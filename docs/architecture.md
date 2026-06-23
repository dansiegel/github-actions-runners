# Architecture

## Scope

This artifact plans Azure VM Scale Set based GitHub Actions runners for 1:N personal-account repositories and 1:N GitHub organizations.

## Topology

The deployment unit is a runner binding, not a generic pool. Each enabled repository or organization runner binding gets its own VMSS and rendered cloud-init file:

- Repository binding: one VMSS registers to one `https://github.com/{owner}/{repo}` URL.
- Organization binding: one VMSS registers to `https://github.com/{org}` and relies on the configured runner group plus repository allow-list.

This avoids pool-only VMSS behavior that cannot prove repo/org-scoped registration. Pools remain templates for image, size, labels, and defaults. The V1 Linux baseline uses Ubuntu 24.04 LTS via Azure CLI image alias `Ubuntu2404` and the `sh-linux` label family. Target bindings set capacity so the sum can be capped by `defaults.totalRunnerCap`.

## GitHub registration boundary

Every binding must define:

- `registration.runnerUrl`
- token provider type: `command`, `env`, or `keyVault`
- labels inherited from the pool plus required labels: `self-hosted`, `azure`, OS, arch, pool name such as `sh-linux` or `sh-linux-lg`
- repository scope or organization scope
- repository allow-list for organization runners

No token value is committed. For live apply, command token provider scripts are embedded into cloud-init and executed from `/usr/local/bin` on the VM with per-binding `GHA_*` context plus the declared `managedIdentityGitHubApp` credential source. The VM obtains Key Vault access through managed identity, reads GitHub App material from named Key Vault secrets, exchanges it for an installation access token, and requests a short-lived runner registration token. Env and direct Key Vault provider modes fail closed before Azure mutation until a VM-available mechanism is implemented. If URL, token provider contract, VM credential prerequisites, or token provider output is missing, bootstrap exits non-zero and fails closed.

Runner bootstrap uses the pinned GitHub Actions runner release and sha256 values from config, so `linux-x64` and `linux-arm64` pools render their matching archive names and verify integrity before extraction. Pool architecture must also match the Azure VM size family: x64 pools use Dsv5/Ddsv5 sizes and arm64 pools use Dpsv5/Dpdsv5/Dplsv5/Dpldsv5 sizes. This prevents rendering an arm64 runner asset onto an x64 VM size such as `Standard_D2s_v5`.

## Azure boundary

Dry-run renders plan JSON only. Live apply validates tenant/subscription against active `az account show` before running mutation commands. The configured deployment identity must be scoped to the target resource group.


## Shared package cache

V1 includes a VM-local shared package cache for job dependencies. The rendered plan records the default contract once at `sharedPackageCache` and again per runner binding. Cloud-init creates `/mnt/actions-cache/packages` and package-manager subdirectories for apt, npm, NuGet, pip, Cargo, and Go, then exports the corresponding environment variables before starting the GitHub Actions runner:

- `NPM_CONFIG_CACHE=/mnt/actions-cache/packages/npm`
- `PIP_CACHE_DIR=/mnt/actions-cache/packages/pip`
- `NUGET_PACKAGES=/mnt/actions-cache/packages/nuget/packages`
- `DOTNET_CLI_HOME=/mnt/actions-cache/packages/dotnet-home`
- `CARGO_HOME=/mnt/actions-cache/packages/cargo`
- `GOMODCACHE=/mnt/actions-cache/packages/go/pkg/mod`
- `GOCACHE=/mnt/actions-cache/packages/go/build`
- `XDG_CACHE_HOME=/mnt/actions-cache/packages/xdg`
- apt archive cache points at `/mnt/actions-cache/packages/apt/archives`

The cache is intentionally VM-local, not a cross-VM Azure Files or blob mount, to avoid V1 credential, locking, and spend complexity. It is shared across jobs that land on the same VM and persists until the VM is reimaged or destroyed. Bootstrap owns it as `actions-runner:actions-runner`, targets 20 GiB, deletes files older than 14 days, and performs an additional older-than-7-days prune if the size target is exceeded.

## Scaling

Version 1 is fixed-capacity. `minRunners` and `idleTimeoutMinutes` are accepted to keep the schema forward-compatible, but no dynamic scaling or idle reconcile loop is implemented in this artifact.
