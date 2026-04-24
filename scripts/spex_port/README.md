# SPEX Port Helper

This folder contains a lightweight conversion utility to speed up migration from XSPEC notebooks to SPEX-ready files.

## What it does

- Resolves your existing PN/RGS OGIP products using this repo's naming conventions.
- Converts them to SPEX `.spo` / `.res` via `pyspextools`.
- Writes a JSON manifest with all resolved inputs and outputs.
- Supports `--dry-run` to validate paths before conversion.

## Script

- `scripts/spex_port/port_to_spex.py`

## Quick usage

Run from repo root:

```bash
python scripts/spex_port/port_to_spex.py pn --obsid 0865600201 --interval Dipping --grouped --dry-run
python scripts/spex_port/port_to_spex.py pn --obsid 0865600201 --interval Dipping --grouped --overwrite

python scripts/spex_port/port_to_spex.py rgs --obsid 0865600201 --interval Full --grouped --dry-run
python scripts/spex_port/port_to_spex.py rgs --obsid 0865600201 --interval Full --grouped --overwrite
```

## Output locations

Defaults if `--out-base` is not provided:

- PN grouped: `products/<obsid>/pn/spex/grouped/pn_<interval>_grp_spex.{spo,res}`
- PN ungrouped: `products/<obsid>/pn/spex/ungrouped/pn_<interval>_spex.{spo,res}`
- RGS grouped: `products/<obsid>/rgs/spex/grouped/rgs_<interval>_grp_spex.{spo,res}`
- RGS ungrouped: `products/<obsid>/rgs/spex/ungrouped/rgs_<interval>_spex.{spo,res}`

A sidecar manifest is always written as:

- `<out-base>.manifest.json`

## Notes

- RGS interval directory is auto-detected in this order:
  1. `products/<obsid>/rgs/time_intervals/<interval>`
  2. `products/<obsid>/rgs/flux_resolved/<interval>`
  3. `products/<obsid>/rgs/<interval>`
- Conversion requires `pyspextools` in your active environment.

## Tests

These tests only validate path resolution logic (they do not require SPEX libs):

```bash
python -m unittest discover -s scripts/spex_port/tests -p 'test_*.py' -v
```

