# Operations

## Validate and preview

```bash
./scripts/validate-config.sh --config config/runners.example.yaml
./scripts/render-plan.sh --config config/runners.example.yaml --out artifacts/plan.json
./scripts/deploy-azure.sh --config config/runners.example.yaml --dry-run
./scripts/destroy-azure.sh --config config/runners.example.yaml --dry-run
```

Dry-run commands do not call Azure mutation commands.

## Apply

Live apply is approval-gated and spend-gated:

```bash
./scripts/deploy-azure.sh --config config/runners.yaml --apply --confirm-spend I_ACCEPT_AZURE_SPEND
```

Expected preconditions:

1. `az login` is active for the configured tenant and subscription.
2. `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` or literal reviewed non-secret values resolve in config.
3. Token provider commands/scripts exist and produce short-lived GitHub runner registration tokens at runtime.
4. The deployment identity is scoped to the configured resource group.


## Shared package cache operations

The V1 cache is VM-local at `/mnt/actions-cache/packages`; it does not require a live Azure file share, storage account, or extra secret. To verify from rendered evidence, inspect `artifacts/plan.json` for `sharedPackageCache` and inspect rendered cloud-init for the cache root, exported package-manager variables, `chown -R`, `find ... -mtime`, and the apt cache config line. On a live VM, operators can validate with `du -sh /mnt/actions-cache/packages` and `find /mnt/actions-cache/packages -maxdepth 2 -type d`.

Rollback is safe: deleting the VMSS or resource group removes the VM-local cache with the runners. No separate cache storage must be destroyed.

## Teardown

Azure teardown:

```bash
./scripts/destroy-azure.sh --config config/runners.yaml --apply --confirm-resource-group gha-runners-dev --confirm-spend I_ACCEPT_AZURE_SPEND
```

GitHub-side cleanup is still required after Azure teardown. Remove stale self-hosted runners from each repository/org and verify organization runner groups no longer contain hosts from the destroyed VMSS bindings. Future automation should reconcile GitHub runner registrations after destroy.

## Rollback

For a bad apply, destroy the resource group using the guarded destroy command, then unregister stale GitHub runners from repository/org settings. Since v1 is fixed-capacity, rollback is resource group delete plus GitHub runner cleanup.
