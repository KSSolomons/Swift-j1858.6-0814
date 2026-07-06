#!/usr/bin/env bash
set -euo pipefail

ROOT="/media/kyle/kyle_phd/Swift-j1858.6-0814"
cd "$ROOT"

OBSID="0865600201"
INTERVALS=("Full" "Dipping" "Persistent" "Shallow")

for interval in "${INTERVALS[@]}"; do
    echo "========================================"
    echo "Processing interval: $interval"
    echo "========================================"

    # Port PN
    echo "-> Running PN porting..."
    python scripts/spex_port/port_to_spex.py pn \
        --obsid "$OBSID" \
        --interval "$interval" \
        --overwrite
        
    # Port RGS
    echo "-> Running RGS porting..."
    python scripts/spex_port/port_to_spex.py rgs \
        --obsid "$OBSID" \
        --interval "$interval" \
        --multi-sector \
        --orders 1 \
        --overwrite
done

echo "Done! All specified intervals have been ported."
