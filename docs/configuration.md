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
| Maximum runners | `10` for the single-pool shorthand | Each pool must be 1 through 20 |
| VM size | `Standard_D4s_v5` for the single-pool shorthand | Any validated Standard Azure VM SKU available in the region |
| VM priority | `Regular` | `Spot` is supported but can evict jobs |
| Managed-image prefix | `gha-runner` | Timestamp is appended by the deployment script |
| Idle timeout | 30 minutes | Only known-idle VMs; normal assignment should be much faster |
| Hard VM lifetime | 12 hours | Cost guard for stuck/orphaned VMs |

There are no default subscription or organization values.

## Runner pool JSON

`runner-pools.example.json` documents the supported shape:

```json
[
  {
    "name": "linux-2vcpu",
    "vmSize": "Standard_D2s_v5",
    "maxRunners": 8,
    "priority": "Regular",
    "labels": ["linux-2vcpu"]
  }
]
```

The scripts require one through eight unique pool names. Each pool can scale to at most 20 VMs. Missing `priority` defaults to `Regular`; missing or empty `labels` defaults to the pool name. Keep deployment-specific copies outside this public repository when their labels or topology are sensitive.

For a single pool, command-line parameters are sufficient:

```powershell
./scripts/deploy-azure.ps1 `
  -SubscriptionId '<subscription-id>' `
  -GitHubOrganization '<organization>' `
  -RunnerScaleSetName 'linux-build' `
  -RunnerVmSize 'Standard_D2s_v5' `
  -RunnerMaxCapacity 6
```

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
RUNNER_SCALE_SET_NAME
RUNNER_MAX_CAPACITY
RUNNER_VM_SIZE
RUNNER_VM_PRIORITY
RUNNER_IMAGE_ID
RUNNER_CONTROLLER_IMAGE
DEPLOY_RUNNER_CONTROLLER
```

The single-pool values mirror pool zero for compatibility. `RUNNER_POOLS_JSON` is authoritative when nonempty. Phase one sets the image values empty and `DEPLOY_RUNNER_CONTROLLER=false`; phase two sets immutable image references and enables all controllers.

## GitHub App secrets

The dedicated Key Vault uses these secret names:

- `github-app-client-id`
- `github-app-installation-id`
- `github-app-private-key`

Every Container App resolves the same secrets through the shared user-assigned identity. They are never rendered into Bicep deployment history or runner VM configuration.

## Runner image

`image/runner.pkr.hcl` builds one Ubuntu 24.04 managed image shared by all pools. Its contents include GitHub Actions runner 2.335.1, .NET SDK 10.0, Node.js 24, Docker Engine, Azure CLI and Bicep CLI, `azd`, PowerShell, Aspire CLI 13.4.6, Java 21, and common build tools.

Resolved versions are written to `/opt/runner-image/manifest.txt`. Rebuild the image deliberately to accept upstream package updates. `-RunnerImageNamePrefix` / `--runner-image-name-prefix` controls the Azure image-name prefix; it does not affect workflow labels.

## Capacity and quota

Capacity changes require updating the relevant pool's `maxRunners` or `vmSize` and reprovisioning. Calculate peak vCPU demand as the sum of `maxRunners × SKU vCPUs` across all pools. Confirm both total regional quota and the SKU-family quota; the controllers enforce per-pool limits, not a global Azure quota budget.

## Spot runners

Set a pool's `priority` to `Spot` only for retry-safe workflows. Spot VMs use `evictionPolicy=Delete`, so an Azure eviction terminates the current job. Regular capacity remains the default.
