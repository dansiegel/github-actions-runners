#!/usr/bin/env bash
set -euo pipefail
CONFIG="config/runners.yaml"
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    -h|--help) echo "usage: $0 [--config path]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
python tools/runner_config.py validate --config "$CONFIG"
