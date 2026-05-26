"""Render a CLI-only SPEX batch workflow.

This module writes human-readable SPEX batch scripts and keeps the repository's
run-directory layout consistent across observations.

It implements a 3-stage fitting strategy for robustness:
1. Fit continuum/thermal normalizations while shape and absorption are frozen.
2. Thaw absorption parameters (nh, xil, fcov) and refit (if include_xabs is True).
3. Thaw continuum shape (pow gamma or comt t1) for a final optimization.

The `xabs` component can be toggled via the `include_xabs` flag or `--no-xabs` CLI option.
Grouping is performed inside SPEX via `obin` or `vbin`.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class WorkflowConfig:
    obsid: str
    instrument: str
    interval: str = "Full"

    thermal_model: str = "dbb"
    # Can be 'pow' or 'comt' (nthcomp equivalent)
    continuum_model: str = "comt"
    include_xabs: bool = True      # Whether to include the xabs absorption component
    fit_iter_cap: int | None = 100  # Maximum iterations for SPEX fit command
    spex_threads: int | None = 4
    overwrite_conversion: bool = False
    blind_search_run: bool = False
    blind_search_dlam: float = 0.1
    blind_search_max_points: int | None = 120
    blind_search_iter_cap: int | None = 8
    blind_search_refit_baseline: bool = False
    blind_search_make_plot: bool = True
    use_scientific_notation: bool = True
    best_fit_params_file: Path | None = None
    binning_strategy: str = "optimal"
    min_counts_threshold: int = 20
    pn_energy_min: float = 0.6  # keV
    pn_energy_max: float = 10.0  # keV
    rgs_lam_min: float = 5.0    # Angstroms
    rgs_lam_max: float = 38.0   # Angstroms
    rgs_regions: str = "1:4"
    multi_sector: bool = False  # Treat RGS1/RGS2 as separate SPEX sectors for cross-calibration
    log_suffix: str = ""     # Optional suffix for the log filename
    quit_at_end: bool = True # Whether to append 'quit' at the end of the script


@dataclass(frozen=True)
class WorkflowPaths:
    repo_root: Path
    products_root: Path
    spex_out_base: Path
    interval_tag: str
    fit_artifact_dir: Path
    artifact_dirs: dict[str, Path] = field(default_factory=dict)


def resolve_paths(repo_root: Path, cfg: WorkflowConfig) -> WorkflowPaths:
    data_name = f"{cfg.instrument}_{cfg.interval}_spex"
    spex_out_base = (
        repo_root / "products" / cfg.obsid / cfg.instrument / "spex"
        / data_name
    )
    interval_tag = cfg.interval
    fit_artifact_dir = spex_out_base.parent / interval_tag
    artifact_dirs = {
        "logs": fit_artifact_dir / "logs",
        "tables": fit_artifact_dir / "fit_tables",
        "summaries": fit_artifact_dir / "summaries",
        "line_search": fit_artifact_dir / "line_search",
        "plots": fit_artifact_dir / "plots",
        "commands": fit_artifact_dir / "commands",
    }
    return WorkflowPaths(
        repo_root=repo_root,
        products_root=repo_root / "products",
        spex_out_base=spex_out_base,
        interval_tag=interval_tag,
        fit_artifact_dir=fit_artifact_dir,
        artifact_dirs=artifact_dirs,
    )


def _quote(path: Path) -> str:
    return f'"{path.as_posix()}"'


def _join_lines(lines: Iterable[str]) -> str:
    return "\n".join(lines).rstrip() + "\n"


def _load_best_fit_params(path: Path) -> dict:
    """Load best-fit parameter values from a JSON file."""
    with open(path, "r", encoding="utf-8") as f:
        params = json.load(f)
    # Strip the _comment key if present
    params.pop("_comment", None)
    return params

def _make_scan_grid(
    energy_min: float, 
    energy_max: float, 
    d_lam: float, 
    instrument: str,
    max_points: int | None = None
) -> list[tuple[float, float]]:
    """Generate a scan grid tailored to the physical instrument resolution."""
    grid = []
    
    if instrument == "pn":
        # EPIC-pn (CCD): Resolution scales with sqrt(E).
        # FWHM is roughly 150 eV (0.15 keV) at 6 keV.
        current_e = energy_min
        
        while current_e <= energy_max:
            lam_ang = 12.3984 / current_e
            grid.append((current_e, lam_ang))
            
            # Calculate physical FWHM at the current energy
            fwhm_kev = 0.15 * math.sqrt(current_e / 6.0)
            
            # Step by 1/3 of the FWHM to ensure no lines are skipped (oversampling)
            step_size = fwhm_kev / 3.0
            current_e += step_size
            
            if max_points and len(grid) >= max_points:
                print(f"WARNING: Blind search grid truncated at {max_points} points (reached {current_e:.2f} keV).")
                print(f"         Increase --blind-search-max-points to cover the full {energy_min}-{energy_max} keV range.")
                break
                
    elif instrument == "rgs":
        # RGS (Grating): Constant velocity resolution (logarithmic grid)
        if max_points is None or max_points <= 0:
            lam_max = 12.3984 / energy_min
            max_points = int(lam_max / d_lam)
            
        log_e_min = math.log(energy_min)
        log_e_max = math.log(energy_max)
        d_log_e = (log_e_max - log_e_min) / max_points
        
        for i in range(max_points + 1):
            e_kev = math.exp(log_e_min + i * d_log_e)
            lam_ang = 12.3984 / e_kev
            grid.append((e_kev, lam_ang))
            
    else:
        raise ValueError(f"Unsupported instrument for grid generation: {instrument}")
            
    return grid


def _fmt_val(value: float) -> str:
    """Format a float value for SPEX parameter commands."""
    if value == 0.0:
        return "0.0"
    # Use scientific notation for very small or very large numbers
    if abs(value) < 0.01 or abs(value) >= 1e4:
        return f"{value:.4e}"
    return f"{value}"


def render_fit_script(cfg: WorkflowConfig, paths: WorkflowPaths, fit_model: bool = True, plot_device: str = "cps") -> str:
    base_name = paths.spex_out_base.name
    log_filename = f"spex_output_{cfg.instrument}_{paths.interval_tag}{cfg.log_suffix}.log"

    # Load best-fit params if provided, otherwise use defaults
    if cfg.best_fit_params_file is not None:
        params = _load_best_fit_params(cfg.best_fit_params_file)
    else:
        params = None

    lines: list[str] = [
        "# Auto-generated SPEX batch script",
        f"# obsid={cfg.obsid} instrument={cfg.instrument} interval={cfg.interval}",
        f"# Grouping is performed by SPEX ({cfg.binning_strategy} / {'vbin' if cfg.binning_strategy == 'min_counts' else 'obin'}) — input data is ungrouped.",
        f"# base_name={base_name}",
        "",
    ]

    # Threading is controlled via OMP_NUM_THREADS environment variable
    # (set in run_workflow.py _run_spex_batch)

    lines.extend([
        f"log out {log_filename}",
        "",
    ])

    if cfg.multi_sector and cfg.instrument == "rgs":
        # Multi-sector: load separate files; each `data` command creates a new instrument
        # RGS1 -> instrument 1 (sector 1), RGS2 -> instrument 2 (sector 2)
        rgs1_name = f"rgs1_{cfg.interval}_spex"
        rgs2_name = f"rgs2_{cfg.interval}_spex"
        lines.extend([
            f"data ../../{rgs1_name} ../../{rgs1_name}",
            f"data ../../{rgs2_name} ../../{rgs2_name}",
            "",
        ])
    else:
        lines.extend([
            f"data ../../{base_name} ../../{base_name}",
            "",
        ])

    lines.extend([
        "abun reset",
        "dist 13.0 kpc",
        "",
    ])

    snr_str = f"{math.sqrt(cfg.min_counts_threshold):.2f}"

    if cfg.instrument == "pn":
        lines += [
            f"ign 0.0:{cfg.pn_energy_min} unit kev",
            f"ign {cfg.pn_energy_max}:100.0 unit kev",
        ]
        if cfg.binning_strategy == "min_counts":
            lines.append(
                f"vbin ins 1 reg 1 {cfg.pn_energy_min}:{cfg.pn_energy_max} 1 {snr_str} unit kev")
        elif cfg.binning_strategy == "optimal":
            lines.append(
                f"obin ins 1 reg 1 {cfg.pn_energy_min}:{cfg.pn_energy_max} unit kev")
        # If "none", do not append any binning command
    elif cfg.instrument == "rgs" and cfg.multi_sector:
        # Use native RGS Angstrom limits
        lam_min = cfg.rgs_lam_min
        lam_max = cfg.rgs_lam_max
        
        lines += [
            "# Multi-sector setup: RGS1 (ins 1) + RGS2 (ins 2)",
            "ign ins 1:2 0.0:1000.0 unit a",
        ]
        
        for reg_chunk in cfg.rgs_regions.split(","):
            reg_chunk = reg_chunk.strip()
            lines += [
                f"use ins 1:2 reg {reg_chunk} 0.0:1000.0 unit a",
                f"ign ins 1:2 reg {reg_chunk} 0.0:{lam_min:.4f} unit a",
                f"ign ins 1:2 reg {reg_chunk} {lam_max:.4f}:1000.0 unit a",
            ]
            if cfg.binning_strategy == "min_counts":
                lines.append(f"vbin ins 1:2 reg {reg_chunk} {lam_min:.4f}:{lam_max:.4f} 1 {snr_str} unit a")
            elif cfg.binning_strategy == "optimal":
                lines.append(f"obin ins 1:2 reg {reg_chunk} {lam_min:.4f}:{lam_max:.4f} unit a")

    elif cfg.instrument == "rgs":
        # Single-sector RGS mode (original behaviour)
        lam_min = cfg.rgs_lam_min
        lam_max = cfg.rgs_lam_max
        
        lines += [
            "ign ins 1 reg 1:4 0.0:1000.0 unit a",  # First, ignore everything
        ]
        
        for reg_chunk in cfg.rgs_regions.split(","):
            reg_chunk = reg_chunk.strip()
            lines += [
                f"use ins 1 reg {reg_chunk} 0.0:1000.0 unit a",  # Use the requested region
                f"ign ins 1 reg {reg_chunk} 0.0:{lam_min:.4f} unit a", # Trim edges
                f"ign ins 1 reg {reg_chunk} {lam_max:.4f}:1000.0 unit a",
            ]
            if cfg.binning_strategy == "min_counts":
                lines.append(f"vbin ins 1 reg {reg_chunk} {lam_min:.4f}:{lam_max:.4f} 1 {snr_str} unit a")
            elif cfg.binning_strategy == "optimal":
                lines.append(f"obin ins 1 reg {reg_chunk} {lam_min:.4f}:{lam_max:.4f} unit a")
        # If "none", do not append any binning command
    else:
        raise ValueError("instrument must be 'pn' or 'rgs'")

    idx_hot = 1
    idx_xabs = 2 if cfg.include_xabs else None
    idx_dbb = 3 if cfg.include_xabs else 2
    idx_cont = 4 if cfg.include_xabs else 3

    lines += [
        #"var calc qc",
        #"ions nmax all 5",
        # "fit print 0",
        "",
        "com hot",
    ]
    if cfg.include_xabs:
        lines.append("com xabs")

    lines += [
        f"com {cfg.thermal_model}",
        f"com {cfg.continuum_model}",
        f"com rel {idx_dbb} {idx_hot}{',' + str(idx_xabs) if idx_xabs else ''}",
        f"com rel {idx_cont} {idx_hot}{',' + str(idx_xabs) if idx_xabs else ''}",
    ]

    # Multi-sector: duplicate the model structure to Sector 2
    if cfg.multi_sector:
        lines += [
            "",
            "# Copy the full model from Sector 1 to Sector 2",
            "sector copy 1",
        ]

    params = params or {}
    hot = params.get("hot", {})
    xabs = params.get("xabs", {})
    dbb = params.get("dbb", {})
    cont = params.get(cfg.continuum_model, {})

    lines += [
        "",
        "# Set initial model parameters",
        f"par 1 {idx_hot} t v {_fmt_val(hot.get('t', 0.0008))}",
        f"par 1 {idx_hot} t stat {hot.get('t_status', 'frozen')}",
        f"par 1 {idx_hot} nh v {_fmt_val(hot.get('nh', 0.002))}",
        f"par 1 {idx_hot} nh stat {hot.get('nh_status', 'frozen')}",
        "",
    ]
    if cfg.include_xabs:
        lines += [
            f"par 1 {idx_xabs} nh v {_fmt_val(xabs.get('nh', 0.003))}",
            f"par 1 {idx_xabs} nh stat {xabs.get('nh_status', 'thawn')}",
            f"par 1 {idx_xabs} nh range 0.0:1.0e10",
            f"par 1 {idx_xabs} xil v {_fmt_val(xabs.get('xil', 2.0))}",
            f"par 1 {idx_xabs} xil stat {xabs.get('xil_status', 'thawn')}",
            f"par 1 {idx_xabs} xil range -4.0:5.0",
            f"par 1 {idx_xabs} fcov v {_fmt_val(xabs.get('fcov', 0.7))}",
            f"par 1 {idx_xabs} fcov stat {xabs.get('fcov_status', 'thawn')}",
            f"par 1 {idx_xabs} fcov range 0.0:1.0",
            "",
        ]

    lines += [
        f"par 1 {idx_dbb} t v {_fmt_val(dbb.get('t', 0.5))}",
        f"par 1 {idx_dbb} t stat {dbb.get('t_status', 'thawn')}",
        f"par 1 {idx_dbb} norm v {_fmt_val(dbb.get('norm', 1.0e-6))}",
        f"par 1 {idx_dbb} norm stat {dbb.get('norm_status', 'thawn')}",
        "",
    ]
    if cfg.continuum_model == "pow":
        lines += [
            f"par 1 {idx_cont} gamm v {_fmt_val(cont.get('gamm', 1.5))}",
            f"par 1 {idx_cont} gamm stat {cont.get('gamm_status', 'thawn')}",
            f"par 1 {idx_cont} norm v {_fmt_val(cont.get('norm', 1.0e-3))}",
            f"par 1 {idx_cont} norm stat {cont.get('norm_status', 'thawn')}",
        ]
    elif cfg.continuum_model == "comt":
        lines += [
            f"par 1 {idx_cont} t0 couple 1 {idx_dbb} t",
            f"par 1 {idx_cont} t1 v {_fmt_val(cont.get('t1', 50.0))}",
            f"par 1 {idx_cont} t1 stat {cont.get('t1_status', 'frozen')}",
            "# Force tau to 2.0 and freeze it (user request)",
            f"par 1 {idx_cont} tau v {_fmt_val(cont.get('tau', 2.0))}",
            f"par 1 {idx_cont} tau stat {cont.get('tau_status', 'frozen')}",
            f"par 1 {idx_cont} tau range 0.0:10.0",
            f"par 1 {idx_cont} norm v {_fmt_val(cont.get('norm', 1.0e-3))}",
            f"par 1 {idx_cont} norm stat {cont.get('norm_status', 'thawn')}",
        ]

    # Multi-sector: couple shape parameters (Sector 2 → Sector 1), untie norms
    if cfg.multi_sector:
        lines += [
            "",
            "# " + "="*60,
            "# CROSS-CALIBRATION: Couple shape, untie normalizations",
            "# " + "="*60,
            "",
            "# Couple absorption / ISM shape",
            f"par 2 {idx_hot} t couple 1 {idx_hot} t",
            f"par 2 {idx_hot} nh couple 1 {idx_hot} nh",
        ]
        if cfg.include_xabs:
            lines += [
                "",
                "# Couple xabs shape",
                f"par 2 {idx_xabs} nh couple 1 {idx_xabs} nh",
                f"par 2 {idx_xabs} xil couple 1 {idx_xabs} xil",
                f"par 2 {idx_xabs} fcov couple 1 {idx_xabs} fcov",
            ]
        lines += [
            "",
            "# Couple thermal shape (temperature only — norm stays free)",
            f"par 2 {idx_dbb} t couple 1 {idx_dbb} t",
        ]
        if cfg.continuum_model == "pow":
            lines += [
                "",
                "# Couple power-law shape",
                f"par 2 {idx_cont} gamm couple 1 {idx_cont} gamm",
            ]
        elif cfg.continuum_model == "comt":
            lines += [
                "",
                "# Couple Comptonization shape",
                f"par 2 {idx_cont} t0 couple 1 {idx_cont} t0",
                f"par 2 {idx_cont} t1 couple 1 {idx_cont} t1",
                f"par 2 {idx_cont} tau couple 1 {idx_cont} tau",
            ]
        lines += [
            "",
            "# Couple normalizations for physical consistency",
            f"par 2 {idx_dbb} norm couple 1 {idx_dbb} norm",
            f"par 2 {idx_cont} norm couple 1 {idx_cont} norm",
            "",
            "# Untie instrument normalization for cross-calibration (leaving instrument 1 frozen at 1.0)",
            "par -2 1 norm stat thawn",
        ]

    if fit_model:
        lines += [
            "",
            "fit stat cstat",
        ]

        if cfg.fit_iter_cap is not None:
            lines.append(f"fit iter {int(cfg.fit_iter_cap)}")

        lines += [
            "fit",
            "",
        ]
    else:
        lines.append("")
        lines.append("# Skipping fit commands")
        if cfg.quit_at_end:
            lines.append("fit iter 0")

    lines += ["",
              "par show free",
              ]

    if cfg.quit_at_end:
        lines += [
              "",
              "# Save the final fit parameters",
              "par write ../best_fit_model overwrite",
              "",
              "# Create a plot",
              f"plot dev {plot_device} {'../plots/fit_plot' + cfg.log_suffix + '.ps' if plot_device == 'cps' else ''}",
              "plot type data",
              "plot ux a" if cfg.instrument == "rgs" else "plot ux kev",
              "plot x log",
              "plot y log",
              "plot line disp t",
              "",
              "# --- Frame 1: Data + Model ---",
              "plot set 1",
              "plot data col 1",
              "plot model col 2",
              "plot data errx f",]

        if cfg.multi_sector:
            lines += [
                  "plot set 2",
                  "plot data col 3",   # green for sector 2 data
                  "plot model col 4",  # blue for sector 2 model
                  "plot data errx f",]

        lines += [
                  "",
                  "# --- Frame 2: Residuals (chi) ---",
                  "plot frame new",
                  "plot frame 2",
                  "plot type chi",
                  "plot ux a" if cfg.instrument == "rgs" else "plot ux kev",
                  "plot x log",
                  "plot y lin",
                  "",
                  "plot set 1",
                  "plot data symbol 17",
                  "plot line disp f",      # Stops connecting lines for RGS1
                  "plot data errx f",]     # Hides x error bars for RGS1

        if cfg.multi_sector:
            lines += [
                  # --- RGS 2 ---
                  "plot set 2",
                  "plot data symbol 17",
                  "plot line disp f",      # Stops connecting lines for RGS2
                  "plot data errx f",]     # Hides x error bars for RGS2

        lines += [
                  "",
                  "# --- Layout ---",
                  "plot cap id f",
                  "plot view def f",
                  "plot view x 0.08:0.92",
                  "plot view y 0.1:0.3",
                  "plot frame 1",
                  "plot view def f",
                  "plot ry 0.005:1.0",
                  "plot view x 0.08:0.92",
                  "plot view y 0.3:1.0",
                  "plot box numlab bot f",
                  "plot cap x f",
                  "plot",
                  "plot close 1",
                  ]
    else:
        lines += [
            "",
            "# Setup complete. You can now use `fit` and `plot` interactively.",
        ]

    if cfg.blind_search_run:
        lines += [
            "",
            "# " + "="*60,
            "# BLIND LINE SEARCH",
            "# " + "="*60,
        ]
        if cfg.blind_search_refit_baseline:
            lines += [
                "# Refit baseline model to ensure best-fit baseline before freezing",
                "fit",
                "",
            ]
        lines += [
            "com gaus",
        ]
        idx_gaus = idx_cont + 1
        lines += [
            f"com rel {idx_gaus} {idx_hot}{',' + str(idx_xabs) if idx_xabs else ''}",
            "",
            "# Freeze all continuum and absorption parameters",
            f"par 1 {idx_hot} nh stat frozen",
            f"par 1 {idx_hot} t stat frozen",
            f"par 1 {idx_dbb} t stat frozen",
            f"par 1 {idx_dbb} norm stat frozen",
        ]
        
        if cfg.continuum_model == "pow":
            lines.append(f"par 1 {idx_cont} gamm stat frozen")
            lines.append(f"par 1 {idx_cont} norm stat frozen")
        elif cfg.continuum_model == "comt":
            lines.append(f"par 1 {idx_cont} t1 stat frozen")
            lines.append(f"par 1 {idx_cont} tau stat frozen")
            lines.append(f"par 1 {idx_cont} norm stat frozen")
            
        if cfg.include_xabs:
            lines.append(f"par 1 {idx_xabs} nh stat frozen")
            lines.append(f"par 1 {idx_xabs} xil stat frozen")
            lines.append(f"par 1 {idx_xabs} fcov stat frozen")

        lines += [
            f"par 1 {idx_gaus} norm v 0.0",
            f"par 1 {idx_gaus} norm stat frozen",
            f"par 1 {idx_gaus} norm range -1.0e10:1.0e10",
            "",
            "# Output baseline stat",
            "fit iter 1",
            "fit",
            ""
        ]
        
        C_KM_S = 299792.458
        line_width_scale = 2.3548200450309493
        velocity_width_km_s = 100.0
        
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
        
        for e_kev, lam_ang in grid:
            sigma_like = (velocity_width_km_s / C_KM_S) * e_kev
            fwhm_kev = line_width_scale * sigma_like
            
            lines += [
                f"# Grid point: E = {e_kev:.4f} keV (lam = {lam_ang:.3f} A)",
                f"par 1 {idx_gaus} e v {e_kev:.4f}",
                f"par 1 {idx_gaus} e stat frozen",
                f"par 1 {idx_gaus} fwhm v {fwhm_kev:.6e}",
                f"par 1 {idx_gaus} fwhm stat frozen",
                f"par 1 {idx_gaus} norm v 1.0e-3",
                f"par 1 {idx_gaus} norm stat thawn",
            ]
            if cfg.blind_search_iter_cap:
                lines.append(f"fit iter {int(cfg.blind_search_iter_cap)}")
            lines += [
                "fit",
                "par show free",
                f"par 1 {idx_gaus} norm v 0.0",
                ""
            ]

    lines += ["",
              "log close out",
              ]
    if cfg.quit_at_end:
        lines.append("quit")

    return _join_lines(lines)


def render_plot_script(cfg: WorkflowConfig, paths: WorkflowPaths, plot_device: str = "xs") -> str:
    lines: list[str] = [
        "# Auto-generated SPEX plot script",
        f"# obsid={cfg.obsid} instrument={cfg.instrument} interval={cfg.interval}",
        "",
        "# Create a plot",
        f"plot dev {plot_device} {'../plots/fit_plot' + cfg.log_suffix + '.ps' if plot_device == 'cps' else ''}",
        "plot type data",
        "plot ux a" if cfg.instrument == "rgs" else "plot ux kev",
        "plot x log",
        "plot y log",
        "plot line disp t",
        "",
        "# --- Frame 1: Data + Model ---",
        "plot set 1",
        "plot data col 1",
        "plot model col 2",
        "plot data errx f",
    ]

    if cfg.multi_sector:
        lines += [
            "plot set 2",
            "plot data col 3",   # green for sector 2 data
            "plot model col 4",  # blue for sector 2 model
            "plot data errx f",
        ]

    lines += [
        "",
        "# --- Frame 2: Residuals (chi) ---",
        "plot frame new",
        "plot frame 2",
        "plot type chi",
        "plot ux a" if cfg.instrument == "rgs" else "plot ux kev",
        "plot x log",
        "plot y lin",
        "",
        "plot set 1",
        "plot data symbol 17",
        "plot line disp f",      # Stops connecting lines for RGS1
        "plot data errx f",      # Hides x error bars for RGS1
    ]

    if cfg.multi_sector:
        lines += [
            # --- RGS 2 ---
            "plot set 2",
            "plot data symbol 17",
            "plot line disp f",      # Stops connecting lines for RGS2
            "plot data errx f",      # Hides x error bars for RGS2
        ]

    lines += [
        "",
        "# --- Layout ---",
        "plot cap id f",
        "plot view def f",
        "plot view x 0.08:0.92",
        "plot view y 0.1:0.3",
        "plot frame 1",
        "plot view def f",
        "plot ry 0.005:1.0",
        "plot view x 0.08:0.92",
        "plot view y 0.3:1.0",
        "plot box numlab bot f",
        "plot cap x f",
        "plot",
    ]
    if plot_device == "cps":
        lines.append("plot close 1")
        
    return _join_lines(lines)


def build_workflow(
        repo_root: Path, cfg: WorkflowConfig, fit_model: bool = True, plot_device: str = "cps") -> tuple[WorkflowPaths, str, str]:
    paths = resolve_paths(repo_root, cfg)
    script = render_fit_script(cfg, paths, fit_model=fit_model, plot_device=plot_device)
    plot_script = render_plot_script(cfg, paths, plot_device="xs")
    return paths, script, plot_script
