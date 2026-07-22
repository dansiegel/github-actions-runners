# Architecture

## Decision

Use GitHub's runner-scale-set message protocol with standalone ephemeral Azure VMs. A shared Azure control plane hosts one small Container App controller per configured runner pool.

This is intentionally not Azure Container Apps Jobs: those jobs do not support privileged containers or Docker commands, while the target build workloads require Docker and Testcontainers. It is also not a Uniform VMSS with Azure Monitor autoscale: VMSS metric scaling cannot safely associate a unique GitHub JIT configuration with each instance or guarantee that scale-in will not remove a busy runner.

## Components

| Component | Idle state | Responsibility |
|---|---:|---|
| GitHub logical runner scale set | No cost | Job routing, assigned-job statistics, JIT runner configurations, lifecycle events |
| Container App controller | 1 × 0.25 vCPU / 0.5 GiB per pool | Long-polls GitHub, provisions and deletes Azure resources, reconciles pool orphans |
| Ephemeral Azure VMs | 0 | Execute exactly one job each; independently sized and capped by pool |
| Managed runner image | Stored | Reusable .NET 10 / Node 24 / Docker build toolchain shared by all pools |
| ACR | Basic | Stores the controller image |
| Key Vault | Empty of runner data | Stores only GitHub App controller credentials |
| VNet + runner subnet + NSG | No metered gateway | Denies Internet ingress to runner public IPs |
| Log Analytics | Usage based | Stores all controller logs |

## Pool model

Each pool defines:

- `name`: GitHub scale-set name and workflow `runs-on` label;
- `vmSize`: Azure SKU, such as `Standard_D2s_v5` or `Standard_D4s_v5`;
- `maxRunners`: independent concurrent VM ceiling from 1 through 20;
- `priority`: `Regular` or `Spot`;
- `labels`: labels registered on the GitHub logical scale set.

Pools share the network, controller identity, Key Vault secrets, ACR, and runner image. They do not share queue state or capacity. A 2-vCPU job cannot consume a 4-vCPU pool unless its workflow targets that pool's name.

Pool zero deliberately uses the original single-controller Azure resource name. This makes a single-pool-to-multi-pool upgrade update the existing listener in place. Keep pool ordering stable. Removing a pool requires the explicit retirement procedure in [operations](operations.md), because incremental ARM deployments do not delete an obsolete Container App.

## Scaling contract

For each pool:

1. Its controller creates or adopts the organization runner scale set.
2. The listener advertises that pool's `maxRunners` value to GitHub.
3. GitHub returns `TotalAssignedJobs`, representing waiting plus running jobs for that pool.
4. Target VM count is `min(maxRunners, TotalAssignedJobs)`; minimum runners is validated to exactly zero.
5. Every new runner gets a unique JIT configuration and Azure VM using the pool's VM size.
6. A `JobStarted` event protects the VM as busy.
7. A `JobCompleted` event starts deletion. The VM also powers off when `run.sh` exits.
8. The one-minute reconciler deletes stopped/deallocated VMs and hard-expired VMs.

The controller never deletes a busy runner merely because desired capacity falls. Queue-driven scale-down only removes runners still known to be idle; completed runners follow the job-completion path.

## Restart behavior

Azure VM tags are the durable inventory:

- `managed-by=gha-runner-scale-controller`
- `runner-scale-set=<pool-name>`
- `github-runner-name=<JIT runner name>`
- `runner-created-at=<UTC timestamp>`

After a controller restart, only VMs tagged for that controller's pool are adopted. They are initially protected from ordinary scale-down. Job events restore known state. A stopped VM or a VM older than the 12-hour hard limit is deleted by reconciliation.

## Networking

Each active VM receives a Standard public IP for outbound connectivity. The runner-subnet NSG denies all Internet ingress, and no SSH rule is opened. Per-runner public IPs are deleted with the VM.

This avoids a dedicated NAT Gateway's fixed hourly charge at low workload levels. If a stable outbound IP becomes mandatory, add a shared approved egress path and reassess the fixed-cost tradeoff.

## Images and caches

All pools use the same Packer-managed image containing repeated build dependencies. The pool name is not the Azure image name. Mutable package caches are not shared between repositories or jobs; every runner VM starts from the same immutable image and is destroyed after one job. GitHub Actions cache/artifact services remain the appropriate place for repository-specific dependency caching.

The marketplace-image fallback exists for recovery, but it installs Docker and the runner at boot and will be substantially slower than the managed image.

## Capacity assumptions

Capacity must be budgeted across all pools. For the example configuration, eight `Standard_D2s_v5` runners plus four `Standard_D4s_v5` runners can request 32 Dsv5-family vCPUs at peak. Azure quota and regional SKU availability must be verified before deployment. Per-pool ceilings do not enforce a subscription-wide global cap.
