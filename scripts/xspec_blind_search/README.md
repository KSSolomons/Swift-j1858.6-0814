# PyXspec Blind Search (PN + RGS)

Standalone CLI port of the notebook blind line-search workflow for:
- PN (`pn xspec.ipynb` algorithm)
- RGS order-1 pair (`rgs xspec.ipynb` algorithm)

The script resolves products from this repository layout, loads a continuum model,
freezes that continuum, scans a Gaussian line centroid on a fixed wavelength grid,
and writes:
- CSV table (`Delta_Stat`, signed delta-stat, line norm, etc.)
- diagnostic PNG (spectrum + residuals + blind-search curve)
- JSON manifest (settings + resolved inputs)

## File

- `scripts/xspec_blind_search/run_blind_search.py`

## Quick usage

From repo root:

```bash
python scripts/xspec_blind_search/run_blind_search.py pn \
  --obsid 0865600201 \
  --interval Persistent \
  --grouped \
  --use-background \
  --model-expr "tbabs*(nthcomp+diskbb)" \
  --fit-stat cstat \
  --refit-continuum
```

```bash
python scripts/xspec_blind_search/run_blind_search.py rgs \
  --obsid 0865600201 \
  --interval Full \
  --grouped \
  --model-expr "constant*tbabs*(diskbb)" \
  --fit-stat cstat \
  --refit-continuum
```

## Notes

- Activate your HEASOFT/PyXspec environment before running.
- `--model-expr` should be the continuum only; the script appends `+ gauss` for the scan.
- RGS mode matches the notebook behavior by scanning **RGS1+RGS2 order-1** together.
- By default, existing outputs are not overwritten (use `--overwrite`).

