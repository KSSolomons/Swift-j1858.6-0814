#!/usr/bin/env bash
set -euo pipefail

# Tiny runner for common dry-run checks before conversion.
# Usage: bash scripts/spex_port/run_examples.sh

ROOT="/media/kyle/kyle_phd/Swift-j1858.6-0814"
cd "$ROOT"

python scripts/spex_port/port_to_spex.py pn \
  --obsid 0865600201 \
  --interval Dipping \
  --grouped \
  --dry-run

python scripts/spex_port/port_to_spex.py rgs \
  --obsid 0865600201 \
  --interval Full \
  --grouped \
  --dry-run

echo "Dry-run checks completed. Remove --dry-run for real conversion."

