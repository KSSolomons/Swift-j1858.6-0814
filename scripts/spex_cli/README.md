# SPEX CLI workflow

This directory contains the command-line-only SPEX workflow.

## What it does

- Reuses the existing ungrouped `.spo` / `.res` files from `scripts/spex_port/`
- Applies **SPEX-native grouping** via the `obin` command inside the batch script
  (PN bins in keV; RGS bins in Ångström)
- Writes a reproducible SPEX batch script into the run artifact directory
- Optionally runs that batch script through your local SPEX executable
- Parses the resulting log into a compact JSON/CSV summary

## Examples

### PN (Single Sector)
```bash
python scripts/spex_cli/run_workflow.py \
  --obsid 0865600201 \
  --instrument pn \
  --interval Full \
  --run
```

### RGS (Multi-Sector Cross-Calibration)
```bash
python scripts/spex_cli/run_workflow.py \
  --obsid 0865600201 \
  --instrument rgs \
  --interval Full \
  --multi-sector \
  --spex-threads 1 \
  --run
```

For convenience, use the top-level `run_fit.sh` helper script.

### Interactive Setup (No Fitting)
If you want to manually fit your data in an interactive SPEX session, you can use the `--setup-only` flag. This will generate a batch script that loads the data, defines the model, and sets the starting parameters, but skips the actual fitting process:

```bash
python scripts/spex_cli/run_workflow.py \
  --obsid 0865600201 \
  --instrument pn \
  --interval Full \
  --setup-only
```

The script will output exact instructions for how to open SPEX and run the generated file.

## Multi-sector cross-calibration

To untie normalizations between RGS1 and RGS2, use the `--multi-sector` flag. 
This requires that you have converted the data using the `--multi-sector` flag
in `port_to_spex.py` (see `scripts/spex_port/README.md`).

When enabled:
- Loads RGS1 and RGS2 as separate instruments (Sectors 1 and 2).
- Couples physical shape parameters (T, N_H, etc.) between sectors.
- Leaves additive component normalizations free to fit the cross-calibration.

This creates:
- `products/<obsid>/rgs/spex/rgs1_<interval>_spex.{spo,res}` (Sector 1)
- `products/<obsid>/rgs/spex/rgs2_<interval>_spex.{spo,res}` (Sector 2)

Then enable `MULTI_SECTOR="true"` in `run_fit.sh` (or pass `--multi-sector` to
`run_workflow.py`) to load them into separate sectors.

### Order filtering

Use `--orders` to control which RGS orders are included (default: `1,2`). 
This is useful to exclude the noisier 2nd order data:

```bash
# Order 1 only (single-sector)
python scripts/spex_port/port_to_spex.py rgs \
    --obsid 0865600201 --interval Full --orders 1 --overwrite

# Order 1 only (multi-sector cross-calibration)
python scripts/spex_port/port_to_spex.py rgs \
    --obsid 0865600201 --interval Full --multi-sector --orders 1 --overwrite
```

### Region Selection (RGS)

When running the fit workflow (`run_workflow.py`), use the `--rgs-regions` flag to control which regions to fit (default: `1:4`). 

If your `.spo` file contains multiple regions (e.g. multiple orders), but you only want to fit the first region, you can specify it like this:

```bash
python scripts/spex_cli/run_workflow.py \
    --obsid 0865600201 \
    --instrument rgs \
    --interval Full \
    --rgs-regions 1 \
    --run
```

## Important: Threading (SIGSEGV)

SPEX 3.08.02 may experience segmentation faults during multi-sector fitting if
multiple threads are used. It is **strongly recommended** to use 1 thread for RGS:

```bash
--spex-threads 1
```

## Helper Script

The repository root contains `run_fit.sh`, which wraps the workflow with 
sensible defaults for this project:

```bash
# Edit run_fit.sh to set MULTI_SECTOR="true" and RGS_REGIONS="1,3"
./run_fit.sh
```

## Output locations

Defaults if `--out-base` is not provided:

- PN: `products/<obsid>/pn/spex/pn_<interval>_spex.{spo,res}`
- RGS (Single file): `products/<obsid>/rgs/spex/rgs_<interval>_spex.{spo,res}`
- RGS (Multi-sector): `products/<obsid>/rgs/spex/rgs{1,2}_<interval>_spex.{spo,res}`.

Within the interval folder you will find:

- `commands/` — generated SPEX batch scripts
- `logs/` — raw SPEX output
- `fit_tables/` — parsed statistics and any table-like outputs
- `summaries/` — JSON summaries
- `plots/` — optional analysis plots
- `line_search/` — reserved for future CLI blind-search runs

## Notes

- Grouping is done inside SPEX via `obin`, **not** during the OGIP-to-SPEX
  conversion step. This avoids NaN/segfault issues that can occur when
  pre-grouping leaves empty bins.
- The batch file mirrors the staged fit sequence used in the repository's
  current SPEX workflow. The exact SPEX command syntax can vary a bit by
  installation, so treat the rendered `.com` file as the editable source of
  truth if your local build expects slightly different line commands.
