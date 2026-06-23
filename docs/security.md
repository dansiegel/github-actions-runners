# Security

## Private-first enforcement

`visibility: public` on any user or organization account is rejected unless `publicVisibilityOptIn` includes an explicit reviewed approval. This keeps the initial artifact private while preserving a reviewed path to open it later.

## Secret handling

Do not commit GitHub tokens, Azure secrets, tenant IDs, subscription IDs, private repo names, certificates, or private keys. Runner registration uses a token provider reference:

- `command`: VM-executable command/script returns a short-lived registration token. Live apply requires `vmCredentialSource.type: managedIdentityGitHubApp` so the VM uses managed identity and Key Vault for GitHub App material instead of relying on an operator environment variable.
- `env`: runtime environment variable supplies the token. Schema-valid, but rejected for live apply until a VM-safe source exists.
- `keyVault`: Azure Key Vault lookup supplies the token. Schema-valid, but rejected for live apply until translated into a managed identity VM contract.

Token providers run with this per-binding context and must write only the short-lived GitHub Actions registration token to stdout:

- `GHA_REGISTRATION_TOKEN_ENDPOINT`: repo/org REST endpoint to POST for a registration token
- `GHA_RUNNER_URL`: runner configuration URL used by `config.sh`
- `GHA_RUNNER_SCOPE`: repository or organization
- `GHA_BINDING_NAME`: local sanitized binding name
- `GHA_TARGET_KIND`, `GHA_TARGET_OWNER`, `GHA_TARGET_REPOSITORY`: target metadata for auditing or provider routing

The committed example uses `scripts/github-runner-token.example.sh`, which is designed for execution on the VM. It uses managed identity to read GitHub App id, private key, and installation id from Key Vault, exchanges them for a GitHub App installation access token, and outputs only the short-lived runner registration token. Live apply validates the declared VM credential-source fields before Azure mutation; a command provider that only depends on local `GITHUB_TOKEN` is rejected.

## Live apply guardrails

Before any paid Azure mutation, apply requires:

- `--confirm-spend I_ACCEPT_AZURE_SPEND`
- configured tenant/subscription resolved from config or env
- active `az account show` tenant/subscription equals configured values
- resource-group-scoped deployment identity in config
- all runner bindings include URL, token endpoint, token provider inputs, and VM credential-source prerequisites for VM-executable command providers
- command providers declare and resolve `managedIdentityGitHubApp` prerequisites; env providers, direct Key Vault providers, and command providers without a VM credential source are rejected before Azure mutation

The code checks these before running Azure mutation commands.

## Least privilege identity

Use a deployment identity scoped to the configured resource group. It should have only the permissions needed for resource group deployments, VMSS, network, and managed identity resources in that group. Do not use owner-level credentials for routine apply.

## Fail-closed bootstrap

The generated cloud-init exits non-zero when runner URL or token provider output is missing. This prevents silent idle hosts that never register as runners.
