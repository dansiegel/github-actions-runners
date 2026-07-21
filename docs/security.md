# Security

## Trust model

These runners execute repository-controlled code with Docker access. Membership in the `avp-linux` runner group is therefore equivalent to access to a short-lived privileged Linux host and its network path.

Use this pool only for AvantiPoint private/internal repositories whose workflows and pull-request policies are trusted. Do not grant public repositories or untrusted fork pull requests access without a separate threat review and isolation design.

## Credential boundaries

| Principal | GitHub App secrets | Azure resource permissions | Workflow access |
|---|---:|---:|---:|
| Container App controller identity | Key Vault Secrets User | Custom VM/disk/NIC/public-IP lifecycle role in one resource group; ACR pull | No workflow code runs here |
| Ephemeral runner VM | None | None; no managed identity is attached | Executes one job |
| Deployment operator | Writes Key Vault secrets and deploys infrastructure | Deployment-time privileges | Does not inject credentials into VM custom data |

The previous pattern—giving runner VMs Key Vault access so they could obtain registration tokens—is removed. Workflow code cannot query Azure IMDS for a privileged runner identity because no identity is assigned.

## GitHub registration

- GitHub App authentication is preferred over a PAT.
- The scale-set client is pinned to v0.4.0.
- Each runner uses a unique one-time JIT configuration.
- The JIT value is base64-enveloped in Azure custom data and consumed before workflow code starts.
- Cloud-init deletes its local user-data copies before launching the runner.
- The VM and disk are destroyed after one job, preventing cross-job persistence.

A job running as the runner user may inspect its process tree or Azure instance metadata. The consumed JIT value must still be treated as sensitive, but it cannot be reused to mint other runners or access the GitHub App key.

## Azure permissions

The controller's custom role permits only:

- VM read/write/delete and instance view
- managed disk read/write/delete
- NIC and public IP read/write/delete
- subnet and public-IP join actions
- resource-group read

It cannot create role assignments, read Key Vault data through that role, or manage unrelated resource types. Separate built-in assignments grant Key Vault secret reads and ACR image pulls.

Runner resources are tagged so reconciliation and audit queries stay scoped to resources created by the controller.

## Network

- The runner subnet NSG explicitly denies Internet ingress.
- No SSH ingress rule is created even though a recovery public key is embedded.
- Standard public IPs are used only for outbound connectivity and deleted with the runner.
- There is no fixed-cost NAT Gateway.
- GitHub, package registries, and arbitrary workflow destinations remain reachable outbound.

If outbound allow-listing or data-exfiltration controls are required, route the subnet through an approved firewall/proxy and update the cost model.

## Docker

Membership in the Docker group is effectively root access on the ephemeral VM. This is necessary for Docker actions, service containers, image builds, and Testcontainers. The mitigation is host-level ephemerality and the absence of Azure/GitHub controller credentials—not an assumption that Docker itself is a sandbox.

## Supply chain

The Actions runner archive is pinned to a version and SHA-256. Aspire CLI is version-pinned. Ubuntu, Docker, NodeSource, Azure CLI, `azd`, and PowerShell packages resolve from their stable signed feeds at image-build time; their resolved versions are captured in `/opt/runner-image/manifest.txt`.

For stricter reproducibility, mirror and pin every package in an internal feed, verify installer-script hashes, scan the managed image, and sign an image provenance record before production rollout.

## Logging and incident response

Controller logs go to Log Analytics. Runner bootstrap and runner diagnostic tails are written to the serial console and captured by managed boot diagnostics. GitHub retains workflow job logs.

On suspected runner compromise:

1. Remove repository access from the runner group.
2. Suspend the controller.
3. Preserve relevant GitHub and Azure logs before deleting resources.
4. Rotate any workflow-accessible credentials used by the affected repository.
5. Rebuild the managed image and redeploy before restoring access.
