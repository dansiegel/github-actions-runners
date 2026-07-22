# Migrating private repositories

## Before changing workflows

1. Deploy and smoke-test every runner pool that workflows will target.
2. In GitHub organization settings, place the scale sets in a runner group accessible only to intended trusted private/internal repositories.
3. Confirm repository default branches and required-check names. Changing the runner label must not accidentally rename required checks.
4. Check Azure regional and SKU-family quota for combined peak capacity across all pools.

## Workflow change

Replace a GitHub-hosted Linux label with the pool name appropriate for the workload:

```yaml
# Before
runs-on: ubuntu-latest

# After: ordinary build
runs-on: linux-2vcpu
```

Use a larger independently scaled pool only where the job benefits from it:

```yaml
jobs:
  integration:
    runs-on: linux-4vcpu
```

Runner scale-set job routing uses the scale-set name; do not use a list such as `[self-hosted, linux, x64]` for these pools.

The VM image already contains .NET 10, Node 24, Docker/Buildx/Compose, Azure CLI and Bicep CLI, `azd`, PowerShell, Java 21, and Aspire. Keep setup actions that enforce an exact project SDK/tool version, but remove redundant installs only after comparing workflow behavior. Image presence is an optimization, not a reason to weaken repository-pinned version policy.

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

Repositories granted access share each pool's configured capacity. GitHub assigns work according to runner-group access and queue state; there is no reserved capacity per repository. Separate pools isolate size classes and queues, but they still share Azure subscription quotas and cost. Use workflow `concurrency` and matrix `max-parallel` as additional budget controls.

## Rollback

Change `runs-on` back to the previous GitHub-hosted label and remove repository access from the affected runner scale set or group. Let active jobs finish, then verify the Azure runner-resource query is empty. No infrastructure deletion is required for rollback.
