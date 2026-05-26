# Swift-j1858.6-0814
Data reduction and analysis of XMM-Newton X-ray spectra of the Neutron star LMXRB Swift j1858.6-0814

## SPEX workflow

The repo now supports a CLI-only SPEX path:

1. Convert OGIP spectra to SPEX `.spo` / `.res` with `scripts/spex_port/port_to_spex.py`
2. Generate and run a batch SPEX fit with `scripts/spex_cli/run_workflow.py`

Quick examples from repo root:

```bash
# Convert data
python scripts/spex_port/port_to_spex.py pn --obsid 0865600201 --interval Full --overwrite

# Run full fit workflow
python scripts/spex_cli/run_workflow.py --obsid 0865600201 --instrument pn --interval Full --run

# Interactive setup (generate SPEX setup commands without fitting)
python scripts/spex_cli/run_workflow.py --obsid 0865600201 --instrument pn --interval Full --setup-only
```

To run a blind line search on a grid:

```bash
python scripts/spex_cli/run_workflow.py \
    --obsid 0865600201 --instrument pn --interval Full \
    --binning min_counts --min-counts 20 --fit-iter-cap 100 \
    --no-xabs --run --blind-search-run \
    --energy-min 0.6 --energy-max 8.0 --blind-search-dlam 0.01
```

The new workflow docs are in `scripts/spex_cli/README.md`.

