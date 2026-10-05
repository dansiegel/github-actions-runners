# Architecture

## Decision

Use GitHub's runner-scale-set message protocol with standalone ephemeral Azure VMs. A shared Azure control plane hosts one small Container App controller hosting independent listeners for every enabled runner pool.

This is intentionally not Azure Container Apps Jobs: those jobs do not support privileged containers or Docker commands, while the target build workloads require Docker and Testcontainers. It is also not a Uniform VMSS with Azure Monitor autoscale: VMSS metric scaling cannot safely associate a unique GitHub JIT configuration with each instance or guarantee that scale-in will not remove a busy runner.

## Components

| Component | Idle state | Responsibility |
|---|---:|---|
| GitHub logical runner scale set | No cost | Job routing, assigned-job statistics, JIT runner configurations, lifecycle events |
| Container App controller | 1 × 0.25 vCPU / 0.5 GiB total | Long-polls GitHub, provisions and deletes Azure resources, reconciles pool orphans |
| Ephemeral Azure VMs | 0 | Execute exactly one job each; independently sized with optional per-pool caps |
| Managed runner image | Stored | Default .NET 10 / Node 24 / Docker build toolchain, with optional per-pool image overrides |
| ACR | Basic | Stores the controller image |
| Key Vault | Empty of runner data | Stores only GitHub App controller credentials |
| VNet + runner subnet + NSG | No metered gateway | Denies Internet ingress to runner public IPs |
| Log Analytics | Usage based | Stores all controller logs |

## Pool model

Each pool defines:

- `name`: stable GitHub logical scale-set identity, independent of VM SKU and image;
- `vmSize`: Azure SKU, such as `Standard_D2s_v5` or `Standard_D4s_v5`;
- `maxRunners`: optional concurrent VM cap; zero or omission follows demand without a configured cap, while a positive integer up to 2,147,483,647 sets a cap;
- `priority`: `Regular` or `Spot`;
- `labels`: complete profile labels registered on the GitHub logical scale set; each job selects one;
- `imageId`: optional image resource ID override; an omitted or empty string inherits `RUNNER_IMAGE_ID`;
- `osDiskTier`: optional capacity-backed Premium SSD tier;
- `enabled`: optional boolean, defaulting to true; false prevents starting that profile's listener and VMs.

Pools share the network, controller identity, Key Vault secrets, and ACR, and inherit the shared runner image unless overridden. They do not share queue state or capacity. A 2-vCPU job cannot consume a 4-vCPU pool unless its workflow selects that pool's complete label. The existing `avp-linux` logical identity retains its label and also advertises `avp-linux-l`, both routing to the same 4-CPU / 16-GiB / P10 pool.

The shared controller deliberately uses the original single-controller Azure resource name. Pool order has no effect on that name. Migration from an older controller-per-pool deployment must explicitly retire extra controllers before starting their listeners in the shared process; ARM incremental deployment does not delete obsolete apps. Follow the drain and retirement procedure in [operations](operations.md).

## Scaling contract

For each pool:

1. Its listener in the shared controller creates or adopts the organization runner scale set.
2. The listener advertises its configured cap to GitHub, or the SDK's maximum int32 capacity (2,147,483,647) when uncapped.
3. GitHub returns `TotalAssignedJobs`, representing waiting plus running jobs for that pool.
4. Target VM count follows `TotalAssignedJobs`, bounded only when `maxRunners` is positive; minimum runners is validated to exactly zero.
5. Every new runner gets a unique JIT configuration and Azure VM using the pool's VM size.
6. A `JobStarted` event protects the VM as busy.
7. A `JobCompleted` event starts deletion. The VM also powers off when `run.sh` exits.
8. The one-minute reconciler deletes stopped/deallocated VMs and hard-expired VMs, and removes the matching GitHub runner registration.
9. A failed VM create removes the JIT registration it just minted. Quota, allocation, and preempted-create errors pause further creates and leave the listener session running.

The controller never deletes a busy runner merely because desired capacity falls. Queue-driven scale-down only removes runners still known to be idle; completed runners follow the job-completion path.

## Restart behavior

Azure VM tags are the durable inventory:

- `managed-by=gha-runner-scale-controller`
- `runner-scale-set=<pool-name>`
- `github-runner-name=<JIT runner name>`
- `runner-created-at=<UTC timestamp>`

After a controller restart, each pool adopts only VMs tagged for its own scale set. They are initially protected from ordinary scale-down. Job events restore known state. A stopped VM or a VM older than the 12-hour hard limit is deleted by reconciliation.

## Networking

Each active VM receives a Standard public IP for outbound connectivity. The runner-subnet NSG denies all Internet ingress, and no SSH rule is opened. Per-runner public IPs are deleted with the VM.

This avoids a dedicated NAT Gateway's fixed hourly charge at low workload levels. If a stable outbound IP becomes mandatory, add a shared approved egress path and reassess the fixed-cost tradeoff.

## Images and caches

Pools default to the Packer-managed image containing repeated build dependencies. A nonempty per-pool `imageId` overrides that shared default, for example to qualify a Gen2/NVMe Compute Gallery image for a new family or keep the legacy `avp-linux` pool pinned to its currently qualified image. The pool name is a stable logical identity, independent of the Azure image or VM SKU. Mutable package caches are not shared between repositories or jobs; every runner VM starts from its pool's selected immutable image and is destroyed after one job. GitHub Actions cache/artifact services remain the appropriate place for repository-specific dependency caching.

The marketplace-image fallback exists for recovery, but it installs Docker and the runner at boot and will be substantially slower than the managed image.

## Capacity assumptions

Capacity must be budgeted across all enabled pools. The example follows demand without configured runner or total-vCPU caps. Azure quota, regional SKU availability, subnet addresses, and provisioning throughput remain practical limits. Positive per-pool caps are optional and do not enforce a subscription-wide global budget. The disabled one-core profiles require a qualified Gen2/NVMe Compute Gallery image and subscription before activation.
