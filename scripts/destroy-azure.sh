#!/usr/bin/env bash
set -euo pipefail
CONFIG="config/runners.yaml"
MODE="dry-run"
CONFIRM_RG=""
CONFIRM_SPEND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --dry-run) MODE="dry-run"; shift ;;
    --apply) MODE="apply"; shift ;;
    --confirm-resource-group) CONFIRM_RG="$2"; shift 2 ;;
    --confirm-spend) CONFIRM_SPEND="$2"; shift 2 ;;
    -h|--help) echo "usage: $0 [--config path] [--dry-run|--apply] --confirm-resource-group name [--confirm-spend I_ACCEPT_AZURE_SPEND]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p .plan
python tools/runner_config.py azure-plan --config "$CONFIG" | tee .plan/destroy-plan.json >/dev/null
RG=$(python - "$CONFIG" <<'PY'
import sys
from tools.runner_config import load_config, normalize_config
cfg,_ = normalize_config(load_config(sys.argv[1]))
print(cfg['defaults']['azure']['resourceGroup'])
PY
)
if [ "$MODE" = "apply" ]; then
  if [ -z "$CONFIRM_RG" ]; then
    echo "--confirm-resource-group $RG is required for destroy apply" >&2
    exit 2
  fi
  python tools/runner_config.py destroy-azure --config "$CONFIG" --confirm-resource-group "$CONFIRM_RG" --confirm-spend "$CONFIRM_SPEND"
else
  echo "dry-run only: would delete Azure resource group $RG and contained runner resources"
  echo "no Azure mutation command was executed"
  echo "rerun with --apply --confirm-resource-group $RG --confirm-spend I_ACCEPT_AZURE_SPEND only after approval"
fi
