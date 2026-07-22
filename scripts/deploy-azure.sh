#!/usr/bin/env bash
set -Eeuo pipefail

SUBSCRIPTION_ID="d901cbec-f20d-4272-a0b4-9ee06b850880"
ENVIRONMENT_NAME="prod"
LOCATION="eastus2"
RESOURCE_GROUP="gha-runners-prod"
SSH_PUBLIC_KEY_FILE="${HOME}/.ssh/id_ed25519.pub"
MODE="dry-run"
BOOTSTRAP_ONLY="false"
CONFIRM_SUBSCRIPTION=""
EXISTING_RUNNER_IMAGE_ID=""

usage() {
  echo "usage: $0 [--dry-run|--apply] [--bootstrap-only] [--environment name] [--location region] [--resource-group name] [--ssh-public-key-file path] [--runner-image-id resource-id] [--confirm-subscription subscription-id]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --apply) MODE="apply"; shift ;;
    --bootstrap-only) BOOTSTRAP_ONLY="true"; shift ;;
    --environment) ENVIRONMENT_NAME="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --ssh-public-key-file) SSH_PUBLIC_KEY_FILE="$2"; shift 2 ;;
    --runner-image-id) EXISTING_RUNNER_IMAGE_ID="$2"; shift 2 ;;
    --confirm-subscription) CONFIRM_SUBSCRIPTION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

cat <<EOF
Target subscription: $SUBSCRIPTION_ID
Resource group:      $RESOURCE_GROUP
Location:            $LOCATION
Runner scale set:    avp-linux
Runner capacity:     0 to 12 Standard_D4s_v5 VMs
Runner image:        .NET 10, Node 24, Docker/Buildx, Azure CLI, azd, PowerShell, Aspire
EOF

if [[ "$MODE" != "apply" ]]; then
  echo "Dry run only. No Azure resources were changed."
  echo "Apply with --apply --confirm-subscription $SUBSCRIPTION_ID"
  exit 0
fi

if [[ "$CONFIRM_SUBSCRIPTION" != "$SUBSCRIPTION_ID" ]]; then
  echo "Refusing Azure mutation: --confirm-subscription must exactly equal $SUBSCRIPTION_ID" >&2
  exit 2
fi
if [[ ! -f "$SSH_PUBLIC_KEY_FILE" ]]; then
  echo "SSH public key not found: $SSH_PUBLIC_KEY_FILE" >&2
  exit 2
fi
for command in az azd packer git; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 2; }
done

az account set --subscription "$SUBSCRIPTION_ID"
for namespace in Microsoft.App Microsoft.ContainerRegistry Microsoft.KeyVault Microsoft.Network Microsoft.Compute Microsoft.OperationalInsights; do
  az provider register --namespace "$namespace" --subscription "$SUBSCRIPTION_ID" --wait
done
if ! azd env select "$ENVIRONMENT_NAME" >/dev/null 2>&1; then
  azd env new "$ENVIRONMENT_NAME" --no-prompt
fi

azd env set AZURE_SUBSCRIPTION_ID "$SUBSCRIPTION_ID"
azd env set AZURE_LOCATION "$LOCATION"
azd env set AZURE_RESOURCE_GROUP "$RESOURCE_GROUP"
azd env set ADMIN_SSH_PUBLIC_KEY "$(<"$SSH_PUBLIC_KEY_FILE")"
azd env set GITHUB_ORGANIZATION "AvantiPoint"
azd env set RUNNER_GROUP "default"
azd env set RUNNER_SCALE_SET_NAME "avp-linux"
azd env set RUNNER_MAX_CAPACITY "12"
azd env set RUNNER_VM_SIZE "Standard_D4s_v5"
azd env set RUNNER_VM_PRIORITY "Regular"
azd env set RUNNER_IMAGE_ID "$EXISTING_RUNNER_IMAGE_ID"
azd env set RUNNER_CONTROLLER_IMAGE ""
azd env set DEPLOY_RUNNER_CONTROLLER "false"

# Phase one creates only the low-cost control-plane resources, network, identity,
# registry, and empty Key Vault. It creates no runner VMs.
azd provision --environment "$ENVIRONMENT_NAME" --no-prompt

if [[ "$BOOTSTRAP_ONLY" == "true" ]]; then
  echo "Bootstrap complete. Add the three GitHub App secrets shown in docs/operations.md, then rerun without --bootstrap-only."
  exit 0
fi

VAULT_NAME="$(azd env get-value GITHUB_APP_KEY_VAULT_NAME)"
ACR_NAME="$(azd env get-value AZURE_CONTAINER_REGISTRY_NAME)"
for secret_name in github-app-client-id github-app-private-key github-app-installation-id; do
  az keyvault secret show --vault-name "$VAULT_NAME" --name "$secret_name" --query id --output tsv >/dev/null
done

if [[ -z "$EXISTING_RUNNER_IMAGE_ID" ]]; then
  IMAGE_NAME="gha-runner-$(date -u +%Y%m%d%H%M%S)"
  packer init image/runner.pkr.hcl
  packer build \
    -var "subscription_id=$SUBSCRIPTION_ID" \
    -var "location=$LOCATION" \
    -var "resource_group_name=$RESOURCE_GROUP" \
    -var "managed_image_name=$IMAGE_NAME" \
    image/runner.pkr.hcl
  EXISTING_RUNNER_IMAGE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Compute/images/$IMAGE_NAME"
else
  RESOLVED_IMAGE_ID="$(az resource show --ids "$EXISTING_RUNNER_IMAGE_ID" --query id --output tsv)"
  if [[ "${RESOLVED_IMAGE_ID,,}" != "${EXISTING_RUNNER_IMAGE_ID,,}" ]]; then
    echo "Resolved runner image did not match --runner-image-id" >&2
    exit 2
  fi
  echo "Reusing managed runner image: $EXISTING_RUNNER_IMAGE_ID"
fi

CONTROLLER_TAG="$(git rev-parse --short=12 HEAD 2>/dev/null || printf 'local')-$(date -u +%Y%m%d%H%M%S)"
az acr build --registry "$ACR_NAME" --image "runner-controller:$CONTROLLER_TAG" --file controller/Dockerfile controller
ACR_LOGIN_SERVER="$(az acr show --name "$ACR_NAME" --query loginServer --output tsv)"

azd env set RUNNER_IMAGE_ID "$EXISTING_RUNNER_IMAGE_ID"
azd env set RUNNER_CONTROLLER_IMAGE "$ACR_LOGIN_SERVER/runner-controller:$CONTROLLER_TAG"
azd env set DEPLOY_RUNNER_CONTROLLER "true"
azd provision --environment "$ENVIRONMENT_NAME" --no-prompt

echo "Deployment complete. Workflows can now target: runs-on: avp-linux"
