# Swift-j1858.6-0814
Data reduction and analysis of XMM-Newton X-ray spectra of the Neutron star LMXRB Swift j1858.6-0814

## SPEX port helper

To speed up migration from XSPEC to SPEX, use `scripts/spex_port/port_to_spex.py`.

Quick dry-runs from repo root:

```bash
python scripts/spex_port/port_to_spex.py pn --obsid 0865600201 --interval Dipping --grouped --dry-run
python scripts/spex_port/port_to_spex.py rgs --obsid 0865600201 --interval Full --grouped --dry-run
```

The full helper docs are in `scripts/spex_port/README.md`.

