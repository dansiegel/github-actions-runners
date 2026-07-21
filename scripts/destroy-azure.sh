#!/usr/bin/env bash
set -Eeuo pipefail

SUBSCRIPTION_ID="d901cbec-f20d-4272-a0b4-9ee06b850880"
RESOURCE_GROUP="gha-runners-prod"
MODE="dry-run"
CONFIRM_SUBSCRIPTION=""
CONFIRM_RESOURCE_GROUP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --apply) MODE="apply"; shift ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --confirm-subscription) CONFIRM_SUBSCRIPTION="$2"; shift 2 ;;
    --confirm-resource-group) CONFIRM_RESOURCE_GROUP="$2"; shift 2 ;;
    -h|--help)
      echo "usage: $0 [--dry-run|--apply] [--resource-group name] --confirm-subscription id --confirm-resource-group name"
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

echo "Would delete resource group $RESOURCE_GROUP from subscription $SUBSCRIPTION_ID."
echo "Key Vault purge protection can leave the vault name unavailable after resource-group deletion."
if [[ "$MODE" != "apply" ]]; then
  echo "Dry run only. Nothing was deleted."
  exit 0
fi
if [[ "$CONFIRM_SUBSCRIPTION" != "$SUBSCRIPTION_ID" ]]; then
  echo "--confirm-subscription must exactly equal $SUBSCRIPTION_ID" >&2
  exit 2
fi
if [[ "$CONFIRM_RESOURCE_GROUP" != "$RESOURCE_GROUP" ]]; then
  echo "--confirm-resource-group must exactly equal $RESOURCE_GROUP" >&2
  exit 2
fi

az account set --subscription "$SUBSCRIPTION_ID"
ACTUAL_ID="$(az group show --name "$RESOURCE_GROUP" --query id --output tsv)"
EXPECTED_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"
if [[ "${ACTUAL_ID,,}" != "${EXPECTED_ID,,}" ]]; then
  echo "Resolved resource group did not match expected ID; refusing deletion" >&2
  exit 2
fi
az group delete --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION_ID" --yes --no-wait
echo "Deletion requested for exactly $EXPECTED_ID"
