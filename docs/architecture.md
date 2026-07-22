# Architecture

## Decision

Use GitHub's runner-scale-set message protocol with standalone ephemeral Azure VMs.

This is intentionally not Azure Container Apps Jobs: those jobs do not support privileged containers or Docker commands, while the target build workloads require Docker and Testcontainers. It is also not a Uniform VMSS with Azure Monitor autoscale: VMSS metric scaling cannot safely associate a unique GitHub JIT configuration with each instance or guarantee that scale-in will not remove a busy runner.

## Components

| Component | Idle state | Responsibility |
|---|---:|---|
| GitHub logical runner scale set `avp-linux` | No cost | Job routing, assigned-job statistics, JIT runner configurations, lifecycle events |
| Container App controller | 1 × 0.25 vCPU / 0.5 GiB | Long-polls GitHub, provisions and deletes Azure resources, reconciles orphans |
| Ephemeral Azure VMs | 0 | Execute exactly one job each; deployed cap 12, controller ceiling 20 |
| Managed runner image | Stored | Reusable .NET 10 / Node 24 / Docker build toolchain |
| ACR | Basic | Stores the controller image |
| Key Vault | Empty of runner data | Stores only GitHub App controller credentials |
| VNet + runner subnet + NSG | No metered gateway | Denies Internet ingress to runner public IPs |
| Log Analytics | Usage based | Stores controller logs |

## Scaling contract

1. The controller creates or adopts the organization runner scale set.
2. The listener advertises the deployed `MAX_RUNNERS=12` to GitHub in `X-ScaleSetMaxCapacity`.
3. GitHub returns `TotalAssignedJobs`, which represents waiting plus running jobs.
4. Target VM count is `min(12, TotalAssignedJobs)`; `MIN_RUNNERS` is validated to exactly zero.
5. Every new runner gets a unique JIT configuration and Azure VM.
6. A `JobStarted` event protects the VM as busy.
7. A `JobCompleted` event starts deletion. The VM also powers off when `run.sh` exits.
8. The one-minute reconciler deletes stopped/deallocated VMs and hard-expired VMs. This catches controller outages and missed cleanup.

The controller never deletes a busy runner merely because desired capacity falls. Queue-driven scale-down only removes runners still known to be idle; completed runners follow the job-completion path.

## Restart behavior

Azure VM tags are the durable inventory:

- `managed-by=gha-runner-scale-controller`
- `runner-scale-set=avp-linux`
- `github-runner-name=<JIT runner name>`
- `runner-created-at=<UTC timestamp>`

After a controller restart, tagged VMs are adopted as `unknown` and protected from ordinary scale-down. Job events restore known state. A stopped VM or a VM older than the 12-hour hard limit is deleted by reconciliation. This favors job safety during a restart while still bounding orphan cost.

## Networking

Each active VM receives a Standard public IP for outbound connectivity. The runner-subnet NSG denies all Internet ingress, and no SSH rule is opened. Per-runner public IPs are deleted with the VM.

This avoids a dedicated NAT Gateway's fixed hourly charge at the current workload level. If a stable outbound IP becomes mandatory, add a shared approved egress path and reassess the fixed-cost tradeoff.

## Images and caches

The Packer-managed image contains repeated build dependencies. Mutable package caches are not shared between repositories or jobs; every runner VM starts from the same immutable image and is destroyed after one job. GitHub Actions cache/artifact services remain the appropriate place for repository-specific dependency caching.

The marketplace-image fallback exists for recovery, but it installs Docker and the runner at boot and will be substantially slower than the managed image.

## Capacity assumptions

The default `Standard_D4s_v5` runner consumes four regional vCPUs and provides 16 GiB for concurrent .NET, Node.js, and Docker workloads. The deployed 12-runner burst consumes 48 of the subscription's 50 Dsv5-family vCPUs. Raising the controller to its supported ceiling of 20 requires at least 80 available Dsv5-family vCPUs plus headroom. Azure quota and regional SKU availability must be verified before increasing capacity.
