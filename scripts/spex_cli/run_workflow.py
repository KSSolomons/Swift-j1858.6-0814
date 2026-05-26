#!/usr/bin/env python3
"""Generate and optionally run a CLI-only SPEX batch workflow.

This script renders a reproducible SPEX command file and can run it through the
SPEX executable. It is the canonical entry point for the repository's fit
workflow.

Grouping is performed inside SPEX via ``obin`` (optimal) or ``vbin`` (min-counts);
the converted .spo/.res inputs are always ungrouped (channel-level) data.

Typical usage:

    python scripts/spex_cli/run_workflow.py \
        --obsid 0865600201 --instrument pn --interval Full \
        --continuum-model comt --run

To compare models with and without xabs (BIC test):

    python scripts/spex_cli/run_workflow.py \
        --obsid 0865600201 --instrument pn --interval Full \
        --test-xabs --run

The BIC (Bayesian Information Criterion) is calculated as BIC = C-stat + k*ln(N),
where k is the number of free parameters and N is the number of data points.
A Delta BIC > 10 indicates strong evidence for the more complex model;
a negative Delta BIC indicates the simpler (NULL) model is preferred.

To run without the xabs absorption component:

    python scripts/spex_cli/run_workflow.py \
        --obsid 0865600201 --instrument pn --interval Full \
        --no-xabs --run

To use a specific energy range and iteration cap:

    python scripts/spex_cli/run_workflow.py \
        --obsid 0865600201 --instrument pn --interval Full \
        --pn-energy-min 0.6 --pn-energy-max 8.0 \
        --fit-iter-cap 500 --run

To use a minimum-counts grouping (e.g. 30 counts per bin) instead of optimal binning:

    python scripts/spex_cli/run_workflow.py \
        --obsid 0865600201 --instrument pn --interval Full \
        --binning min_counts --min-counts 30 --run

To run a blind search (line scan) instead of a static fit:

    python scripts/spex_cli/run_workflow.py \
        --obsid 0865600201 --instrument pn --interval Full \
        --run --blind-search-run --binning min_counts \
        --pn-energy-min 2.0 --pn-energy-max 10.0 \
        --blind-search-dlam 0.01

By default, the script uses staged fitting with frozen continuum shape parameters
in the initial steps. To skip this and start from a best-fit parameter file instead:

    python scripts/spex_cli/run_workflow.py \
        --obsid 0865600201 --instrument pn --interval Full \
        --best-fit-params /path/to/best_fit_params.json \
        --run

If your SPEX build requires a specific launcher, set ``--spex-bin`` to that
executable name/path. The script assumes SPEX can read batch commands from
stdin; if your local build uses a different invocation style, edit the launcher
section in this script or run the generated ``.com`` file manually.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import math
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from parse_log import parse_spex_log, write_summary_json, write_summary_txt  # type: ignore
    from parse_blind_search import parse_blind_search_log  # type: ignore
    from workflow import WorkflowConfig, build_workflow, _make_scan_grid  # type: ignore
else:
    from .parse_log import parse_spex_log, write_summary_json, write_summary_txt
    from .parse_blind_search import parse_blind_search_log
    from .workflow import WorkflowConfig, build_workflow, _make_scan_grid


def _default_repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _write_text(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def _run_spex_batch(spex_bin: str, script_path: Path, log_path: Path, spex_threads: int | None = None) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    # SPEX will not overwrite existing log files, so we must delete it first
    out_file = log_path.with_name(log_path.name + ".out")
    if out_file.exists():
        out_file.unlink()

    env = os.environ.copy()
    if spex_threads is not None:
        env["OMP_NUM_THREADS"] = str(spex_threads)
        env["SPEX_NCORE"] = str(spex_threads)
    
    # Increase stack size for OpenMP to prevent segfaults during complex fits
    env["OMP_STACKSIZE"] = "128M"

    # We run SPEX in the logs directory so that we can use a pure filename
    # for `log out` (SPEX dislikes slashes in log paths), and we use relative
    # paths (`../../`) for the `data` command to avoid path length limits.
    with script_path.open("r", encoding="utf-8") as script_f:
        proc = subprocess.run(
            [spex_bin],
            stdin=script_f,
            cwd=log_path.parent,
            env=env,
            check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"SPEX exited with code {proc.returncode}")


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Run a CLI-only SPEX workflow")
    p.add_argument(
        "--repo-root",
        default=str(
            _default_repo_root()),
        help="Repository root (default: auto-detected)")
    p.add_argument("--obsid", required=True)
    p.add_argument("--instrument", required=True, choices=["pn", "rgs"])
    p.add_argument("--interval", default="Full")
    p.add_argument("--thermal-model", default="dbb")
    p.add_argument(
        "--continuum-model",
        default="comt",
        choices=[
            "pow",
            "comt"])
    p.add_argument("--fit-iter-cap", type=int, default=100)
    p.add_argument("--no-fit-iter-cap", action="store_true",
                   help="Do not emit fit iter caps in the SPEX batch file")
    p.add_argument("--spex-threads", type=int, default=4,
                   help="Number of CPU threads to use for SPEX (default: 4)")
    p.add_argument(
        "--spex-bin",
        default="spex",
        help="SPEX command-line executable (default: spex)")
    p.add_argument(
        "--run",
        action="store_true",
        help="Execute the generated batch file")
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Only write the command file and report paths")
    p.add_argument("--overwrite-conversion", action="store_true")
    p.add_argument("--blind-search-run", action="store_true")
    p.add_argument("--blind-search-dlam", type=float, default=0.1)
    p.add_argument("--blind-search-max-points", type=int, default=0)
    p.add_argument("--blind-search-iter-cap", type=int, default=8)
    p.add_argument(
        "--blind-search-refit-baseline",
        action="store_true",
        help="Before freezing the continuum for a blind search, run one final 'fit' to ensure the baseline is at its best-fit value."
    )
    p.add_argument("--no-blind-search-plot", action="store_false", 
                   dest="blind_search_make_plot", help="Do not make a blind search diagnostic plot")
    p.set_defaults(blind_search_make_plot=True)
    p.add_argument(
        "--best-fit-params",
        default=str(Path(__file__).resolve().parent / "best_fit_params.json"),
        help="Path to a JSON file with best-fit starting values")
    p.add_argument(
        "--binning",
        choices=[
            "optimal",
            "min_counts",
            "none"],
        default="optimal",
        help="Binning strategy (default: optimal/obin)")
    p.add_argument(
        "--min-counts",
        type=int,
        default=20,
        help="Minimum counts threshold for 'min_counts' binning strategy (default: 20)")
    p.add_argument("--pn-energy-min", type=float, default=0.6,
                   help="Lower energy limit for PN fitting in keV (default: 0.6)")
    p.add_argument("--pn-energy-max", type=float, default=10.0,
                   help="Upper energy limit for PN fitting in keV (default: 10.0)")
    p.add_argument("--rgs-lam-min", type=float, default=5.0,
                   help="Lower wavelength limit for RGS fitting in Angstroms (default: 5.0)")
    p.add_argument("--rgs-lam-max", type=float, default=38.0,
                   help="Upper wavelength limit for RGS fitting in Angstroms (default: 38.0)")
    p.add_argument(
        "--rgs-regions",
        default="1:4",
        help="SPEX regions to fit when using RGS (default: 1:4, options: 1, 1:2, etc.)")
    p.add_argument(
        "--no-xabs",
        action="store_true",
        help="Do not include the xabs absorption component")
    p.add_argument(
        "--test-xabs",
        action="store_true",
        help="Run model comparison (with/without xabs) and calculate BIC")
    p.add_argument(
        "--multi-sector",
        action="store_true",
        help="Treat RGS1 and RGS2 as separate SPEX sectors for cross-calibration "
             "(requires trafo to have placed them in separate sectors)")
    p.add_argument(
        "--setup-only",
        action="store_true",
        help="Generate a SPEX script that loads data and sets up models, but skips fitting and does not quit. Prints instructions to launch interactive SPEX.")
    return p


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    repo_root = Path(args.repo_root).expanduser().resolve()

    best_fit_path = Path(args.best_fit_params).expanduser(
    ).resolve() if args.best_fit_params else None

    spex_threads = args.spex_threads
    if args.instrument == "rgs" and spex_threads > 1:
        print("WARNING: Forcing SPEX to use 1 thread for RGS data to prevent OpenMP conresp_mat segmentation faults.")
        spex_threads = 1

    cfg = WorkflowConfig(
        obsid=args.obsid,
        instrument=args.instrument,
        interval=args.interval,

        thermal_model=args.thermal_model,
        continuum_model=args.continuum_model,
        fit_iter_cap=None if args.no_fit_iter_cap else args.fit_iter_cap,
        spex_threads=spex_threads,
        overwrite_conversion=args.overwrite_conversion,
        blind_search_run=args.blind_search_run,
        blind_search_dlam=args.blind_search_dlam,
        blind_search_max_points=args.blind_search_max_points,
        blind_search_iter_cap=args.blind_search_iter_cap,
        blind_search_refit_baseline=args.blind_search_refit_baseline,
        blind_search_make_plot=args.blind_search_make_plot,
        best_fit_params_file=best_fit_path,
        binning_strategy=args.binning,
        min_counts_threshold=args.min_counts,
        pn_energy_min=args.pn_energy_min,
        pn_energy_max=args.pn_energy_max,
        rgs_lam_min=args.rgs_lam_min,
        rgs_lam_max=args.rgs_lam_max,
        rgs_regions=args.rgs_regions,
        multi_sector=args.multi_sector,
        include_xabs=not args.no_xabs,
        quit_at_end=not args.setup_only,
    )

    fit_model = not args.setup_only
    paths, script_text, plot_script_text = build_workflow(repo_root, cfg, fit_model=fit_model)
    command_path = paths.artifact_dirs["commands"] / \
        f"fit_workflow_{cfg.instrument}_{paths.interval_tag}.com"
    plot_command_path = paths.artifact_dirs["commands"] / \
        f"plot_workflow_{cfg.instrument}_{paths.interval_tag}.com"
    manifest_path = paths.fit_artifact_dir / \
        f"workflow_manifest_{cfg.instrument}_{paths.interval_tag}.json"

    manifest = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "repo_root": str(repo_root),
        "config": {
            "obsid": cfg.obsid,
            "instrument": cfg.instrument,
            "interval": cfg.interval,

            "thermal_model": cfg.thermal_model,
            "continuum_model": cfg.continuum_model,
            "fit_iter_cap": cfg.fit_iter_cap,
            "overwrite_conversion": cfg.overwrite_conversion,
            "blind_search_run": cfg.blind_search_run,
            "binning_strategy": cfg.binning_strategy,
            "min_counts_threshold": cfg.min_counts_threshold,
            "pn_energy_min": cfg.pn_energy_min,
            "pn_energy_max": cfg.pn_energy_max,
            "rgs_lam_min": cfg.rgs_lam_min,
            "rgs_lam_max": cfg.rgs_lam_max,
            "include_xabs": cfg.include_xabs,
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

    if args.dry_run:
        print(json.dumps(manifest, indent=2))
        return 0

    for p in paths.artifact_dirs.values():
        p.mkdir(parents=True, exist_ok=True)

    _write_text(command_path, script_text)
    _write_text(plot_command_path, plot_script_text)
    _write_text(manifest_path, json.dumps(manifest, indent=2))

    print(f"Wrote command file: {command_path}")
    print(f"Wrote plot command file: {plot_command_path}")
    print(f"Wrote manifest: {manifest_path}")

    if args.setup_only:
        launch_script_path = paths.artifact_dirs['logs'] / f"launch_spex_{cfg.instrument}_{paths.interval_tag}.sh"
        launch_script = [
            "#!/bin/bash",
            f"export OMP_STACKSIZE=128M"
        ]
        if cfg.spex_threads is not None:
            launch_script.append(f"export OMP_NUM_THREADS={cfg.spex_threads}")
            launch_script.append(f"export SPEX_NCORE={cfg.spex_threads}")
        launch_script.append("spex")
        
        _write_text(launch_script_path, "\n".join(launch_script) + "\n")
        launch_script_path.chmod(0o755)

        print("\n" + "=" * 60)
        print("SETUP SCRIPT GENERATED")
        print("=" * 60)
        print("To interactively fit this observation, open a terminal, navigate to")
        print(f"the logs directory, and run the generated launcher script:")
        print(f"\n  cd {paths.artifact_dirs['logs']}")
        print(f"  ./{launch_script_path.name}")
        print(f"\nOnce SPEX starts, load the setup by running:")
        print(f"  SPEX> log exe ../commands/{command_path.stem}")
        print("\nThis will load the data, set up the initial parameters, and leave")
        print("you in the SPEX prompt ready to run `fit` and `plot`.")
        print("\nTo generate the stacked interactive plot, run:")
        print(f"  SPEX> log exe ../commands/{plot_command_path.stem}")
        print("============================================================\n")

    if args.run:
        if args.test_xabs:
            print("\n" + "=" * 60)
            print("AUTOMATED BIC TEST: xabs significance")
            print("=" * 60)

            # 1. Run without xabs
            print("\n[1/2] Fitting NULL model (without xabs)...")
            cfg_null = dataclasses.replace(
                cfg, include_xabs=False, log_suffix="_no_xabs")
            paths_null, script_null = build_workflow(repo_root, cfg_null)
            cmd_path_null = _write_text(
                paths_null.artifact_dirs["commands"] /
                f"fit_workflow_{cfg_null.instrument}_{paths_null.interval_tag}_no_xabs.com",
                script_null)
            spex_log_null = paths_null.artifact_dirs["logs"] / f"spex_output_{cfg_null.instrument}_{paths_null.interval_tag}_no_xabs.log"
            _run_spex_batch(args.spex_bin, cmd_path_null, spex_log_null, cfg.spex_threads)
            parsed_null = parse_spex_log(spex_log_null.with_suffix(".log.out"))

            # 2. Run with xabs
            print("\n[2/2] Fitting TEST model (with xabs)...")
            cfg_xabs = dataclasses.replace(
                cfg, include_xabs=True, log_suffix="_with_xabs")
            paths_xabs, script_xabs = build_workflow(repo_root, cfg_xabs)
            cmd_path_xabs = _write_text(
                paths_xabs.artifact_dirs["commands"] /
                f"fit_workflow_{cfg_xabs.instrument}_{paths_xabs.interval_tag}_with_xabs.com",
                script_xabs)
            spex_log_xabs = paths_xabs.artifact_dirs["logs"] / f"spex_output_{cfg_xabs.instrument}_{paths_xabs.interval_tag}_with_xabs.log"
            _run_spex_batch(args.spex_bin, cmd_path_xabs, spex_log_xabs, cfg.spex_threads)
            parsed_xabs = parse_spex_log(spex_log_xabs.with_suffix(".log.out"))

            # 3. Calculate BIC
            # The Bayesian Information Criterion (BIC) is a criterion for model selection
            # among a finite set of models; the model with the lowest BIC is preferred.
            # Formula: BIC = C-stat + k * ln(N)
            # - k: number of parameters estimated by the model
            # - N: number of data points in the spectrum (estimated as dof + k)
            # - Delta BIC = BIC_null - BIC_test
            #   (Positive Delta means the TEST model is an improvement)

            stats_null = parsed_null["statistics"]
            stats_xabs = parsed_xabs["statistics"]

            c_null = stats_null["cstat"]
            dof_null = stats_null["dof"]

            c_xabs = stats_xabs["cstat"]
            dof_xabs = stats_xabs["dof"]

            # Dynamically calculate k: try 'nfree' from the log stats, fallback
            # to counting 'thawn' parameters
            k_null = stats_null.get("nfree") or sum(
                1 for p in parsed_null["parameters"] if p.get("status") == "thawn")
            k_xabs = stats_xabs.get("nfree") or sum(
                1 for p in parsed_xabs["parameters"] if p.get("status") == "thawn")

            # Calculate N (data points) and BIC for both models
            # N should be identical for both fits, but calculating it per-model
            # ensures mathematical consistency
            N_null = dof_null + k_null
            N_xabs = dof_xabs + k_xabs

            bic_null = c_null + k_null * math.log(N_null)
            bic_xabs = c_xabs + k_xabs * math.log(N_xabs)
            delta_bic = bic_null - bic_xabs

            # 4. Parameter Comparison Table
            p_null = {p["name"]: p for p in parsed_null["parameters"]}
            p_xabs = {p["name"]: p for p in parsed_xabs["parameters"]}

            all_names = sorted(list(set(p_null.keys()) | set(p_xabs.keys())))
            param_lines = [
                "Parameter Comparison (relevant only):", f"{'Parameter':<20} {'NULL Model':<20} {'TEST Model (xabs)':<20}", "-" * 60]
            for name in all_names:
                p_n = p_null.get(name)
                p_x = p_xabs.get(name)

                v_n = p_n.get("value") if p_n else None
                v_x = p_x.get("value") if p_x else None

                # Filter: only show if thawn, or if value differs, or if only
                # in one model
                is_thawn = (
                    p_n and p_n.get("status") == "thawn") or (
                    p_x and p_x.get("status") == "thawn")
                differs = v_n != v_x
                only_in_one = (p_n is None) != (p_x is None)

                if is_thawn or differs or only_in_one:
                    s_null = f"{v_n:.4e}" if v_n is not None else "N/A"
                    s_xabs = f"{v_x:.4e}" if v_x is not None else "N/A"
                    param_lines.append(f"{name:<20} {s_null:<20} {s_xabs:<20}")
            param_lines.append("-" * 60)
            param_table = "\n".join(param_lines)

            if delta_bic > 10:
                conclusion = "Strong evidence that xabs IS required (Delta BIC > 10)."
            elif delta_bic > 2:
                conclusion = "Positive evidence that xabs is required."
            elif delta_bic < -2:
                conclusion = "Evidence that xabs is NOT required (Null model preferred)."
            else:
                conclusion = "Weak evidence / Indeterminate."

            report = (
                "============================================================\n"
                "AUTOMATED BIC TEST: xabs significance\n"
                "============================================================\n"
                f"NULL Model (No xabs): C-stat={c_null:.2f}, DOF={dof_null}, BIC={bic_null:.2f}\n"
                f"TEST Model (xabs):    C-stat={c_xabs:.2f}, DOF={dof_xabs}, BIC={bic_xabs:.2f}\n"
                f"Delta BIC:           {delta_bic:.2f}\n"
                "----------------------------------------\n"
                f"{param_table}\n"
                f"CONCLUSION: {conclusion}\n"
                "============================================================\n"
            )

            print("\n" + report)

            bic_report_path = paths_null.artifact_dirs["summaries"] / f"bic_test_{cfg.instrument}_{paths_null.interval_tag}.txt"
            _write_text(bic_report_path, report)
            print(f"Wrote BIC test results to: {bic_report_path}")

        else:
            # SPEX's own `log out` writes to this file (see workflow.py)
            spex_log = paths.artifact_dirs["logs"] / \
                f"spex_output_{cfg.instrument}_{paths.interval_tag}.log"
            print(
                f"Running SPEX with {args.spex_bin!r}; SPEX log -> {spex_log}.out")
            _run_spex_batch(args.spex_bin, command_path, spex_log, cfg.spex_threads)

            # Parse the SPEX-internal log (.out extension added by SPEX)
            spex_log_out = spex_log.with_suffix(".log.out")
            if spex_log_out.exists():
                if cfg.blind_search_run:
                    print("Parsing blind search log...")
                    if cfg.instrument == "pn":
                        e_min, e_max = cfg.pn_energy_min, cfg.pn_energy_max
                    else:
                        e_max, e_min = 12.3984 / cfg.rgs_lam_min, 12.3984 / cfg.rgs_lam_max
                    
                    grid = _make_scan_grid(
                        e_min, 
                        e_max, 
                        cfg.blind_search_dlam, 
                        cfg.instrument, 
                        cfg.blind_search_max_points
                    )
                    ls_dir = paths.artifact_dirs["line_search"]
                    csv_path = ls_dir / f"blind_search_{cfg.instrument}_{paths.interval_tag}.csv"
                    plot_path = ls_dir / f"blind_search_{cfg.instrument}_{paths.interval_tag}.png" if cfg.blind_search_make_plot else None
                    parse_blind_search_log(spex_log_out, csv_path, plot_path, grid)
                
                parsed = parse_spex_log(spex_log_out)
                summary_json = write_summary_json(
                    paths.artifact_dirs["summaries"] /
                    f"fit_summary_{cfg.instrument}_{paths.interval_tag}.json",
                    parsed)
                summary_txt = write_summary_txt(
                    paths.artifact_dirs["summaries"] /
                    f"fit_summary_{cfg.instrument}_{paths.interval_tag}.txt",
                    parsed)
                print(f"Wrote parsed summary (JSON): {summary_json}")
                print(f"Wrote parsed summary (TXT): {summary_txt}")
            else:
                print(f"Warning: SPEX log not found at {spex_log_out}; skipping summary generation.")
    else:
        print("Not running SPEX yet; use --run to execute the generated batch file.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
