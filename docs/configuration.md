# Configuration

`infra/main.bicep` is the source of truth. `infra/main.parameters.json` maps Azure Developer CLI environment values into its parameters. Deployment scripts validate and normalize the public command-line inputs before provisioning.

## Deployment inputs

| Setting | Default | Constraint |
|---|---|---|
| Subscription | Required | Exact confirmation is required for mutation |
| GitHub organization | Required | GitHub App must be installed here |
| Region | `eastus2` | Managed image and runner VMs must be in the same region |
| Resource group | `gha-runners-prod` | Controller custom role is scoped here |
| Runner group | `default` | Restrict repository access in GitHub settings |
| Pool configuration | One `azure-linux` pool | Use a JSON file for multiple size classes |
| Minimum runners | `0` | Controller rejects any other value |
| Maximum runners | `0` (uncapped) | Optional integer from 0 through 2,147,483,647; omission also means uncapped |
| VM size | `Standard_D4s_v5` for the single-pool shorthand | Any validated Standard Azure VM SKU available in the region |
| VM priority | `Regular` | `Spot` is supported but can evict jobs |
| Managed-image prefix | `gha-runner` | Timestamp is appended by the deployment script |
| Idle timeout | 30 minutes | Only known-idle VMs; normal assignment should be much faster |
| Hard VM lifetime | 12 hours | Cost guard for stuck/orphaned VMs |

There are no default subscription or organization values.

## Runner pool JSON

`runner-pools.example.json` documents the supported shape. Each entry accepts only `name`, `vmSize`, `maxRunners`, `priority`, `labels`, `osDiskTier`, `enabled`, and `imageId`; unknown keys are rejected:

```json
[
  {
    "name": "avp-linux-m",
    "vmSize": "Standard_D2s_v5",
    "priority": "Regular",
    "labels": ["avp-linux-m"],
    "osDiskTier": "P10"
  }
]
```

The scripts require a nonempty array with unique pool names and labels, at least one enabled pool, and no fixed pool-count limit. `maxRunners` is optional: omission or `0` means uncapped demand; a positive integer through 2,147,483,647 is an explicit per-pool cap. Negative, fractional, string, boolean, or null caps are rejected. `enabled` is an optional boolean, defaulting to true. False leaves a profile configured without starting its listener or VMs. `imageId` is an optional string; omission, an empty string, or whitespace inherits the shared `RUNNER_IMAGE_ID`, while a nonempty value overrides it for that pool. Null and non-string values are rejected, and omitted values stay omitted during normalization. Missing `priority` defaults to `Regular`; missing or empty `labels` defaults to the pool name. Keep deployment-specific copies outside this public repository when their labels or topology are sensitive.

The profile labels define complete workload choices:

| Base label | Higher-performance label | CPU / memory | VM size | Default state |
|---|---|---|---|---|
| `avp-linux-s` | `avp-linux-sp` | 1 CPU / 2 GiB | `Standard_F1als_v7` | Disabled |
| `avp-linux-m` | `avp-linux-mp` | 2 CPUs / 8 GiB | `Standard_D2s_v5` | Enabled, uncapped |
| `avp-linux-l` | `avp-linux-lp` | 4 CPUs / 16 GiB | `Standard_D4s_v5` | Enabled, uncapped |
| `avp-linux-xl` | `avp-linux-xlp` | 8 CPUs / 32 GiB | `Standard_D8s_v5` | Enabled, uncapped |

Base labels select P10 and the attached `p` selects P20. Both use `Premium_LRS`; `p` is a higher-performance profile convention, not a distinction between premium and non-premium storage. The catalog stores the disk class only; capacities, IOPS, and throughput are derived from the tier rather than duplicated in pool JSON.

`name` is the stable GitHub logical scale-set identity, separate from VM SKU and image reference. There is no additional `id` field. All example names match the main label except the large P10 pool: its existing `name` remains `avp-linux` and its labels are `["avp-linux", "avp-linux-l"]`. These two labels select the identical profile. Existing `avp-linux` workflows retain their 4-CPU / 16-GiB `Standard_D4s_v5`, P10 disk, currently qualified image, runner group, and priority. No migration deadline is imposed; repositories choose other profiles individually. The previous capacity cap is removed because the fleet is explicitly uncapped, with Azure quota and capacity still applying.

The two small profiles remain `enabled: false` until a Gen2/NVMe-compatible Compute Gallery image and subscription are qualified. The current managed image is not qualified for that family. A qualified per-pool `imageId` can enable a new family without changing other pools' images. Conversely, pin the existing qualified image in the private `avp-linux` pool entry before changing the shared image default, so existing consumers keep it. The public example deliberately omits actual image IDs and `maxRunners`; enabled profiles also omit `enabled` to use the true default.

For a single pool, command-line parameters are sufficient:

```powershell
./scripts/deploy-azure.ps1 `
  -SubscriptionId '<subscription-id>' `
  -GitHubOrganization '<organization>' `
  -RunnerScaleSetName 'linux-build' `
  -RunnerVmSize 'Standard_D2s_v5' `
  -RunnerMaxCapacity 6
```

## Optional OS disk performance

Pool entries may set `"osDiskTier": "P20"` to select a capacity-backed Premium SSD tier for
new ephemeral runners. Omission preserves the existing 128 GiB/P10 default. The public example explicitly selects P10 or P20 for each profile.

| osDiskTier | New OS disk capacity | Sustained disk IOPS | Disk throughput |
|---|---:|---:|---:|
| P10 | 128 GiB | 500 | 100 MB/s |
| P15 | 256 GiB | 1,100 | 125 MB/s |
| P20 | 512 GiB | 2,300 | 150 MB/s |
| P30 | 1,024 GiB | 5,000 | 200 MB/s |

The controller selects the matching disk capacity during VM creation, so the tier is present
before boot. This increases ephemeral disk capacity as well as performance; it does not resize
an existing runner or mutate a disk after a job starts. The controller's optional
`RUNNER_OS_DISK_SIZE_GB` setting cannot exceed a selected tier's capacity. Unknown or conflicting
tiers fail validation before the controller allocates runner resources. Both deployment scripts
validate the pool value and display it in dry runs; Bicep supplies all profile settings once through `RUNNER_POOLS_JSON` to the shared controller. Legacy single-pool controller deployments may still use `RUNNER_OS_DISK_TIER`.

Check the chosen VM's disk limits before activation. For example, `Standard_D4s_v5` has an
uncached limit of 6,400 IOPS and 145 MB/s: P20's 2,300 IOPS fit, but its nominal 150 MB/s is bounded
by the VM's 145 MB/s limit. The provisioner does not infer workload needs or silently change
VM size. See [Microsoft's VM limits](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/dsv5-series)
and [Premium SSD tiers](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-change-performance).

Cost illustration, checked against the [Azure Retail Prices API](https://prices.azure.com/api/retail/prices)
on 2026-09-27 for East US 2, USD, Premium SSD Managed Disks LRS disk meters:

| Tier | Monthly retail meter | Approximate disk-hour (730 hours/month) |
|---|---:|---:|
| P10 | $17.92 | $0.02455 |
| P15 | $34.56 | $0.04734 |
| P20 | $66.56 | $0.09118 |
| P30 | $122.88 | $0.16833 |

P20 adds approximately $0.06663 per runner-hour over P10, or $0.03332 for a 30-minute disk
lifetime. Actual charges depend on disk lifetime, region, agreement, and current prices. These
estimates exclude VM/network charges and shared-disk mount meters. OS disks for ephemeral runners retain
`deleteOption: Delete`; no disk remains after successful VM cleanup.

Before changing a shared organization pool, inventory its consumers and total runner-hours.
Compare a bounded run's disk pressure, job duration, and outcomes against the previous tier;
a higher tier is not proof that unrelated DNS, registry, or application failures are fixed.
Reverting the pool setting returns future runners to the default; already-running VMs are not
changed. No deployment or higher-tier activation occurs merely by updating this repository.

## Azure Developer CLI values

The deployment scripts set these values:

```text
AZURE_SUBSCRIPTION_ID
AZURE_LOCATION
AZURE_RESOURCE_GROUP
ADMIN_SSH_PUBLIC_KEY
GITHUB_ORGANIZATION
RUNNER_GROUP
RUNNER_POOLS_JSON
RUNNER_POOLS_BASE64
RUNNER_SCALE_SET_NAME
RUNNER_MAX_CAPACITY
RUNNER_VM_SIZE
RUNNER_VM_PRIORITY
RUNNER_IMAGE_ID
RUNNER_CONTROLLER_IMAGE
DEPLOY_RUNNER_CONTROLLER
```

The single-pool values mirror pool zero for compatibility. Keep the existing `avp-linux` pool first, as in the example, so those values retain its logical name and D4s_v5 SKU. `RUNNER_POOLS_JSON` is the human-readable authoritative definition; the deployment scripts derive `RUNNER_POOLS_BASE64` from it so `azd` can safely interpolate the structured value into its JSON parameters document. Bicep decodes that transport value and passes the complete array as `RUNNER_POOLS_JSON` to one controller. It does not inject the single-pool environment variables alongside that array. Phase one sets the image values empty and `DEPLOY_RUNNER_CONTROLLER=false`; phase two sets immutable image references and enables the shared controller. A missing cap mirrors as zero in the compatibility values. The controller also supports the legacy single-pool environment variables when no pool JSON is supplied.

## GitHub App secrets

The dedicated Key Vault uses these secret names:

- `github-app-client-id`
- `github-app-installation-id`
- `github-app-private-key`

The shared Container App resolves the secrets through its user-assigned identity. They are never rendered into Bicep deployment history or runner VM configuration.

## Runner image

`image/runner.pkr.hcl` builds the default Ubuntu 24.04 managed image. Pools inherit its `RUNNER_IMAGE_ID` unless they set a nonempty `imageId` override; each selected image must be compatible with that pool's VM family. Its contents include GitHub Actions runner 2.337.0, .NET SDK 10.0, Node.js 24, Docker Engine, Azure CLI and Bicep CLI, `azd`, PowerShell, Aspire CLI 13.4.6, Java 21, and common build tools. A VM still replaces the baked runner when `.installed-version` does not match `RUNNER_VERSION`, because GitHub rejects job messages from a deprecated runner build.

Resolved versions, the verified booted kernel and the package-inventory hash are written
to `/opt/runner-image/manifest.txt`; `/opt/runner-image/packages.tsv` contains the installed
package inventory. Image creation applies stable OS updates and verifies the image after
a reboot. Automatic apt and firmware maintenance is disabled for the disposable job
lifetime. Follow the [immutable-image refresh policy](security.md#immutable-os-maintenance)
for security updates. `-RunnerImageNamePrefix` / `--runner-image-name-prefix` controls the
Azure image-name prefix; it does not affect workflow labels.

## Capacity and quota

Capacity changes require updating the relevant pool's `maxRunners` or `vmSize` and reprovisioning. For explicitly capped pools, calculate peak vCPU demand as the sum of `maxRunners × SKU vCPUs`. Uncapped profiles have no configured peak; estimate workload concurrency instead. Confirm both total regional quota and each SKU-family quota, and leave replacement headroom. The shared controller imposes no fixed total-vCPU ceiling or 20-runner ceiling. GitHub's capacity field is int32, so an uncapped listener advertises 2,147,483,647 while Azure availability and quotas still bound actual VMs.

## Spot runners

Set a pool's `priority` to `Spot` only for retry-safe workflows. Spot VMs use `evictionPolicy=Delete`, so an Azure eviction terminates the current job. Regular capacity remains the default.
