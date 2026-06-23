#!/usr/bin/env bash
set -euo pipefail
CONFIG="config/runners.yaml"
MODE="dry-run"
ALLOW_SCALE_DOWN="false"
CONFIRM_SPEND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --dry-run) MODE="dry-run"; shift ;;
    --apply) MODE="apply"; shift ;;
    --allow-scale-down) ALLOW_SCALE_DOWN="true"; shift ;;
    --confirm-spend) CONFIRM_SPEND="$2"; shift 2 ;;
    -h|--help) echo "usage: $0 [--config path] [--dry-run|--apply] [--allow-scale-down] [--confirm-spend I_ACCEPT_AZURE_SPEND]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p .plan
python tools/runner_config.py azure-plan --config "$CONFIG" | tee .plan/azure-plan.json
if [ "$MODE" = "apply" ]; then
  args=(apply-azure --config "$CONFIG" --confirm-spend "$CONFIRM_SPEND")
  if [ "$ALLOW_SCALE_DOWN" = "true" ]; then
    args+=(--allow-scale-down)
  fi
  python tools/runner_config.py "${args[@]}"
else
  echo "dry-run only: no Azure mutation command was executed"
  echo "review .plan/azure-plan.json, then rerun with --apply --confirm-spend I_ACCEPT_AZURE_SPEND only after approval"
fi
