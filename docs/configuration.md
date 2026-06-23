# Configuration

`config/runners.example.yaml` is the reference shape.

Required top-level fields:

- `version: 1`
- `project: github-actions-runners`
- `defaults`
- `runnerPools`
- `accounts`

## Defaults

`defaults.totalRunnerCap` caps the sum of all target binding capacities. Default is 20.

`defaults.azure.region` defaults to `eastus`. Live apply also requires `tenantId`, `subscriptionId`, and a resource-group-scoped `deploymentIdentity`.

`defaults.github.tokenProvider` is required. It must reference a token provider, not a token value.

## Accounts

User accounts contain repository bindings. Organization accounts contain pools with `repositoryAllowList`. Public visibility is rejected unless a reviewed `publicVisibilityOptIn` exists.

## Runner pools

Pools define VM size, image, labels, OS, arch, and fixed capacity defaults. The V1 Linux default image is `Ubuntu2404` (Ubuntu 24.04 LTS), and Linux pool labels should use the `sh-linux` family (`sh-linux`, `sh-linux-lg`, and `sh-linux-max` for a future larger pool). Bindings can override capacity with `maxRunners` so the deployment topology can remain per target while staying under the total cap.

Architecture compatibility is validated before render/apply:

- `arch: x64` requires an x64 Azure VM size such as `Standard_D2s_v5`.
- `arch: arm64` requires an Azure Arm VM size in the Dpsv5/Dpdsv5/Dplsv5/Dpldsv5 families, such as `Standard_D2ps_v5`.

Microsoft Learn documents Dpsv5/Dpdsv5/Dplsv5/Dpldsv5 as Ampere Altra Arm64 VM series. An arm64 runner pool with `Standard_D2s_v5` is rejected because Dsv5 is x64.


## Shared package cache

`defaults.sharedPackageCache` is enabled in the V1 example for private trusted runner bindings:

```yaml
sharedPackageCache:
  enabled: true
  root: /mnt/actions-cache/packages
  maxSizeGb: 20
  pruneAfterDays: 14
  ownership: actions-runner:actions-runner
  packageManagers: [apt, npm, nuget, pip, cargo, go]
```

The public visibility review is intentionally separate from shared writable cache review. If any account is public/untrusted and `defaults.sharedPackageCache.enabled` is true, validation fails unless `publicVisibilityOptIn.sharedPackageCacheRisk` records `allowSharedPackageCache: true`, `reviewedBy`, `reviewedAt`, and `reason`. Public/untrusted configs can instead set `defaults.sharedPackageCache.enabled: false` to avoid sharing retained package/global cache state across untrusted repositories or jobs.

The root must be an absolute dedicated Linux path. The renderer injects the cache contract into the plan and cloud-init for every binding. The bootstrap creates the root and subdirectories, applies the configured ownership, exports package-manager cache variables, sets apt archives to the shared apt cache directory, prunes files older than `pruneAfterDays`, and applies an extra size-pressure prune when usage exceeds `maxSizeGb`.

## Registration

Every enabled repo/org binding must include `registration.runnerUrl`. This explicit URL is injected into cloud-init together with a VM-provisioned token provider command and the computed `registrationTokenEndpoint`. Missing registration inputs fail validation before live apply.

The token provider contract receives per-binding context through environment variables: `GHA_REGISTRATION_TOKEN_ENDPOINT`, `GHA_RUNNER_URL`, `GHA_RUNNER_SCOPE`, `GHA_BINDING_NAME`, `GHA_TARGET_KIND`, `GHA_TARGET_OWNER`, and `GHA_TARGET_REPOSITORY`. Providers must not print source credentials or logs to stdout; stdout must contain only the short-lived GitHub Actions registration token. Current live apply support requires a relative command provider script that can be embedded into cloud-init and executed on the VM. Command providers must declare `vmCredentialSource.type: managedIdentityGitHubApp` with Key Vault secret names for GitHub App id, private key, and installation id. Live apply validates those VM-side prerequisites resolve before any Azure mutation. Command providers that depend only on a local operator environment variable, plus env and Key Vault provider modes, fail closed until translated into a VM-available managed identity or equivalent mechanism.

## Runner download integrity

`defaults.github.runnerRelease` pins the GitHub Actions runner version and sha256 values for `linux-x64` and `linux-arm64`. Cloud-init downloads the exact pinned asset URL and verifies `sha256sum -c -` before extraction.
