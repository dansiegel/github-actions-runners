# Migrating private repositories

## Before changing workflows

1. Deploy and smoke-test every runner pool that workflows will target.
2. In GitHub organization settings, place the scale sets in a runner group accessible only to intended trusted private/internal repositories.
3. Confirm repository default branches and required-check names. Changing the runner label must not accidentally rename required checks.
4. Check Azure regional and SKU-family quota for combined peak capacity across all pools.

## Workflow change

Replace a GitHub-hosted Linux label with the complete profile label appropriate for the workload:

```yaml
# Before
runs-on: ubuntu-latest

# After: ordinary build
runs-on: avp-linux-m
```

Use a larger independently scaled pool only where the job benefits from it:

```yaml
jobs:
  integration:
    runs-on: avp-linux-lp
```

Each job selects exactly one complete CPU/memory/disk label. Do not compose size and disk labels or use a list such as `[self-hosted, linux, x64]` for these pools. `avp-linux-lp` selects 4 CPUs / 16 GiB with P20; `avp-linux-l` selects the same CPU/memory size with P10. Both disks are Premium SSD. The supported size codes are `s`, `m`, `l`, and `xl`, with an attached `p` for P20. Keep the two `s` profiles disabled until image and subscription qualification succeeds.

The VM image already contains .NET 10, Node 24, Docker/Buildx/Compose, Azure CLI and Bicep CLI, `azd`, PowerShell, Java 21, and Aspire. Keep setup actions that enforce an exact project SDK/tool version, but remove redundant installs only after comparing workflow behavior. Image presence is an optimization, not a reason to weaken repository-pinned version policy.

## Preserve existing `avp-linux` consumers

Keep the existing logical scale-set `name: "avp-linux"` and configure `labels: ["avp-linux", "avp-linux-l"]` on that same set. Do not rename it to `avp-linux-l` or create a second scale set with the `avp-linux` label: that would orphan the original identity or leave competing routing labels. Preserve the existing runner group, priority, `Standard_D4s_v5` CPU/memory size, P10 disk, and qualified image. Set a private per-pool `imageId` to pin that image before changing the shared `RUNNER_IMAGE_ID`. Removing the former capacity cap is the explicitly requested fleet-wide uncapped behavior; it does not require changing hardware or images.

Existing workflows may continue using `runs-on: avp-linux` indefinitely. `runs-on: avp-linux-l` is an alias for the identical base profile; a repository opts into another profile only when its workflow changes. Verify that the existing scale set adopts both labels and that exactly one healthy listener owns it. If a previous prototype created another logical set for the large P10 profile, stop routing to it, drain its jobs and VMs, and explicitly retire that set before reusing any of its labels. Repository changes and deployment require their own rollout approval; editing this catalog does not perform either.

## Recommended rollout

1. Add a manual smoke workflow in one repository.
2. Move pull-request validation for one selected repository.
3. Observe queue time, VM boot time, job duration, Azure cleanup, and failure rate for several days.
4. Move that repository's production jobs.
5. Repeat for each additional repository and pool.
6. Keep a temporary workflow input or branch allowing a GitHub-hosted fallback during stabilization; remove it when acceptance criteria are met.

Do not use an expression that silently falls back based on secrets for untrusted pull requests. Fork-triggered workflows must be reviewed explicitly because self-hosted runners execute repository code inside the organization's Azure network boundary.

## Docker and Testcontainers

The runner process executes directly on the VM and belongs to the Docker group. Docker actions, service containers, production image builds, and Testcontainers are supported. This is why the architecture uses VMs instead of Azure Container Apps Jobs.

## Capacity interaction

Repositories granted access share each pool's configured capacity. GitHub assigns work according to runner-group access and queue state; there is no reserved capacity per repository. Separate pools isolate CPU/memory/disk profiles and queues within one shared controller, but they still share Azure subscription quotas and cost. Use workflow `concurrency` and matrix `max-parallel` as additional budget controls.

## Rollback

Change `runs-on` back to the previous GitHub-hosted label and remove repository access from the affected runner scale set or group. Let active jobs finish, then verify the Azure runner-resource query is empty. No infrastructure deletion is required for rollback.
