# github-actions-runners

Azure-first deployment baseline for self-hosted GitHub Actions runners.

Status: private-first scaffold, designed so the project can be opened later after review. Dry-run commands are safe by default. Live Azure apply/destroy requires explicit approval, configured tenant/subscription match, spend confirmation, and complete runner registration inputs.

## Defaults

- Azure region: `eastus`
- Total runner cap: `20`
- Public IP: disabled by default
- Runner mode: ephemeral by default
- Azure image: `Ubuntu2404` (Ubuntu 24.04 LTS) by default
- V1 Linux labels: `sh-linux` and `sh-linux-lg` in the example label family; reserve `sh-linux-max` for larger pools when added.
- Topology: one VM Scale Set and cloud-init bootstrap per repo/org registration binding
- Scaling mode: fixed-capacity v1. `minRunners` and `idleTimeoutMinutes` are accepted as documented intent, but no dynamic reconcile loop is implemented yet.
- Shared package cache: enabled by default only for private trusted runner bindings at `/mnt/actions-cache/packages` for apt, npm, NuGet, pip, Cargo, and Go cache directories; owned by `actions-runner:actions-runner`, sized at 20 GiB, and pruned for files older than 14 days during bootstrap. Public/untrusted bindings fail closed unless the specific shared-cache trust risk is separately reviewed in `publicVisibilityOptIn.sharedPackageCacheRisk`, or the cache is disabled.

## Quick start

```bash
cp config/runners.example.yaml config/runners.yaml
./scripts/validate-config.sh --config config/runners.yaml
./scripts/render-plan.sh --config config/runners.yaml --out artifacts/plan.json
./scripts/deploy-azure.sh --config config/runners.yaml --dry-run
./scripts/destroy-azure.sh --config config/runners.yaml --dry-run
```

Render one bootstrap file for review:

```bash
./scripts/render-cloud-init.sh --config config/runners.yaml --binding repo-example-user-repo-one --output /tmp/cloud-init.yaml
```

## Live Azure gates

Live apply is intentionally guarded:

```bash
./scripts/deploy-azure.sh --config config/runners.yaml --apply --confirm-spend I_ACCEPT_AZURE_SPEND
```

Before any paid Azure mutation, the tool validates:

1. `defaults.azure.tenantId` and `defaults.azure.subscriptionId` resolve from config/env.
2. Active `az account show` tenant/subscription matches the configured values before any token minting.
3. `defaults.azure.deploymentIdentity.scope` is `resourceGroup` for the configured resource group.
4. Every runner binding has `registration.runnerUrl` and a token provider contract that is executable in the VM environment.
5. Command token providers declare `vmCredentialSource.type: managedIdentityGitHubApp`; live apply validates the VM-side Key Vault/GitHub App prerequisites resolve before any Azure mutation. Env, direct Key Vault, and local `GITHUB_TOKEN`-only command providers fail live apply until translated into a VM-available mechanism.
6. Runner downloads use a pinned `defaults.github.runnerRelease.version` and per-asset sha256 for `linux-x64` and `linux-arm64`.
7. Runner pool architecture matches the Azure VM size family; arm64 uses Dpsv5/Dpdsv5/Dplsv5/Dpldsv5 sizes such as `Standard_D2ps_v5`, not x64 Dsv5 sizes such as `Standard_D2s_v5`.
8. The rendered plan and cloud-init include the shared package cache contract, including root path, package-manager environment variables, ownership, and prune/sizing controls.

Destroy is also guarded:

```bash
./scripts/destroy-azure.sh --config config/runners.yaml --apply --confirm-resource-group gha-runners-dev --confirm-spend I_ACCEPT_AZURE_SPEND
```

## Private-first policy

Accounts default to private. `visibility: public` is rejected unless `publicVisibilityOptIn` records a reviewed approval. That public-visibility approval does not approve shared writable package cache state. Public/untrusted accounts must either set `defaults.sharedPackageCache.enabled: false` or record a separate `publicVisibilityOptIn.sharedPackageCacheRisk` review with `allowSharedPackageCache: true`, `reviewedBy`, `reviewedAt`, and `reason`. Do not commit tokens, tenant IDs, subscription IDs, resource IDs, or private repo names.
