# Operations

## Bootstrap and deploy

1. Prepare a deployment-private runner-pool JSON file, or choose the single-pool command-line values.
2. Select the exact Azure subscription and target GitHub organization.
3. Run the deployment script with bootstrap-only enabled.
4. Add the three GitHub App secrets to the output Key Vault.
5. Run the deployment script again without bootstrap-only.
6. Grant the GitHub runner group access to intended trusted repositories.
7. Run a smoke workflow selecting exactly one complete profile label for each enabled pool before changing production workflow labels.

The deployment scripts refuse mutation unless the caller repeats the subscription passed through `-SubscriptionId` / `--subscription-id`. They create a new timestamped managed image and never delete an old image automatically.

## GitHub App setup

Create a GitHub App owned by the target organization with:

- Organization permissions → Self-hosted runners: Read and write
- Installation target: the target organization
- Repository access: repositories allowed to use the runner group

No webhook is required; each enabled pool has an independent listener in the shared controller, long-polling its runner-scale-set message service.

## Preflight

Confirm selected account, region, and quota:

```bash
az account show --query '{subscription:id,name:name,tenant:tenantId}' --output table
az vm list-usage --location '<region>' --output table
az vm list-skus --location '<region>' --resource-type virtualMachines --all --output table
```

Estimate simultaneous demand across every enabled profile. Uncapped profiles do not have a configured peak; use workload concurrency, or set explicit positive caps where needed. Verify regional and family quotas and leave headroom for other Azure workloads and transient replacements. Keep the example one-core profiles disabled until a compatible Gen2/NVMe Compute Gallery image and subscription are qualified.

## Observe the shared controller

List the deployed shared controller:

```bash
az containerapp list \
  --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  --query "[?tags.purpose=='github-runner-scale-set-listener'].{name:name,profiles:tags.'runner-pool-count'}" \
  --output table
```

Follow all pool listeners using the controller name returned above:

```bash
az containerapp logs show \
  --name '<controller-name>' \
  --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  --follow
```

Expected events include `Runner scale controller ready`, desired-capacity reconciliation, VM provisioning, job started/completed, and VM deletion. Each event includes the scale-set context in its controller stream.

## Verify scale-to-zero

After all GitHub jobs finish, allow several minutes for Azure deletion operations, then run:

```bash
az vm list \
  --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  --query "[?tags.'managed-by'=='gha-runner-scale-controller'].{name:name,pool:tags.'runner-scale-set',runner:tags.'github-runner-name'}" \
  --output table
```

The result must be empty. Also verify no tagged NICs or public IPs remain:

```bash
az resource list \
  --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  --tag managed-by=gha-runner-scale-controller \
  --query '[].{name:name,type:type}' \
  --output table
```

## Cleanup behavior

- `JobCompleted` asynchronously deletes the VM, NIC, and public IP.
- The OS disk and NIC are additionally configured with Azure `deleteOption=Delete`.
- Runner bootstrap powers off the VM whenever the runner exits, including failure paths.
- Reconciliation runs every minute and deletes stopped/deallocated VMs belonging to that pool.
- Every VM deletion also removes that runner's GitHub registration. A create that fails does the same for the registration it just minted, so a dead JIT runner cannot keep a job assigned or accumulate on the organization runner list.
- Quota errors pause provisioning for 10 minutes, allocation failures for 5 minutes, and other create failures for 2 minutes. The listener stays online during the pause.
- A 12-hour hard lifetime limits the cost of a stuck runner.

Do not manually delete a running VM unless the associated job is known to be abandoned. Ordinary scale-down deliberately protects busy and restart-unknown VMs.

## Change or remove pools

Pool order does not affect the shared controller resource name. Adding a profile is an ordinary reprovision. To disable or retire a profile safely:

1. Remove repository access to the profile or change every workflow away from all of its labels. The `avp-linux` and `avp-linux-l` labels belong to the same profile; existing consumers have no migration deadline.
2. Let its jobs finish and verify no Azure VM has `runner-scale-set=<pool-name>`.
3. Set `enabled` to false, or remove the profile from JSON, and reprovision the shared controller.
4. Delete the logical scale set in GitHub organization settings if it is no longer needed.

Keep `name` stable when changing a label, SKU, or image: it is the logical scale-set identity and Azure cleanup tag. In particular, preserve `name: "avp-linux"` when adding its `avp-linux-l` alias; do not create a competing scale set. Follow the [compatibility migration](migration.md#preserve-existing-avp-linux-consumers).

A disabled or removed profile has no running listener or reconciler. Drain it first so active VMs do not lose their cleanup owner.

### Migrate older controller-per-pool deployments

The original `gha-scale-controller-<environment-token>` app is updated in place. ARM incremental deployments do not delete extra apps created by older per-pool loops. Before activating the shared controller, stop routing new work, drain all affected pools, then explicitly stop and retire those extra apps after resolving their names from the old `runner-scale-set` tags. Do not run an old per-pool controller and the shared listener against the same scale set. Keep only the original app, verify one healthy listener per enabled profile, and restore workflow access after smoke testing.

## Suspend provisioning

To suspend one profile, stop routing work to it, drain its VMs, then set `enabled` to false and reprovision. To suspend the entire platform, first drain every profile, then scale the shared controller down:

```bash
az containerapp update \
  --name '<controller-name>' \
  --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  --min-replicas 0 \
  --max-replicas 0
```

Restore the Bicep-declared one-replica controller with `azd provision`. While it is suspended, finished VMs power off but are not reconciled/deleted until it returns. Suspending the shared controller affects every enabled profile.

## Rotate the GitHub App key

1. Generate a new private key in GitHub App settings.
2. Update `github-app-private-key` in Key Vault using `az keyvault secret set --file`.
3. Reprovision or restart the shared controller revision.
4. Verify every listener creates a message session.
5. Revoke the old key in GitHub.

## Refresh the runner image

Rerun the full deployment script. It builds one timestamped managed image, updates the shared `RUNNER_IMAGE_ID`, and rolls the Container App revision. Pools with a nonempty `imageId` override keep that image; only inheriting pools use the new default for newly created VMs. Pin the currently qualified image in the private `avp-linux` pool entry before changing the shared default so legacy consumers retain their image. Existing jobs continue on their original image. Qualify per-pool image overrides before enabling a new VM family, including the disabled Gen2/NVMe small profiles.

After no VMs reference an old managed image, list and delete it explicitly if desired. Image deletion is intentionally not automated because it is destructive.

## Common failures

| Symptom | Likely cause | Action |
|---|---|---|
| Jobs stay queued and no VM appears | Shared controller stopped, profile disabled, runner-group access missing, wrong `runs-on`, or GitHub App permission missing | Inspect the shared controller, the profile setting, and GitHub runner group |
| VM creation returns quota/capacity error | Combined pool capacity exceeds regional/family quota or SKU capacity. `avp-linux` at 12 `Standard_D4s_v5` runners is 48 cores against a 50-core `standardDSv5Family` limit in `eastus2`, so a replacement VM has no headroom | The controller pauses creates after a quota error. Raise the family quota or lower pool capacity before expecting replacements to succeed |
| Jobs stay assigned and new VMs stop without starting a job | A previous create registered a GitHub runner, then the VM died or the listener exited before that runner connected. GitHub keeps the job on the dead registration | Confirm controller logs show `Removed GitHub runner registration`. Delete leftover `avp-linux-*` runners that have no VM |
| VM exists but runner never becomes online | Image/bootstrap failure or GitHub connectivity | Inspect VM boot diagnostics and serial console output |
| VM deletion fails | Controller role drift or Azure operation conflict | Restore Bicep roles; reconciler retries on later passes |
| Container App cannot start | Missing Key Vault secret, RBAC propagation, or ACR pull failure | Verify secret names, role assignments, and image reference |

## Destroy

Before permanent teardown, remove repository access from every runner group and delete logical runner scale sets from GitHub organization settings so jobs cannot target ownerless labels.

Destroy is separate from deployment and requires `-SubscriptionId` / `--subscription-id` plus exact resource-group and subscription confirmation. Key Vault purge protection means its soft-deleted vault cannot be immediately purged or recreated with the same name. Do not use resource-group deletion as a routine scale-to-zero mechanism.

## Windows profile qualification

All eight Windows profiles are disabled initially. They add listeners to the same controller only after activation; no second controller is required. Keep the existing Linux source revision, image IDs, labels, scale-set ownership, and jobs untouched while testing the isolated Windows source branch.

1. Verify East US 2 image/SKU availability and quota with read-only Azure queries. The initial source is pinned to `MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:26100.33438.260905`, verified in East US 2 on 2026-10-05 as x64 Gen2 with a 127-GiB OS disk and no purchase plan. Recheck availability before building; confirm the resulting custom image still fits 128 GiB. The small F1als_v7 entries additionally need a qualified Gen2/NVMe Compute Gallery image; the managed-image builder alone does not qualify them.
2. Agree a bounded image-build plus smoke-test allocation and cleanup deadline, including Windows PAYG licensing, disk/IP lifetime, retained image storage, logs, and egress. No live provisioning is part of repository CI. Do not start an uncapped production Windows fleet as an image test.
3. Obtain explicit approval for the build access described in [security](security.md#windows-credential-and-image-boundary). An operator executes `packer init` and `packer build image/windows-runner.pkr.hcl` with subscription, output resource group/name, exact base version, and `build_source_cidr` set to that operator's current public IPv4 `/32`. The scripts do not invoke this build automatically. Packer must delete the temporary build resource group, IP, and access after success or failure; inspect remnants on failure.
4. Verify the image manifest, tool versions, at least 15 GiB free workspace, absent build account/registration/JIT/private credentials, disabled runtime remoting, and startup task. The initial toolchain supports lightweight command-line .NET/Node/Git/PowerShell work, not all Visual Studio or UI workloads.
5. Approve the Azure-generated, VM-lifetime local administrator credential mechanism. No password entry or secret-value handoff is needed because the value is generated inside Azure and never exposed to the controller. Approve only `Microsoft.Resources/deployments/read`, `/write`, `/delete`, `/cancel/action`, `/operations/read`, and `/operationstatuses/read` in the runner resource group. The source update does not grant these rights. No new Key Vault access is required.
6. In private pool configuration, set the selected Windows profile's qualified `imageId`. Temporarily use an explicit `maxRunners: 1` only for the agreed qualification test; this is an operator-chosen test bound, not a default fleet cap. Enable only that test profile and roll the tested controller source through the normal what-if/drain/single-owner process.
7. Route one controlled job to the exact label, initially `avp-windows-lp`. Verify SDK checkout/build, JIT one-job behavior, version mismatch fail-closed behavior, exit/shutdown, cancellation/restart cleanup, and deletion of VM/disk/NIC/IP/deployment metadata. Confirm Linux jobs/ID/labels/image remain identical. Repeat other sizes only within the approved window. The 2-GiB profile is not a Visual Studio Build Tools host; qualify its actual lightweight workload separately.
8. Disable the test profile and remove qualification resources/access on completion unless persistent Windows activation is separately approved. Retain the image only for an agreed period; verify all VM-local credentials disappeared with their VMs. Remove temporary per-profile caps only when approving ordinary demand-driven use. No global cap or extra controller is introduced.

Example budgeting: four total allocated D4s_v5 Windows VM-hours, conservatively costed with P20 and public IPv4 throughout, are approximately $1.89. This includes boot and cleanup **only if they fit inside those four hours**. Retaining up to 128 GiB of used managed-image data for one day adds at most about $0.51 at $0.12/GiB-month; logs, egress, build storage/operations, and tax must be budgeted separately. These are estimates, not an Azure-enforced spending cutoff. Reserve cleanup time and verify zero tagged resources; stopped but allocated VMs/disks/IPs can continue billing.
