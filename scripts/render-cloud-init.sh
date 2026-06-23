#!/usr/bin/env bash
set -euo pipefail
CONFIG="config/runners.yaml"
BINDING=""
OUTPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --binding) BINDING="$2"; shift 2 ;;
    --pool) BINDING="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) echo "usage: $0 --binding binding-name [--config path] [--output path]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$BINDING" ]; then
  echo "--binding is required" >&2
  exit 2
fi
args=(render-cloud-init --config "$CONFIG" --binding "$BINDING")
if [ -n "$OUTPUT" ]; then
  args+=(--output "$OUTPUT")
fi
python tools/runner_config.py "${args[@]}"
