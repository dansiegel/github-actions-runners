#!/usr/bin/env bash
set -euo pipefail
# Example VM-executable provider. Do not commit real tokens or keys.
# Contract inputs supplied by deploy validation and cloud-init:
# - GHA_REGISTRATION_TOKEN_ENDPOINT: GitHub REST endpoint for this repo/org registration token
# - GHA_RUNNER_URL: runner config URL, for audit/log context only
# - GHA_RUNNER_SCOPE: repository or organization
# - GHA_BINDING_NAME: sanitized local binding name
# - AZURE_KEY_VAULT_NAME: Key Vault reachable by this VM managed identity
# - AZURE_CLIENT_ID: optional user-assigned managed identity client id
# - GITHUB_APP_ID_SECRET_NAME, GITHUB_APP_PRIVATE_KEY_SECRET_NAME, GITHUB_APP_INSTALLATION_ID_SECRET_NAME
# The provider must write ONLY the short-lived GitHub Actions registration token to stdout.

for name in GHA_REGISTRATION_TOKEN_ENDPOINT GHA_RUNNER_URL AZURE_KEY_VAULT_NAME GITHUB_APP_ID_SECRET_NAME GITHUB_APP_PRIVATE_KEY_SECRET_NAME GITHUB_APP_INSTALLATION_ID_SECRET_NAME; do
  if [ -z "${!name:-}" ]; then
    echo "$name is required" >&2
    exit 1
  fi
done

metadata_url="http://169.254.169.254/metadata/identity/oauth2/token"
metadata_query="api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net"
if [ -n "${AZURE_CLIENT_ID:-}" ]; then
  metadata_query="${metadata_query}&client_id=${AZURE_CLIENT_ID}"
fi

kv_bearer="$(curl -fsSL -H Metadata:true "${metadata_url}?${metadata_query}" | jq -er '.access_token')"

kv_secret() {
  local secret_name="$1"
  curl -fsSL \
    -H "Authorization: Bearer ${kv_bearer}" \
    "https://${AZURE_KEY_VAULT_NAME}.vault.azure.net/secrets/${secret_name}?api-version=7.4" | jq -er '.value'
}

github_app_id="$(kv_secret "$GITHUB_APP_ID_SECRET_NAME")"
github_private_key="$(kv_secret "$GITHUB_APP_PRIVATE_KEY_SECRET_NAME")"
github_installation_id="$(kv_secret "$GITHUB_APP_INSTALLATION_ID_SECRET_NAME")"

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

now="$(date +%s)"
iat="$((now - 60))"
exp="$((now + 540))"
header='{"alg":"RS256","typ":"JWT"}'
payload="{\"iat\":${iat},\"exp\":${exp},\"iss\":\"${github_app_id}\"}"
unsigned="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
private_key_file="$(mktemp)"
trap 'rm -f "$private_key_file"' EXIT
printf '%s\n' "$github_private_key" > "$private_key_file"
signature="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$private_key_file" -binary | b64url)"
app_jwt="${unsigned}.${signature}"

install_bearer="$(curl -fsSL \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${app_jwt}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${github_installation_id}/access_tokens" | jq -er '.token')"

curl -fsSL \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${install_bearer}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${GHA_REGISTRATION_TOKEN_ENDPOINT}" | jq -er '.token'
