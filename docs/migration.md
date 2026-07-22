# Migrating private repositories

## Before changing workflows

1. Deploy and smoke-test `avp-linux`.
2. In GitHub organization settings, place the scale set in a runner group accessible only to the intended private/internal repositories.
3. Confirm both repositories' default branches and required-check names. Changing the runner label must not accidentally rename required checks.
4. Check Azure Dsv5 quota for the combined concurrency of both repositories.

## Workflow change

Replace GitHub-hosted Linux labels used by build/test jobs with the scale-set name:

```yaml
# Before
runs-on: ubuntu-latest

# After
runs-on: avp-linux
```

Apply the same replacement to custom aliases such as `ubuntu-latest-m`. Runner scale-set job routing uses the scale-set name; do not use a list such as `[self-hosted, linux, x64]` for this pool.

The new VM image already contains .NET 10, Node 24, Docker/Buildx/Compose, Azure CLI, `azd`, PowerShell, Java 21, and Aspire. Keep setup actions that enforce an exact project SDK/tool version, but remove redundant installs only after comparing workflow behavior. Image presence is an optimization, not a reason to weaken repository-pinned version policy.

## Recommended rollout

1. Add a manual smoke workflow in one repository.
2. Move pull-request validation for one selected repository.
3. Observe queue time, VM boot time, job duration, Azure cleanup, and failure rate for several days.
4. Move that repository's production jobs.
5. Repeat for each additional repository.
6. Keep a temporary workflow input or branch allowing a GitHub-hosted fallback during stabilization; remove it when acceptance criteria are met.

Do not use an expression that silently falls back based on secrets for untrusted pull requests. Fork-triggered workflows must be reviewed explicitly because self-hosted runners execute repository code inside the AvantiPoint network boundary.

## Docker and Testcontainers

The runner process executes directly on the VM and belongs to the Docker group. Docker actions, service containers, production image builds, and Testcontainers are supported. This is the reason the architecture uses VMs instead of Azure Container Apps Jobs.

## Capacity interaction

All repositories granted access share one homogeneous pool with a deployed maximum of 12 active VMs. GitHub assigns work according to runner-group access and queue state; there is no reserved quota per repository. The controller supports up to 20 only after Azure quota is raised. If one repository must not consume all capacity, enforce workflow-level `concurrency` / matrix `max-parallel`, or introduce separately budgeted scale sets with an explicit global-cap design.

## Rollback

Change `runs-on` back to the previous GitHub-hosted label and remove repository access from the runner group. Let active jobs finish, then verify the Azure runner resource query returns empty. No infrastructure deletion is required for rollback.
