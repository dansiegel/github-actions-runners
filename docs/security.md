# Security

## Trust model

These runners execute repository-controlled code with Docker access. Access to any configured runner pool is therefore equivalent to access to a short-lived privileged Linux or Windows host and its network path.

Use these pools only for trusted private/internal repositories whose workflows and pull-request policies are controlled. Do not grant public repositories or untrusted fork pull requests access without a separate threat review and isolation design.

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

## Runner host privileges

The runner account has passwordless `sudo`, matching the standard GitHub Linux-runner workflow contract, and belongs to the Docker group for Docker actions, service containers, image builds, and Testcontainers. Either capability is effectively root access on the ephemeral VM. The mitigation is host-level ephemerality and the absence of Azure/GitHub controller credentials—not an assumption that the runner account or Docker is a sandbox.

## Supply chain

The Actions runner archive is pinned to a version and SHA-256. Aspire CLI is version-pinned. Ubuntu, Docker, NodeSource, Azure CLI, Bicep CLI, `azd`, and PowerShell packages resolve from their stable signed feeds at image-build time; their resolved versions are captured in `/opt/runner-image/manifest.txt`.

For stricter reproducibility, mirror and pin every package in an internal feed, verify installer-script hashes, scan the managed image, and sign an image provenance record before production rollout.

## Immutable OS maintenance

Image creation applies stable signed package updates synchronously before installing the
toolchain. It stops automatic timer scheduling, waits up to ten minutes for any existing
package maintenance to finish, and fails instead of killing an active package transaction.
Automatic apt updates, unattended upgrades and firmware refresh units are then masked;
the effective APT periodic settings are disabled. These disposable Azure VMs must not
change packages or perform firmware maintenance while a CI job is running.

The builder reboots before capture and verifies the masks, effective package policy,
completed package transactions and toolchain. The manifest records the booted kernel
and a hash of the complete installed-package inventory in `packages.tsv`.

Disabling live maintenance makes immutable image refresh an operational requirement:
the pool owner must rebuild and validate at least weekly and promptly for applicable
critical security updates. A source merge does not update a deployed image. Retain the
previous immutable image for rollback and record each pool's selected image and build
date. Do not deploy this policy without an owner for that refresh cadence. This policy
does not apply to long-lived hosts and does not claim a particular kernel regression is fixed.

## Logging and incident response

Controller logs go to Log Analytics. Linux bootstrap and runner diagnostic tails are written to the serial console and captured by managed boot diagnostics. Windows records bootstrap exit status in `C:\ProgramData\GitHubRunner\result.json` and runner diagnostics under `C:\actions-runner\_diag`; these are ephemeral and are not automatically exported to Log Analytics. Collect a failing qualification VM’s diagnostics through an approved operator route before cleanup when needed. GitHub retains workflow job logs.

On suspected runner compromise:

1. Remove repository access from the runner group.
2. Suspend the controller.
3. Preserve relevant GitHub and Azure logs before deleting resources.
4. Rotate any workflow-accessible credentials used by the affected repository.
5. Rebuild the managed image and redeploy before restoring access.

## Windows credential and image boundary

Windows activation requires a separate explicit access review. Azure generates a unique local administrator password per ephemeral VM deployment from a `securestring` default containing `newGuid()` and a fixed complexity prefix. The controller sends the expression only; it never creates, reads, stores, logs, or transmits the resulting password. No credential is an output or pool field, and secure parameters are hidden from deployment history. The account credential dies with the VM; there is no shared password or persistent credential vault to rotate. Azure operator recovery, if needed, is a separate approved action.

A new deployment evaluates a new default. The controller therefore submits each Windows deployment PUT once, then reads/polls the deterministic deployment name even if its response was lost. It does not repeat that PUT automatically. Failed/canceled deployments are canceled to terminal state before VM/NIC/IP deletion. A later job retry creates a new runner/resource name and credential. Tests verify this no-re-PUT contract and absence of password parameters/outputs. Live qualification must still verify Azure retry/restart behavior.

Windows needs ARM deployment lifecycle operations in the runner resource group. Bicep adds only the six documented deployment read/write/delete/cancel/operation-read actions to the existing lifecycle role when at least one Windows profile is enabled. With every Windows profile disabled, those actions are absent. The role and assignment remain scoped to the runner resource group. Review the what-if permission delta before enabling Windows; disabling all Windows profiles and reprovisioning removes the extra actions. Existing resource-type permissions still constrain what the template can create. Windows needs no new Key Vault permission, role-assignment permission, or subscription-wide access.

Packer's Windows build uses temporary WinRM-over-TLS restricted to one approved builder IPv4 `/32`, with an ephemeral self-signed certificate. Executing that build requires explicit operator approval of temporary credential handling, skipping server certificate-chain/hostname validation for this connection, and ingress. The builder fails validation by default; only after that exact approval may the operator pass `allow_unverified_winrm_certificate=true`. Source CI supplies this flag for no-resource template validation only and never opens a WinRM connection. No credential is checked into this repository. Remove the build account, temporary WinRM listeners, and their TLS private keys before capture; verify that no private credential or registration state remains in the generalized image. First boot removes build remoting listeners, disables WinRM/RDP, and refuses an image retaining the build account. Do not route production jobs until this is tested on an actual Azure VM.

Windows jobs run as SYSTEM in a disposable VM, without an interactive desktop session. This is privileged execution, like Linux passwordless sudo, not a process sandbox. The image contains pinned GitHub runner, .NET SDK, Node, Git, and PowerShell tools. No Visual Studio/Build Tools or Windows SDK workload is installed or licensed by this change. Those workloads need a separate compatible image, license/entitlement review, and memory/disk qualification. Windows automatic updates are disabled during jobs; the same immutable image refresh ownership and security-update cadence described above applies.
