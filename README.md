# Swift-j1858.6-0814
Data reduction and analysis of XMM-Newton X-ray spectra of the Neutron star LMXRB Swift j1858.6-0814

## SPEX workflow

The repo now supports a CLI-only SPEX path:

1. Convert OGIP spectra to SPEX `.spo` / `.res` with `scripts/spex_port/port_to_spex.py`
2. Generate and run a batch SPEX fit with `scripts/spex_cli/run_workflow.py`

Quick dry-run examples from repo root:

```bash
python scripts/spex_port/port_to_spex.py pn --obsid 0865600201 --interval Dipping --grouped --dry-run
python scripts/spex_cli/run_workflow.py --obsid 0865600201 --instrument pn --interval Full --grouped --dry-run
```

The new workflow docs are in `scripts/spex_cli/README.md`.

