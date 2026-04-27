#!/usr/bin/env bash
set -euo pipefail

# Tiny runner for the CLI-only SPEX workflow.
# Usage: bash scripts/spex_cli/run_examples.sh

ROOT="/media/kyle/kyle_phd/Swift-j1858.6-0814"
cd "$ROOT"

python scripts/spex_cli/run_workflow.py \
  --obsid 0865600201 \
  --instrument pn \
  --interval Full \
  --dry-run

echo "Dry-run completed. Add --run to execute the generated SPEX batch file."
