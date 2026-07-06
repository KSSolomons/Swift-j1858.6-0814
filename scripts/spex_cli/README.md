# SPEX CLI workflow

This directory contains the command-line-only SPEX workflow.

## What it does

- Reuses the existing ungrouped `.spo` / `.res` files from `scripts/spex_port/`
- Applies **SPEX-native grouping** via the `obin` command inside the batch script
  (PN bins in keV; RGS bins in Ångström)
- Writes a reproducible SPEX batch script into the run artifact directory
- Optionally runs that batch script through your local SPEX executable
- Parses the resulting log into a compact JSON/CSV summary

## Usage & Examples

### Basic Fitting

**PN (Single Sector)**
```bash
python scripts/spex_cli/run_workflow.py \
  --obsid 0865600201 \
  --instrument pn \
  --interval Full \
  --run
```

**RGS (Multi-Sector Cross-Calibration)**
```bash
python scripts/spex_cli/run_workflow.py \
  --obsid 0865600201 \
  --instrument rgs \
  --interval Full \
  --spex-threads 1 \
  --run
```
*Note: By default, RGS fitting operates in **multi-sector** mode with **Region 1 (Order 1) only**, which is the recommended setup for cross-calibration.*

### Interactive Setup (No Fitting)
If you want to manually fit your data in an interactive SPEX session, use the `--setup-only` flag. This generates a batch script that loads the data, defines the model, and sets the starting parameters, but skips the fitting process:

```bash
python scripts/spex_cli/run_workflow.py \
  --obsid 0865600201 \
  --instrument pn \
  --interval Full \
  --setup-only
```
The script will output exact instructions for how to open SPEX and run the generated file.

### Advanced Fit Options

**Include xabs Absorption**
To run a single fit with the `xabs` absorption component included:
```bash
python scripts/spex_cli/run_workflow.py \
    --obsid 0865600201 --instrument pn --interval Full \
    --xabs --run
```

**Model Comparison (BIC Test for xabs)**
To compare models with and without `xabs` absorption and calculate the Bayesian Information Criterion (BIC):
```bash
python scripts/spex_cli/run_workflow.py \
    --obsid 0865600201 --instrument pn --interval Full \
    --test-xabs --run
```

**Start from Best-Fit Parameters**
To skip the staged fitting steps (which usually freeze continuum parameters initially) and start directly from a known set of best-fit parameters:
```bash
python scripts/spex_cli/run_workflow.py \
    --obsid 0865600201 --instrument pn --interval Full \
    --best-fit-params /path/to/best_fit_params.json \
    --run
```

**Custom Energy Range and Iteration Cap**
To fit using a specific energy range (e.g. 0.6–8.0 keV) and cap the maximum number of iterations:
```bash
python scripts/spex_cli/run_workflow.py \
    --obsid 0865600201 --instrument pn --interval Full \
    --pn-energy-min 0.6 --pn-energy-max 8.0 \
    --fit-iter-cap 500 --run
```

**Blind Search (Line Scan)**
To run a blind search (line scan) over a given energy/wavelength range instead of a static fit:
```bash
python scripts/spex_cli/run_workflow.py \
    --obsid 0865600201 --instrument pn --interval Full \
    --run --blind-search-run --binning min_counts \
    --pn-energy-min 2.0 --pn-energy-max 10.0 \
    --blind-search-dlam 0.01
```

## Configuration Details

### Multi-sector cross-calibration

To untie normalizations between RGS1 and RGS2, the workflow defaults to `--multi-sector`. 
This requires that you have converted the data using the default `--multi-sector` flag in `port_to_spex.py` (see `scripts/spex_port/README.md`).

When enabled:
- Loads RGS1 and RGS2 as separate instruments (Sectors 1 and 2).
- Couples physical shape parameters (T, N_H, etc.) between sectors.
- Leaves additive component normalizations free to fit the cross-calibration.

This loads:
- `products/<obsid>/rgs/spex/rgs1_<interval>_spex.{spo,res}` (Sector 1)
- `products/<obsid>/rgs/spex/rgs2_<interval>_spex.{spo,res}` (Sector 2)

If you prefer to disable cross-calibration and fit both instruments in a single sector, pass the `--no-multi-sector` flag:

```bash
python scripts/spex_cli/run_workflow.py \
    --obsid 0865600201 --instrument rgs --interval Full \
    --no-multi-sector --run
```

### Order and Region Selection (RGS)

By default, the porting script exports only Order 1 data, and the fit workflow script defaults to `--rgs-regions 1` to fit only Region 1 (Order 1).

If you ported both orders (e.g. `--orders 1,2` during porting) and want to fit all regions, you can specify `--rgs-regions 1:4` during `run_workflow.py`:

```bash
python scripts/spex_cli/run_workflow.py \
    --obsid 0865600201 \
    --instrument rgs \
    --interval Full \
    --rgs-regions 1:4 \
    --run
```

### Binning options

By default, the workflow applies SPEX-native optimal binning (`obin`) to the ungrouped data. You can configure this behavior using the `--binning` and `--min-counts` CLI options:

- **Optimal Binning** (Default): Uses the `obin` command in SPEX.
  ```bash
  python scripts/spex_cli/run_workflow.py \
      --obsid 0865600201 --instrument pn --interval Full \
      --binning optimal --run
  ```
- **Minimum Counts (Variable Binning)**: Uses the `vbin` command to group bins based on a target signal-to-noise ratio derived from a counts threshold (defaults to 20):
  ```bash
  python scripts/spex_cli/run_workflow.py \
      --obsid 0865600201 --instrument pn --interval Full \
      --binning min_counts --min-counts 30 --run
  ```
- **No Binning**: Fits ungrouped channel-level data (no grouping command emitted):
  ```bash
  python scripts/spex_cli/run_workflow.py \
      --obsid 0865600201 --instrument pn --interval Full \
      --binning none --run
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
