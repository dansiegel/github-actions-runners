# Operations

## Bootstrap and deploy

1. Prepare a deployment-private runner-pool JSON file, or choose the single-pool command-line values.
2. Select the exact Azure subscription and target GitHub organization.
3. Run the deployment script with bootstrap-only enabled.
4. Add the three GitHub App secrets to the output Key Vault.
5. Run the deployment script again without bootstrap-only.
6. Grant the GitHub runner group access to intended trusted repositories.
7. Run a smoke workflow for each pool before changing production workflow labels.

The deployment scripts refuse mutation unless the caller repeats the subscription passed through `-SubscriptionId` / `--subscription-id`. They create a new timestamped managed image and never delete an old image automatically.

## GitHub App setup

Create a GitHub App owned by the target organization with:

- Organization permissions → Self-hosted runners: Read and write
- Installation target: the target organization
- Repository access: repositories allowed to use the runner group

No webhook is required; each controller long-polls its runner-scale-set message service.

## Preflight

Confirm selected account, region, and quota:

```bash
az account show --query '{subscription:id,name:name,tenant:tenantId}' --output table
az vm list-usage --location '<region>' --output table
az vm list-skus --location '<region>' --resource-type virtualMachines --all --output table
```

Calculate peak demand across every pool. For example, eight D2s v5 runners plus four D4s v5 runners request 32 Dsv5-family vCPUs. Leave headroom for other Azure workloads and transient replacement operations.

## Observe controllers

List all deployed pool controllers:

```bash
az containerapp list \
  --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  --query "[?tags.purpose=='github-runner-scale-set-listener'].{name:name,pool:tags.'runner-scale-set',size:tags.'runner-vm-size',max:tags.'runner-max-capacity'}" \
  --output table
```

Follow one pool's logs using the name returned above:

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
- A 12-hour hard lifetime limits the cost of a stuck runner.

Do not manually delete a running VM unless the associated job is known to be abandoned. Ordinary scale-down deliberately protects busy and restart-unknown VMs.

## Change or remove pools

Pool order is stable infrastructure configuration. Pool zero preserves the original controller resource name for upgrade compatibility. Renaming pool zero updates that controller in place; reordering pools can move a controller to a different queue and should be treated as a controlled migration.

Adding a pool is an ordinary reprovision. To retire a pool safely:

1. Remove repository access to the pool or change every workflow away from its name.
2. Let its jobs finish and verify no Azure VM has `runner-scale-set=<pool-name>`.
3. Remove the pool from JSON and reprovision.
4. Delete the obsolete Container App explicitly after resolving its name from the `runner-scale-set` tag.
5. Delete the logical scale set in GitHub organization settings if it is no longer needed.

Step 4 is explicit because ARM incremental deployments do not delete resources removed from a loop. Never delete a controller while its pool still has running VMs; it owns their reconciliation and cleanup.

## Suspend provisioning

First remove repository access or change workflows away from the target pool. Then scale only its controller down:

```bash
az containerapp update \
  --name '<controller-name>' \
  --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  --min-replicas 0 \
  --max-replicas 0
```

Restore the Bicep-declared one-replica controller with `azd provision`. While it is suspended, finished VMs power off but are not reconciled/deleted until it returns.

## Rotate the GitHub App key

1. Generate a new private key in GitHub App settings.
2. Update `github-app-private-key` in Key Vault using `az keyvault secret set --file`.
3. Reprovision or restart every controller revision.
4. Verify every listener creates a message session.
5. Revoke the old key in GitHub.

## Refresh the runner image

Rerun the full deployment script. It builds one timestamped managed image, points every controller at its resource ID, and rolls the Container App revisions. Existing jobs continue on the old image; only newly created VMs use the new image.

After no VMs reference an old managed image, list and delete it explicitly if desired. Image deletion is intentionally not automated because it is destructive.

## Common failures

| Symptom | Likely cause | Action |
|---|---|---|
| Jobs stay queued and no VM appears | Pool controller stopped, runner-group access missing, wrong `runs-on`, or GitHub App permission missing | Inspect the controller tagged for that pool and GitHub runner group |
| VM creation returns quota/capacity error | Combined pool capacity exceeds regional/family quota or SKU capacity | Reduce a pool, request quota, or select an approved region/SKU |
| VM exists but runner never becomes online | Image/bootstrap failure or GitHub connectivity | Inspect VM boot diagnostics and serial console output |
| VM deletion fails | Controller role drift or Azure operation conflict | Restore Bicep roles; reconciler retries on later passes |
| Container App cannot start | Missing Key Vault secret, RBAC propagation, or ACR pull failure | Verify secret names, role assignments, and image reference |

## Destroy

Before permanent teardown, remove repository access from every runner group and delete logical runner scale sets from GitHub organization settings so jobs cannot target ownerless labels.

Destroy is separate from deployment and requires `-SubscriptionId` / `--subscription-id` plus exact resource-group and subscription confirmation. Key Vault purge protection means its soft-deleted vault cannot be immediately purged or recreated with the same name. Do not use resource-group deletion as a routine scale-to-zero mechanism.
