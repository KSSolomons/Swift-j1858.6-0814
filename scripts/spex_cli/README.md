# SPEX CLI workflow

This directory contains the command-line-only SPEX workflow.

## What it does

- Reuses the existing ungrouped `.spo` / `.res` files from `scripts/spex_port/`
- Applies **SPEX-native grouping** via the `obin` command inside the batch script
  (PN bins in keV; RGS bins in Ångström)
- Writes a reproducible SPEX batch script into the run artifact directory
- Optionally runs that batch script through your local SPEX executable
- Parses the resulting log into a compact JSON/CSV summary

## Example

```bash
python scripts/spex_cli/run_workflow.py \
  --obsid 0865600201 \
  --instrument pn \
  --interval Full \
  --run
```

If your SPEX binary is not named `spex`, pass `--spex-bin /path/to/spex`.

## Output layout

The generated files live under:

```text
products/<obsid>/<instrument>/spex/<interval>/
```

The converted SPEX inputs (ungrouped `.spo` / `.res`) sit directly in
`products/<obsid>/<instrument>/spex/`.

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
