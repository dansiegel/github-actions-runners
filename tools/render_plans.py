#!/usr/bin/env python
from __future__ import annotations

import argparse
import json
from pathlib import Path

from tools.runner_config import build_azure_plan, load_config, normalize_config


def main() -> int:
    parser = argparse.ArgumentParser(description="Render dry-run plans. No live GitHub or Azure calls are made.")
    parser.add_argument("--config", required=True)
    parser.add_argument("--out", default="-")
    args = parser.parse_args()
    cfg, _ = normalize_config(load_config(args.config))
    plan = build_azure_plan(cfg, args.config)
    text = json.dumps(plan, indent=2, sort_keys=True)
    if args.out == "-":
        print(text)
    else:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(text + "\n", encoding="utf-8")
        print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
