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

Packer's Windows build uses temporary WinRM-over-TLS restricted to one approved builder IPv4 `/32`, with an ephemeral self-signed certificate. `skip_create_build_key_vault=true` avoids the plugin's default build vault and its broad key/secret access policy. The Azure Custom Script extension executes only repository bootstrap code and the approved source CIDR; no password or private key enters that command or VM user data. The guest generates a non-exportable, four-hour TLS key and enables only HTTPS/5986 with NTLM authentication, encrypted transport, and a matching guest firewall rule. Packer retains its existing temporary administrator credential flow. The temporary local administrator token policy is reset before capture.

Executing that build requires explicit operator approval of temporary credential handling, skipping server certificate-chain/hostname validation for this connection, and ingress. The builder fails validation by default; only after that exact approval may the operator pass `allow_unverified_winrm_certificate=true`. Source CI supplies this flag for no-resource template validation only and never opens a WinRM connection. No credential is checked into this repository. Remove the temporary WinRM listeners/firewall rule and TLS private keys before capture; verify that no private credential or registration state remains in the generalized image. First boot removes build remoting listeners, disables WinRM/RDP, and refuses an account still named `packer`. Do not route production jobs until this is tested on an actual Azure VM.

Image finalization identifies the build account by SID before Sysprep. Azure [renames the built-in RID500 Administrator to the provisioning username](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/serial-console-cmd-ps-commands#verify-user-account-is-enabled), so deleting `packer` by name is not valid. After confirmed Server Sysprep completion, ordinary temporary accounts are deleted; RID500 is restored to `Administrator` and disabled, with account/name/SID readback required. [Server Sysprep clears the built-in password](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/enable-and-disable-the-built-in-administrator-account?view=windows-11#configuring-the-built-in-administrator-password); no replacement password is generated or transmitted. Client editions, other special accounts, name collisions, identity changes, and failed cleanup readback stop capture. The next Azure deployment provisions its own administrator name and secure per-VM credential. WinRM stages the trusted finalizer before generalization. Finalization then uses the existing Azure VM agent through managed Run Command, so retiring remoting does not destroy its completion channel. A lost connection is never evidence that cleanup succeeded.

Build TLS uses an explicit software-CNG machine key. Before generalization, the finalizer matches the owned certificate to its listener, opens its key, and verifies its exact backing filename. After Sysprep, it deletes that key through the retained handle, requires provider-level absence, and removes only the recorded orphaned file if one remains. Checked directory enumeration and a second provider lookup must both confirm absence before the public certificate is removed. A missing-key message, `HasPrivateKey`, `File.Exists=false`, or certificate disappearance alone is not proof. Access errors and failed deletion/readback stop capture; there is no key export, ACL change, directory-wide deletion, or unrelated certificate cleanup.

Windows jobs run as SYSTEM in a disposable VM, without an interactive desktop session. This is privileged execution, like Linux passwordless sudo, not a process sandbox. The image contains pinned GitHub runner, .NET SDK, Node, Git, and PowerShell tools. No Visual Studio/Build Tools or Windows SDK workload is installed or licensed by this change. Those workloads need a separate compatible image, license/entitlement review, and memory/disk qualification. Windows automatic updates are disabled during jobs; the same immutable image refresh ownership and security-update cadence described above applies.

The operator-side finalization helper uses the existing Azure CLI login without reading or logging a token. Before submitting, it verifies the exact Packer-tagged Windows VM and effective `Microsoft.Compute/virtualMachines/runCommands/read`, `/write`, and `/delete` permissions at that VM. It adds no role, vault, credential, blob/SAS, or ingress. A single PUT creates an attempt-named command; an uncertain response is reconciled by GET rather than resubmitting. The guest verifies the staged script SHA-256 and atomically records a one-shot attempt before mutations. Capture requires managed execution `Succeeded`, exit code zero, a matching completion record with every cleanup readback true, and confirmed deletion of that managed command. Failed or timed-out attempts cannot repeat Sysprep on the same builder. Losing the VM-agent channel also rejects capture.
