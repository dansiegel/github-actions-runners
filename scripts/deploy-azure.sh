#!/usr/bin/env bash
set -Eeuo pipefail

SUBSCRIPTION_ID=""
GITHUB_ORGANIZATION=""
RUNNER_GROUP="default"
RUNNER_POOLS_FILE=""
RUNNER_SCALE_SET_NAME="azure-linux"
RUNNER_MAX_CAPACITY="10"
RUNNER_VM_SIZE="Standard_D4s_v5"
RUNNER_VM_PRIORITY="Regular"
RUNNER_LABELS=""
ENVIRONMENT_NAME="prod"
LOCATION="eastus2"
RESOURCE_GROUP="gha-runners-prod"
SSH_PUBLIC_KEY_FILE="${HOME}/.ssh/id_ed25519.pub"
RUNNER_IMAGE_NAME_PREFIX="gha-runner"
MODE="dry-run"
BOOTSTRAP_ONLY="false"
CONFIRM_SUBSCRIPTION=""
EXISTING_RUNNER_IMAGE_ID=""

usage() {
  echo "usage: $0 --subscription-id id --github-organization org [--dry-run|--apply] [--bootstrap-only] [--runner-pools-file json] [--runner-scale-set-name name] [--runner-max-capacity count] [--runner-vm-size sku] [--runner-vm-priority Regular|Spot] [--runner-labels csv] [--environment name] [--location region] [--resource-group name] [--ssh-public-key-file path] [--runner-image-id resource-id] [--runner-image-name-prefix prefix] [--confirm-subscription id]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --apply) MODE="apply"; shift ;;
    --bootstrap-only) BOOTSTRAP_ONLY="true"; shift ;;
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --github-organization) GITHUB_ORGANIZATION="$2"; shift 2 ;;
    --runner-group) RUNNER_GROUP="$2"; shift 2 ;;
    --runner-pools-file) RUNNER_POOLS_FILE="$2"; shift 2 ;;
    --runner-scale-set-name) RUNNER_SCALE_SET_NAME="$2"; shift 2 ;;
    --runner-max-capacity) RUNNER_MAX_CAPACITY="$2"; shift 2 ;;
    --runner-vm-size) RUNNER_VM_SIZE="$2"; shift 2 ;;
    --runner-vm-priority) RUNNER_VM_PRIORITY="$2"; shift 2 ;;
    --runner-labels) RUNNER_LABELS="$2"; shift 2 ;;
    --environment) ENVIRONMENT_NAME="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --ssh-public-key-file) SSH_PUBLIC_KEY_FILE="$2"; shift 2 ;;
    --runner-image-id) EXISTING_RUNNER_IMAGE_ID="$2"; shift 2 ;;
    --runner-image-name-prefix) RUNNER_IMAGE_NAME_PREFIX="$2"; shift 2 ;;
    --confirm-subscription) CONFIRM_SUBSCRIPTION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! "$SUBSCRIPTION_ID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "--subscription-id must be an Azure subscription UUID" >&2
  exit 2
fi
if [[ ! "$GITHUB_ORGANIZATION" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]; then
  echo "--github-organization is required and must be a valid GitHub organization name" >&2
  exit 2
fi
if [[ ! "$RUNNER_IMAGE_NAME_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,39}$ ]]; then
  echo "--runner-image-name-prefix must use 1-40 letters, numbers, or hyphens" >&2
  exit 2
fi
if ! command -v jq >/dev/null; then
  echo "jq is required to validate runner pool configuration" >&2
  exit 2
fi

if [[ -n "$RUNNER_POOLS_FILE" ]]; then
  [[ -f "$RUNNER_POOLS_FILE" ]] || { echo "Runner pool configuration not found: $RUNNER_POOLS_FILE" >&2; exit 2; }
  RUNNER_POOLS_JSON="$(jq -ce '
    if type != "array" or length < 1 or length > 8 then error("configuration must contain 1-8 pools") else . end
    | map(
        if (.name | type) != "string" or (.name | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") | not) then error("invalid pool name") else . end
        | if (.vmSize | type) != "string" or (.vmSize | test("^Standard_[A-Za-z0-9_]+$") | not) then error("invalid VM size for " + .name) else . end
        | if (.maxRunners | type) != "number" or (.maxRunners | floor) != .maxRunners or .maxRunners < 1 or .maxRunners > 20 then error("maxRunners must be 1-20 for " + .name) else . end
        | .priority = (.priority // "Regular")
        | if (.priority != "Regular" and .priority != "Spot") then error("priority must be Regular or Spot for " + .name) else . end
        | .labels = (
            if (.labels | type) == "array" and (.labels | length) > 0
            then [.labels[] | tostring | gsub("^\\s+|\\s+$"; "") | select(length > 0)]
            else [.name]
            end
          )
        | if (.labels | length) == 0 then .labels = [.name] else . end
      )
    | if ([.[].name | ascii_downcase] | unique | length) != length then error("pool names must be unique") else . end
  ' "$RUNNER_POOLS_FILE")"
else
  [[ "$RUNNER_SCALE_SET_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo "invalid --runner-scale-set-name" >&2; exit 2; }
  [[ "$RUNNER_MAX_CAPACITY" =~ ^[0-9]+$ ]] && (( RUNNER_MAX_CAPACITY >= 1 && RUNNER_MAX_CAPACITY <= 20 )) || { echo "--runner-max-capacity must be 1-20" >&2; exit 2; }
  [[ "$RUNNER_VM_SIZE" =~ ^Standard_[A-Za-z0-9_]+$ ]] || { echo "invalid --runner-vm-size" >&2; exit 2; }
  [[ "$RUNNER_VM_PRIORITY" == "Regular" || "$RUNNER_VM_PRIORITY" == "Spot" ]] || { echo "--runner-vm-priority must be Regular or Spot" >&2; exit 2; }
  if [[ -z "$RUNNER_LABELS" ]]; then RUNNER_LABELS="$RUNNER_SCALE_SET_NAME"; fi
  RUNNER_POOLS_JSON="$(jq -cn --arg name "$RUNNER_SCALE_SET_NAME" --arg vmSize "$RUNNER_VM_SIZE" --argjson maxRunners "$RUNNER_MAX_CAPACITY" --arg priority "$RUNNER_VM_PRIORITY" --arg labels "$RUNNER_LABELS" '[{name:$name,vmSize:$vmSize,maxRunners:$maxRunners,priority:$priority,labels:($labels | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))}]')"
fi

PRIMARY_POOL_NAME="$(jq -r '.[0].name' <<<"$RUNNER_POOLS_JSON")"
PRIMARY_POOL_MAX="$(jq -r '.[0].maxRunners' <<<"$RUNNER_POOLS_JSON")"
PRIMARY_POOL_VM_SIZE="$(jq -r '.[0].vmSize' <<<"$RUNNER_POOLS_JSON")"
PRIMARY_POOL_PRIORITY="$(jq -r '.[0].priority' <<<"$RUNNER_POOLS_JSON")"

echo "Target subscription: $SUBSCRIPTION_ID"
echo "GitHub organization: $GITHUB_ORGANIZATION"
echo "Resource group:      $RESOURCE_GROUP"
echo "Location:            $LOCATION"
echo "Runner pools:"
jq -r '.[] | "  \(.name): 0..\(.maxRunners) \(.vmSize) (\(.priority))"' <<<"$RUNNER_POOLS_JSON"
echo "Runner image:        .NET 10, Node 24, Docker/Buildx, Azure CLI, azd, PowerShell, Aspire"

if [[ "$MODE" != "apply" ]]; then
  echo "Dry run only. No Azure resources were changed."
  echo "Apply with --apply --subscription-id $SUBSCRIPTION_ID --github-organization $GITHUB_ORGANIZATION --confirm-subscription $SUBSCRIPTION_ID"
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
azd env set GITHUB_ORGANIZATION "$GITHUB_ORGANIZATION"
azd env set RUNNER_GROUP "$RUNNER_GROUP"
azd env set RUNNER_SCALE_SET_NAME "$PRIMARY_POOL_NAME"
azd env set RUNNER_MAX_CAPACITY "$PRIMARY_POOL_MAX"
azd env set RUNNER_VM_SIZE "$PRIMARY_POOL_VM_SIZE"
azd env set RUNNER_VM_PRIORITY "$PRIMARY_POOL_PRIORITY"
azd env set RUNNER_POOLS_JSON "$RUNNER_POOLS_JSON"
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
  IMAGE_NAME="$RUNNER_IMAGE_NAME_PREFIX-$(date -u +%Y%m%d%H%M%S)"
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

echo "Deployment complete. Workflow labels: $(jq -r '[.[].name] | join(", ")' <<<"$RUNNER_POOLS_JSON")"
