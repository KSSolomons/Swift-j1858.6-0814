# SPEX Port Helper

This folder contains a lightweight conversion utility that ports OGIP spectra
(PN / RGS) into SPEX `.spo` / `.res` format using `pyspextools` or `trafo`.

## What it does

- Resolves your existing PN/RGS OGIP products using this repo's naming conventions.
- Converts them to **ungrouped** SPEX `.spo` / `.res` files via `pyspextools` (default) or `trafo`.
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

By default, RGS porting compiles **Order 1 only** and enables **multi-sector** mode to support cross-calibration between RGS1 and RGS2.

### Multi-sector (cross-calibration)

To fit RGS1 and RGS2 with independent normalizations, the script defaults to `--multi-sector`. This produces separate `.spo`/`.res` files for RGS1 and RGS2, which are loaded as separate SPEX sectors via two `data` commands in the fit workflow.

```bash
# RGS1 + RGS2, order 1 only (default)
python scripts/spex_port/port_to_spex.py rgs \
    --obsid 0865600201 --interval Full --overwrite

# RGS1 + RGS2, both orders (if desired)
python scripts/spex_port/port_to_spex.py rgs \
    --obsid 0865600201 --interval Full --orders 1,2 --overwrite
```

This creates:
- `products/<obsid>/rgs/spex/rgs1_<interval>_spex.{spo,res}` — RGS1 (Sector 1)
- `products/<obsid>/rgs/spex/rgs2_<interval>_spex.{spo,res}` — RGS2 (Sector 2)

By default, `run_workflow.py` has `--multi-sector` enabled as well, so it will automatically load these files into separate sectors.

### Order filtering

Use `--orders` to control which RGS orders are included (default: `1`). This is configured to exclude the noisier 2nd order data by default:

```bash
# Single-sector, order 1 only
python scripts/spex_port/port_to_spex.py rgs \
    --obsid 0865600201 --interval Full --no-multi-sector --overwrite
```

### Conversion Backend

The script uses the classic `trafo` utility by default (using `pexpect` to drive the interactive `trafo` inputs automatically). Note that `trafo` must be available in your system `$PATH`.

```bash
python scripts/spex_port/port_to_spex.py rgs \
    --obsid 0865600201 --interval Full --overwrite
```

## Output locations

Defaults if `--out-base` is not provided:

- PN: `products/<obsid>/pn/spex/pn_<interval>_spex.{spo,res}`
- RGS (no multi-sector): `products/<obsid>/rgs/spex/rgs_<interval>_spex.{spo,res}`
- RGS (multi-sector): `products/<obsid>/rgs/spex/rgs{1,2}_<interval>_spex.{spo,res}`

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
