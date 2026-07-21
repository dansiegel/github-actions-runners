# Operations

## Bootstrap and deploy

1. Select the exact Azure subscription.
2. Run the deployment script with bootstrap-only enabled.
3. Add the three GitHub App secrets to the output Key Vault.
4. Run the deployment script again without bootstrap-only.
5. Grant the GitHub runner group access to the intended repositories.
6. Run the smoke workflow before changing production workflow labels.

The deployment scripts refuse mutation unless the caller repeats subscription `d901cbec-f20d-4272-a0b4-9ee06b850880`. They create a new timestamped managed image and never delete an old image automatically.

## GitHub App setup

Create a GitHub App owned by AvantiPoint with:

- Organization permissions → Self-hosted runners: Read and write
- Installation target: AvantiPoint
- Repository access: the repositories allowed to use the runner group

No webhook is required; the controller long-polls the runner-scale-set message service.

## Preflight

Confirm the selected account and quota:

```bash
az account show --query '{subscription:id,name:name,tenant:tenantId}' --output table
az vm list-usage --location eastus2 --query "[?contains(localName, 'Total Regional') || contains(localName, 'DSv5')]" --output table
```

A 20-runner burst of `Standard_D2s_v5` needs 40 vCPUs. Request quota before migration if the available limit is lower.

## Observe the controller

```bash
az containerapp logs show \
  --name "$(azd env get-value RUNNER_CONTROLLER_NAME)" \
  --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  --follow
```

Expected events include `Runner scale controller ready`, desired-capacity reconciliation, VM provisioning, job started/completed, and VM deletion.

## Verify scale-to-zero

After all GitHub jobs finish, allow several minutes for Azure deletion operations, then run:

```bash
az vm list \
  --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  --query "[?tags.'managed-by'=='gha-runner-scale-controller'].{name:name,runner:tags.'github-runner-name'}" \
  --output table
```

The result must be empty. Also verify there are no tagged NICs or public IPs:

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
- Reconciliation runs every minute and deletes stopped/deallocated VMs.
- A 12-hour hard lifetime limits the cost of a stuck runner.

Do not manually delete a running VM unless the associated job is known to be abandoned. Ordinary scale-down deliberately protects busy and restart-unknown VMs.

## Suspend provisioning

To stop accepting new jobs without deleting active runner VMs, first remove repository access from the GitHub runner group or change workflows away from `avp-linux`. Then scale the controller down:

```bash
az containerapp update \
  --name "$(azd env get-value RUNNER_CONTROLLER_NAME)" \
  --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  --min-replicas 0 \
  --max-replicas 0
```

Restore the Bicep-declared one-replica controller with `azd provision`. While the controller is suspended, finished VMs power off but are not reconciled/deleted until it returns.

## Rotate the GitHub App key

1. Generate a new private key in GitHub App settings.
2. Update `github-app-private-key` in Key Vault using `az keyvault secret set --file`.
3. Restart the Container App revision.
4. Verify the listener creates a message session.
5. Revoke the old key in GitHub.

## Refresh the runner image

Rerun the full deployment script. It builds a timestamped managed image, points the controller at its resource ID, and rolls the Container App revision. Existing jobs continue on the old image; only newly created VMs use the new image.

After no VMs reference an old managed image, list it and delete it explicitly if desired. Image deletion is intentionally not automated because it is destructive.

## Common failures

| Symptom | Likely cause | Action |
|---|---|---|
| Jobs stay queued and no VM appears | Controller stopped, runner-group access missing, or GitHub App permission missing | Inspect controller logs and GitHub runner group |
| VM creation returns quota/capacity error | Insufficient regional/Dsv5 quota or SKU capacity | Request quota or select an approved region/SKU |
| VM exists but runner never becomes online | Image/bootstrap failure or GitHub connectivity | Inspect VM boot diagnostics and serial console output |
| VM deletion fails | Controller role drift or Azure operation conflict | Restore Bicep roles; reconciler retries on later passes |
| Container App cannot start | Missing Key Vault secret, RBAC propagation, or ACR pull failure | Verify secret names, role assignments, and image reference |

## Destroy

Before permanent teardown, remove repository access from the GitHub runner group and delete the logical runner scale set from GitHub organization runner settings so jobs cannot target an ownerless label.

Destroy is separate from deployment and must require exact resource-group and subscription confirmation. Key Vault purge protection means its soft-deleted vault cannot be immediately purged or recreated with the same name. See the destroy scripts before running them; do not use resource-group deletion as a routine scale-to-zero mechanism.
