# SPEX Port Helper

This folder contains a lightweight conversion utility that ports OGIP spectra
(PN / RGS) into SPEX `.spo` / `.res` format using `pyspextools`.

## What it does

- Resolves your existing PN/RGS OGIP products using this repo's naming conventions.
- Converts them to **ungrouped** SPEX `.spo` / `.res` files via `pyspextools`.
- **Does not apply any grouping** — grouping is deferred to SPEX's native `obin`
  command, which is applied during the fit workflow (see `scripts/spex_cli/`).
- Writes a JSON manifest with all resolved inputs and outputs.
- Supports `--dry-run` to validate paths before conversion.

## Script

- `scripts/spex_port/port_to_spex.py`

## Quick usage

Run from repo root:

```bash
# Dry-run first to check resolved paths
python scripts/spex_port/port_to_spex.py pn --obsid 0865600201 --interval Dipping --dry-run
python scripts/spex_port/port_to_spex.py pn --obsid 0865600201 --interval Dipping --overwrite

python scripts/spex_port/port_to_spex.py rgs --obsid 0865600201 --interval Full --dry-run
python scripts/spex_port/port_to_spex.py rgs --obsid 0865600201 --interval Full --overwrite
```

## Output locations

Defaults if `--out-base` is not provided:

- PN: `products/<obsid>/pn/spex/pn_<interval>_spex.{spo,res}`
- RGS: `products/<obsid>/rgs/spex/rgs_<interval>_spex.{spo,res}`

A sidecar manifest is always written as:

- `<out-base>.manifest.json`

## Notes

- RGS interval directory is auto-detected in this order:
  1. `products/<obsid>/rgs/time_intervals/<interval>`
  2. `products/<obsid>/rgs/flux_resolved/<interval>`
  3. `products/<obsid>/rgs/<interval>`
- Conversion requires `pyspextools` in your active environment.
- Grouping (`obin`) is **not** done here — use the SPEX CLI workflow for that.

## Tests

These tests only validate path resolution logic (they do not require SPEX libs):

```bash
python -m unittest discover -s scripts/spex_port/tests -p 'test_*.py' -v
```
