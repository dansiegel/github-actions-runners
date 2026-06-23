# Testing

Run local checks from the repository root:

```bash
python -m unittest discover -s tests
./scripts/validate-config.sh --config config/runners.example.yaml
./scripts/render-plan.sh --config config/runners.example.yaml --out artifacts/plan.json
./scripts/deploy-azure.sh --config config/runners.example.yaml --dry-run
./scripts/destroy-azure.sh --config config/runners.example.yaml --dry-run
```

Targeted negative tests cover:

- public user visibility rejection
- public organization visibility rejection
- missing runner URL fail-closed behavior
- missing token provider fail-closed behavior
- live apply spend confirmation before Azure CLI mutation calls
- missing token provider command before Azure CLI mutation calls
- command provider nonzero or empty output before Azure group/network/VMSS mutation calls
- unset env provider before any Azure CLI call
- Key Vault/env provider modes fail the VM-executable provider contract before Azure group/network/VMSS mutation calls
- per-binding provider context passed through `GHA_*` environment variables
- command provider script content is provisioned into rendered cloud-init under `/usr/local/bin`
- cloud-init runner download uses pinned `linux-x64`/`linux-arm64` archive names and verifies sha256 before extraction
- rendered plan includes the shared package cache contract at `/mnt/actions-cache/packages`
- rendered cloud-init creates shared package-manager cache directories, applies ownership, exports cache environment variables, configures apt archives, and includes prune/sizing guards
