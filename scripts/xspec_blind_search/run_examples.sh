#!/usr/bin/env bash
set -euo pipefail

# Example PN run
python scripts/xspec_blind_search/run_blind_search.py pn \
  --obsid 0865600201 \
  --interval Persistent \
  --grouped \
  --use-background \
  --model-expr "tbabs*(nthcomp+diskbb)" \
  --fit-stat cstat \
  --refit-continuum

# Example RGS run
python scripts/xspec_blind_search/run_blind_search.py rgs \
  --obsid 0865600201 \
  --interval Full \
  --grouped \
  --model-expr "constant*tbabs*(diskbb)" \
  --fit-stat cstat \
  --refit-continuum

