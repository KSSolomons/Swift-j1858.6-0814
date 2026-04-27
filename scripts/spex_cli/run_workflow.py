#!/usr/bin/env python3
"""Generate and optionally run a CLI-only SPEX batch workflow.

This script renders a reproducible SPEX command file and can run it through the
SPEX executable. It is the canonical entry point for the repository's fit
workflow.

Grouping is performed inside SPEX via ``obin``; the converted .spo/.res inputs
are always ungrouped (channel-level) data.

Typical usage:

    python scripts/spex_cli/run_workflow.py \
        --obsid 0865600201 --instrument pn --interval Full \
        --run

If your SPEX build requires a specific launcher, set ``--spex-bin`` to that
executable name/path. The script assumes SPEX can read batch commands from
stdin; if your local build uses a different invocation style, edit the launcher
section in this script or run the generated ``.com`` file manually.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from parse_log import parse_spex_log, write_summary_csv, write_summary_json  # type: ignore
    from workflow import WorkflowConfig, build_workflow  # type: ignore
else:
    from .parse_log import parse_spex_log, write_summary_csv, write_summary_json
    from .workflow import WorkflowConfig, build_workflow


def _default_repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _write_text(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def _run_spex_batch(spex_bin: str, script_path: Path, log_path: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    # SPEX will not overwrite existing log files, so we must delete it first
    out_file = log_path.with_name(log_path.name + ".out")
    if out_file.exists():
        out_file.unlink()

    # We run SPEX in the logs directory so that we can use a pure filename
    # for `log out` (SPEX dislikes slashes in log paths), and we use relative
    # paths (`../../`) for the `data` command to avoid path length limits.
    with script_path.open("r", encoding="utf-8") as script_f:
        proc = subprocess.run([spex_bin], stdin=script_f, cwd=log_path.parent, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"SPEX exited with code {proc.returncode}")


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Run a CLI-only SPEX workflow")
    p.add_argument("--repo-root", default=str(_default_repo_root()), help="Repository root (default: auto-detected)")
    p.add_argument("--obsid", required=True)
    p.add_argument("--instrument", required=True, choices=["pn", "rgs"])
    p.add_argument("--interval", default="Full")
    p.add_argument("--thermal-model", default="dbb")
    p.add_argument("--fit-iter-cap", type=int, default=100)
    p.add_argument("--no-fit-iter-cap", action="store_true", help="Do not emit fit iter caps in the SPEX batch file")
    p.add_argument("--spex-bin", default="spex", help="SPEX command-line executable (default: spex)")
    p.add_argument("--run", action="store_true", help="Execute the generated batch file")
    p.add_argument("--dry-run", action="store_true", help="Only write the command file and report paths")
    p.add_argument("--overwrite-conversion", action="store_true")
    p.add_argument("--blind-search-run", action="store_true")
    p.add_argument("--blind-search-dlam", type=float, default=0.05)
    p.add_argument("--blind-search-max-points", type=int, default=120)
    p.add_argument("--blind-search-iter-cap", type=int, default=8)
    p.add_argument("--blind-search-refit-baseline", action="store_true")
    p.add_argument("--blind-search-make-plot", action="store_true")
    return p


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    repo_root = Path(args.repo_root).expanduser().resolve()

    cfg = WorkflowConfig(
        obsid=args.obsid,
        instrument=args.instrument,
        interval=args.interval,

        thermal_model=args.thermal_model,
        fit_iter_cap=None if args.no_fit_iter_cap else args.fit_iter_cap,
        overwrite_conversion=args.overwrite_conversion,
        blind_search_run=args.blind_search_run,
        blind_search_dlam=args.blind_search_dlam,
        blind_search_max_points=args.blind_search_max_points,
        blind_search_iter_cap=args.blind_search_iter_cap,
        blind_search_refit_baseline=args.blind_search_refit_baseline,
        blind_search_make_plot=args.blind_search_make_plot,
    )

    paths, script_text = build_workflow(repo_root, cfg)
    for p in paths.artifact_dirs.values():
        p.mkdir(parents=True, exist_ok=True)

    command_path = _write_text(paths.artifact_dirs["commands"] / f"fit_workflow_{cfg.instrument}_{paths.interval_tag}.com", script_text)

    manifest = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "repo_root": str(repo_root),
        "config": {
            "obsid": cfg.obsid,
            "instrument": cfg.instrument,
            "interval": cfg.interval,

            "thermal_model": cfg.thermal_model,
            "fit_iter_cap": cfg.fit_iter_cap,
            "overwrite_conversion": cfg.overwrite_conversion,
            "blind_search_run": cfg.blind_search_run,
        },
        "paths": {
            "spex_out_base": str(paths.spex_out_base),
            "fit_artifact_dir": str(paths.fit_artifact_dir),
            "commands": str(paths.artifact_dirs["commands"]),
            "logs": str(paths.artifact_dirs["logs"]),
            "tables": str(paths.artifact_dirs["tables"]),
            "summaries": str(paths.artifact_dirs["summaries"]),
        },
        "command_file": str(command_path),
    }
    manifest_path = paths.fit_artifact_dir / f"workflow_manifest_{cfg.instrument}_{paths.interval_tag}.json"
    _write_text(manifest_path, json.dumps(manifest, indent=2))

    print(f"Wrote command file: {command_path}")
    print(f"Wrote manifest: {manifest_path}")

    if args.dry_run:
        print(json.dumps(manifest, indent=2))
        return 0

    if args.run:
        # SPEX's own `log out` writes to this file (see workflow.py)
        spex_log = paths.artifact_dirs["logs"] / f"spex_output_{cfg.instrument}_{paths.interval_tag}.log"
        print(f"Running SPEX with {args.spex_bin!r}; SPEX log -> {spex_log}.out")
        _run_spex_batch(args.spex_bin, command_path, spex_log)

        # Parse the SPEX-internal log (.out extension added by SPEX)
        spex_log_out = spex_log.with_suffix(".log.out")
        if spex_log_out.exists():
            parsed = parse_spex_log(spex_log_out)
            summary_json = write_summary_json(paths.artifact_dirs["summaries"] / f"fit_summary_{cfg.instrument}_{paths.interval_tag}.json", parsed)
            summary_csv = write_summary_csv(paths.artifact_dirs["tables"] / f"fit_statistics_{cfg.instrument}_{paths.interval_tag}.csv", parsed)
            print(f"Wrote parsed summary: {summary_json}")
            print(f"Wrote parsed statistics: {summary_csv}")
        else:
            print(f"Warning: SPEX log not found at {spex_log_out}; skipping summary generation.")
    else:
        print("Not running SPEX yet; use --run to execute the generated batch file.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())


