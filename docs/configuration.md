# Configuration

`infra/main.bicep` is the source of truth. `infra/main.parameters.json` maps Azure Developer CLI environment values into its parameters.

## Defaults

| Setting | Default | Constraint |
|---|---|---|
| Subscription | `d901cbec-f20d-4272-a0b4-9ee06b850880` in deployment scripts | Exact confirmation required by scripts |
| Region | `eastus2` | Managed image and runner VMs must be in the same region |
| Resource group | `gha-runners-prod` | Controller custom role is scoped here |
| GitHub organization | `AvantiPoint` | GitHub App must be installed here |
| Scale set / label | `avp-linux` | Use this exact value in `runs-on` |
| Minimum runners | `0` | Controller rejects any other value |
| Maximum runners | `20` | Enforced by Bicep and controller validation |
| VM size | `Standard_D2s_v5` | 2 vCPU, 8 GiB, x64 |
| VM priority | `Regular` | `Spot` is supported but can evict jobs |
| Idle timeout | 30 minutes | Only known-idle VMs; normal assignment should be much faster |
| Hard VM lifetime | 12 hours | Cost guard for stuck/orphaned VMs |

## Azure Developer CLI values

The deployment scripts set these values:

```text
AZURE_SUBSCRIPTION_ID
AZURE_LOCATION
AZURE_RESOURCE_GROUP
ADMIN_SSH_PUBLIC_KEY
GITHUB_ORGANIZATION
RUNNER_GROUP
RUNNER_SCALE_SET_NAME
RUNNER_MAX_CAPACITY
RUNNER_VM_SIZE
RUNNER_VM_PRIORITY
RUNNER_IMAGE_ID
RUNNER_CONTROLLER_IMAGE
DEPLOY_RUNNER_CONTROLLER
```

Phase one sets the image values empty and `DEPLOY_RUNNER_CONTROLLER=false`. Phase two sets immutable image references and enables the controller.

## GitHub App secrets

The dedicated Key Vault uses these secret names:

- `github-app-client-id`
- `github-app-installation-id`
- `github-app-private-key`

The Container App resolves these as Key Vault references through its user-assigned identity. They are never rendered into Bicep deployment history or runner VM configuration.

## Runner image

`image/runner.pkr.hcl` builds an Ubuntu 24.04 managed image with:

- GitHub Actions runner 2.335.1, pinned by SHA-256
- .NET SDK 10.0
- Node.js 24 and npm
- Docker Engine, Buildx, and Compose
- Azure CLI and Azure Developer CLI
- PowerShell
- Aspire CLI 13.4.0
- Java 21, Python 3, Git, build-essential, jq, zip/unzip, and rsync

The resolved versions are written to `/opt/runner-image/manifest.txt` in the image. Rebuild the image deliberately to accept upstream package updates.

## Changing capacity

Capacity can be reduced without code changes by setting `RUNNER_MAX_CAPACITY` to an integer from 1 through 20 and reprovisioning. The supported production ceiling is 20. A larger ceiling requires a code/config review, an Azure quota review, and revisiting the cost guard; do not simply bypass the validation.

## Spot runners

Set `RUNNER_VM_PRIORITY=Spot` only for retry-safe workflows. Spot VMs use `evictionPolicy=Delete`, so an Azure eviction terminates the current job. Production deployments default to Regular capacity.
