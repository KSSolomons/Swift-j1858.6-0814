#!/usr/bin/env python3
"""Standalone PyXspec blind line-search runner for PN and RGS.

This script ports the notebook blind-search workflow into a CLI tool:
- resolve PN/RGS OGIP products from this repository layout
- load a user-provided continuum expression
- fit continuum once (optional)
- freeze continuum, add a Gaussian line, and scan on a wavelength grid
- write CSV results + a diagnostic PNG
"""

from __future__ import annotations

import argparse
import functools
import json
import sys
import os
from pathlib import Path
from typing import Iterable, Optional, NamedTuple

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# Force all print statements in this script to flush immediately.
# This prevents Jupyter/IPython from buffering the output during long fits.
print = functools.partial(print, flush=True)

C_KM_S = 299_792.458
KEV_ANGSTROM = 12.398_419_75


class SuppressC:
    """Context manager to suppress C/Fortran-level stdout/stderr."""
    def __init__(self):
        self.null_fd = None
        self.saved_stdout_fd = None
        self.saved_stderr_fd = None

    def __enter__(self):
        sys.stdout.flush()
        sys.stderr.flush()
        try:
            self.null_fd = os.open(os.devnull, os.O_WRONLY)
            self.saved_stdout_fd = os.dup(1)
            self.saved_stderr_fd = os.dup(2)
            os.dup2(self.null_fd, 1)
            os.dup2(self.null_fd, 2)
        except OSError:
            pass
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        try:
            if self.saved_stdout_fd is not None:
                os.dup2(self.saved_stdout_fd, 1)
                os.close(self.saved_stdout_fd)
            if self.saved_stderr_fd is not None:
                os.dup2(self.saved_stderr_fd, 2)
                os.close(self.saved_stderr_fd)
            if self.null_fd is not None:
                os.close(self.null_fd)
        except OSError:
            pass


class PnDataset(NamedTuple):
    spec: Path
    bkg: Path
    rmf: Path
    arf: Path


class RgsOrder1Dataset(NamedTuple):
    rgs1_spec: Path
    rgs1_bkg: Path
    rgs1_rmf: Path
    rgs2_spec: Path
    rgs2_bkg: Path
    rgs2_rmf: Path


def _first_existing(candidates: Iterable[Path]) -> Optional[Path]:
    for p in candidates:
        if p.is_file():
            return p
    return None


def _name_index(directory: Path) -> dict[str, Path]:
    return {p.name.lower(): p for p in directory.iterdir() if p.is_file()}


def _first_name_match(directory: Path, candidate_names: Iterable[str]) -> Optional[Path]:
    index = _name_index(directory)
    for name in candidate_names:
        hit = index.get(name.lower())
        if hit is not None:
            return hit
    return None


def _find_interval_dir(rgs_root: Path, interval: str) -> Path:
    candidates = [
        rgs_root / "time_intervals" / interval,
        rgs_root / "flux_resolved" / interval,
        rgs_root / interval,
    ]
    for c in candidates:
        if c.is_dir():
            return c

    # Flux-resolved folders are often named LowFlux/HighFlux while interval keys
    # are Dipping_LowFlux / Dipping_HighFlux.
    suffix_map = {
        "Dipping_LowFlux": "LowFlux",
        "Dipping_HighFlux": "HighFlux",
    }
    alt = suffix_map.get(interval)
    if alt is not None:
        for c in [rgs_root / "flux_resolved" / alt, rgs_root / "time_intervals" / alt, rgs_root / alt]:
            if c.is_dir():
                return c

    raise FileNotFoundError(
        f"Could not find an RGS interval directory for {interval!r}. "
        f"Tried: {', '.join(str(c) for c in candidates)}"
    )


def resolve_pn_dataset(products_root: Path, obsid: str, interval: str, grouped: bool) -> PnDataset:
    pn_spec_dir = products_root / obsid / "pn" / "spec"
    flux_dir = pn_spec_dir / "flux_resolved"

    if interval == "Full":
        grouped_spec_names = ["pn_source_spectrum_grp.pha", "pn_source_spectrum_grp.fits"]
        ungrouped_spec_names = ["pn_source_spectrum.fits", "pn_source_spectrum.pha"]
        bkg_names = ["pn_bkg_spectrum.fits"]
        rmf_names = ["pn_rmf.rmf"]
        arf_names = ["pn_arf.arf"]
    else:
        grouped_spec_names = [f"pn_source_{interval}_grp.pha", f"pn_source_{interval}_grp.fits"]
        ungrouped_spec_names = [f"pn_source_{interval}.fits", f"pn_source_{interval}.pha"]
        bkg_names = [f"pn_bkg_{interval}.fits"]
        rmf_names = [f"pn_rmf_{interval}.rmf", "pn_rmf.rmf"]
        arf_names = [f"pn_arf_{interval}.arf", "pn_arf.arf"]

    spec_candidates: list[Path] = []
    for name in (grouped_spec_names if grouped else ungrouped_spec_names):
        spec_candidates.extend([pn_spec_dir / name, flux_dir / name])

    bkg_candidates: list[Path] = []
    rmf_candidates: list[Path] = []
    arf_candidates: list[Path] = []
    for name in bkg_names:
        bkg_candidates.extend([pn_spec_dir / name, flux_dir / name])
    for name in rmf_names:
        rmf_candidates.extend([pn_spec_dir / name, flux_dir / name])
    for name in arf_names:
        arf_candidates.extend([pn_spec_dir / name, flux_dir / name])

    spec = _first_existing(spec_candidates)
    bkg = _first_existing(bkg_candidates)
    rmf = _first_existing(rmf_candidates)
    arf = _first_existing(arf_candidates)

    missing = []
    if spec is None:
        missing.append("spec")
    if bkg is None:
        missing.append("bkg")
    if rmf is None:
        missing.append("rmf")
    if arf is None:
        missing.append("arf")
    if missing:
        raise FileNotFoundError(
            f"Missing PN files for interval={interval!r}, grouped={grouped}: {', '.join(missing)}"
        )

    assert spec is not None and bkg is not None and rmf is not None and arf is not None
    return PnDataset(spec=spec, bkg=bkg, rmf=rmf, arf=arf)


def resolve_rgs_dataset(products_root: Path, obsid: str, interval: str, grouped: bool, order: int = 1) -> RgsOrder1Dataset:
    interval_dir = _find_interval_dir(products_root / obsid / "rgs", interval)

    if order not in {1, 2}:
        raise ValueError(f"Unsupported RGS order: {order}. Expected 1 or 2.")

    order_tag = f"o{order}"

    # The blind-search uses RGS1+RGS2 order-specific spectra.
    if interval in {"Dipping_LowFlux", "Dipping_HighFlux"}:
        stem = interval.split("_", 1)[1]
    else:
        stem = interval

    def _resolve(inst: int) -> tuple[Path, Path, Path]:
        if grouped:
            spec_names = [f"rgs{inst}_src_{order_tag}_{stem}_grp.pha", f"rgs{inst}_src_{order_tag}_{stem}_grp.fits"]
        else:
            spec_names = [f"rgs{inst}_src_{order_tag}_{stem}.fits", f"rgs{inst}_src_{order_tag}_{stem}.pha"]
        bkg_names = [f"rgs{inst}_bkg_{order_tag}_{stem}.fits"]
        rmf_names = [f"rgs{inst}_{order_tag}_{stem}.rmf"]

        spec = _first_name_match(interval_dir, spec_names)
        bkg = _first_name_match(interval_dir, bkg_names)
        rmf = _first_name_match(interval_dir, rmf_names)
        if spec is None or bkg is None or rmf is None:
            raise FileNotFoundError(
                f"Could not resolve RGS{inst} order-{order} files in {interval_dir} for interval={interval!r}, grouped={grouped}."
            )
        return spec, bkg, rmf

    s1, b1, r1 = _resolve(1)
    s2, b2, r2 = _resolve(2)
    return RgsOrder1Dataset(
        rgs1_spec=s1,
        rgs1_bkg=b1,
        rgs1_rmf=r1,
        rgs2_spec=s2,
        rgs2_bkg=b2,
        rgs2_rmf=r2,
    )


def resolve_rgs_order1_dataset(products_root: Path, obsid: str, interval: str, grouped: bool) -> RgsOrder1Dataset:
    return resolve_rgs_dataset(products_root, obsid, interval, grouped, order=1)


def _n_free_params(model) -> int:
    n = 0
    for comp_name in model.componentNames:
        comp = getattr(model, comp_name)
        for par_name in comp.parameterNames:
            p = getattr(comp, par_name)
            if (not p.frozen) and str(p.link).strip() == "":
                n += 1
    return n


def _n_free_params_groups(xspec_mod, groups: Iterable[int]) -> int:
    n = 0
    for g in groups:
        model = xspec_mod.AllModels(g)
        n += _n_free_params(model)
    return n


def _ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def _safe_overwrite_guard(path: Path, overwrite: bool) -> None:
    if path.exists() and not overwrite:
        raise FileExistsError(f"Refusing to overwrite existing file: {path} (pass --overwrite)")


def _build_pn_scan_grid(energy_min_keV: float, energy_max_keV: float, d_lambda_angstrom: float) -> list[tuple[float, float]]:
    energy = float(energy_min_keV)
    grid: list[tuple[float, float]] = []
    while energy < float(energy_max_keV):
        lam = KEV_ANGSTROM / energy
        grid.append((energy, lam))
        lam_next = lam - float(d_lambda_angstrom)
        if lam_next <= 0:
            break
        energy = KEV_ANGSTROM / lam_next
    return grid


def _build_rgs_scan_grid(lambda_min_ang: float, lambda_max_ang: float, d_lambda_angstrom: float) -> list[tuple[float, float]]:
    cur = float(lambda_min_ang)
    out: list[tuple[float, float]] = []
    while cur <= float(lambda_max_ang):
        out.append((KEV_ANGSTROM / cur, cur))
        cur += float(d_lambda_angstrom)
    return out


def _plot_three_panel(
    title: str,
    xvals,
    xerr,
    data_y,
    data_err,
    model_y,
    residuals,
    y_label: str,
    df_plot: pd.DataFrame,
    x_label: str,
    out_png: Path,
    xlim: tuple[float, float],
    label_data: str = "Data",
    label_model: str = "Model",
    second=None,
    eff_area=None,
) -> None:
    fig, (ax1, ax2, ax3) = plt.subplots(
        3,
        1,
        figsize=(14, 12),
        dpi=100,
        sharex=True,
        gridspec_kw={"height_ratios": [2.2, 1.0, 1.3], "hspace": 0.0},
    )

    ax1.errorbar(xvals, data_y, xerr=xerr, yerr=data_err, fmt="o", ms=2, elinewidth=0.8, color="black", alpha=0.7, label=label_data)
    ax1.step(xvals, model_y, where="mid", lw=1.8, color="C1", label=label_model)
    if second is not None:
        ax1.errorbar(
            second["x"],
            second["data"],
            xerr=second["xerr"],
            yerr=second["data_err"],
            fmt="o",
            ms=2,
            elinewidth=0.8,
            color="C0",
            alpha=0.55,
            label=second["label_data"],
        )
        ax1.step(second["x"], second["model"], where="mid", lw=1.5, color="C3", alpha=0.9, label=second["label_model"])

    ax1_eff = None
    if eff_area is not None:
        ax1_eff = ax1.twinx()
        eff_y_all = []
        for series in eff_area.get("series", []):
            yvals = np.asarray(series["y"], dtype=float)
            eff_y_all.append(yvals)
            ax1_eff.step(
                series["x"],
                yvals,
                where="mid",
                lw=series.get("lw", 0.9),
                ls=series.get("ls", "--"),
                color=series.get("color", "gray"),
                alpha=series.get("alpha", 0.55),
                label=series["label"],
            )
        ax1_eff.set_ylabel(eff_area.get("ylabel", "Effective area"))
        if eff_y_all:
            finite = np.concatenate([y[np.isfinite(y)] for y in eff_y_all if y.size > 0])
            if finite.size > 0:
                user_ylim = eff_area.get("ylim")
                if user_ylim is not None and len(user_ylim) == 2:
                    ax1_eff.set_ylim(float(user_ylim[0]), float(user_ylim[1]))
                else:
                    ymax = float(np.nanmax(finite))
                    if ymax > 0:
                        headroom = float(eff_area.get("headroom", 1.5))
                        ax1_eff.set_ylim(0.0, ymax * max(headroom, 1.05))
        ax1_eff.tick_params(axis="y", which="both", direction="in", colors="0.35")
        ax1_eff.spines["right"].set_color("0.35")

    ax1.set_yscale("log")
    ax1.set_ylabel(y_label)
    ax1.set_title(title)
    ax1.grid(alpha=0.3)
    handles, labels = ax1.get_legend_handles_labels()
    if ax1_eff is not None:
        eff_handles, eff_labels = ax1_eff.get_legend_handles_labels()
        handles += eff_handles
        labels += eff_labels
    ax1.legend(handles, labels, loc="best")

    ax2.step(xvals, residuals, where="mid", color="black", lw=1.2)
    if second is not None:
        ax2.step(second["x"], second["resid"], where="mid", color="C0", lw=1.0, alpha=0.8)
    ax2.axhline(0, color="red", linestyle="--")
    ax2.set_ylabel(r"Residuals ($\chi$)")
    ax2.grid(alpha=0.3)

    ax3.plot(
        df_plot["X"],
        df_plot["Signed_Delta_Stat"],
        color="red",
        lw=2,
        label=r"Signed $\Delta$stat ($|\Delta|\times$ sign(norm))",
    )
    ax3.axhline(0, color="black", linestyle="--")
    ax3.axhline(9, color="blue", linestyle=":", label=r"~3$\sigma$ (stat=9)")
    ax3.axhline(-9, color="blue", linestyle=":", alpha=0.7)
    ax3.set_xlim(*xlim)
    ax3.set_xlabel(x_label)
    ax3.set_ylabel(r"Signed $\Delta$stat")
    ax3.grid(alpha=0.3)
    ax3.legend(loc="best")

    fig.tight_layout()
    fig.savefig(out_png, dpi=300, bbox_inches="tight")
    plt.close(fig)


def _set_xspec_common(xspec_mod, fit_stat: str) -> None:
    xspec_mod.Fit.statMethod = fit_stat
    xspec_mod.Fit.query = "no"
    xspec_mod.Fit.nIterations = 100
    xspec_mod.Xset.xsect = "vern"
    xspec_mod.Xset.abund = "wilm"
    
    # DO NOT enable parallel fitting - it can cause hangs in PyXspec Model() creation
    # The issue is that Model() initialization can deadlock when parallel is enabled.
    # Serial fitting is reliable even if slightly slower.
    try:
        pass
        xspec_mod.Xset.parallel.leven = 8
        print("Enabled parallel XSPEC fitting (leven=8 cores)")
    except Exception:
        pass


def _configure_continuum_model(xspec_mod, model_expr: str, refit: bool) -> None:
    print(f"Loading continuum model: {model_expr}")
    xspec_mod.AllModels.clear()
    
    # Suppress XSPEC chatter during model initialization to avoid interactive prompts
    orig_chatter = xspec_mod.Xset.chatter
    xspec_mod.Xset.chatter = 0
    
    print("Executing xspec.Model()...")
    try:
        model = xspec_mod.Model(model_expr)
        print("xspec.Model() created successfully!")
    except Exception as e:
        print(f"Failed to load model! Exception: {e}")
        xspec_mod.Xset.chatter = orig_chatter
        raise e
    
    xspec_mod.Xset.chatter = orig_chatter
    
    # Bounded starts for tbabs and nthcomp
    def _set_par(comp_name, par_name, values, frozen=None):
        cname_match = next((c for c in model.componentNames if c.lower() == comp_name.lower()), None)
        if not cname_match: return
        comp = getattr(model, cname_match)
        pname_match = next((p for p in comp.parameterNames if p.lower() == par_name.lower()), None)
        if not pname_match: return
        
        # Safely assign arrays vs scalars
        try:
            par = getattr(comp, pname_match)
            if isinstance(values, (list, tuple)):
                par.values = values
            else:
                par.values = [values]
            if frozen is not None:
                par.frozen = frozen
        except Exception as e:
            print(f"Warning: Failed to set parameter {comp_name}.{par_name} - {e}")

    print("Setting tbabs/nthcomp/diskbb default parameters...")
    _set_par("tbabs", "nH", [0.2, 0.01, 0.01, 0.01, 5.0, 10.0])
    _set_par("nthcomp", "Gamma", [1.8, 0.01, 1.0, 1.0, 3.5, 5.0])
    _set_par("nthcomp", "kT_e", [50.0, 0.1, 1.0, 1.0, 200.0, 300.0])
    _set_par("nthcomp", "inp_type", 1.0, frozen=True)
    _set_par("nthcomp", "Redshift", [0.0, 0.001, -0.01, -0.01, 0.01, 0.01], frozen=True)
    _set_par("nthcomp", "norm", [0.003, 0.01, 1.0e-6, 1.0e-6, 1.0e3, 1.0e6])
    _set_par("diskbb", "Tin", [0.8, 0.01, 0.05, 0.05, 3.0, 5.0])
    _set_par("diskbb", "norm", [0.001, 0.01, 1.0e-4, 1.0e-4, 1.0e5, 1.0e6])
    
    # Also attempt linking kT_bb to Tin if both exist
    print("Linking kT_bb to Tin if applicable...")
    tin_idx = None
    for c in model.componentNames:
        if c.lower() == "diskbb":
            for p in getattr(model, c).parameterNames:
                if p.lower() == "tin":
                    tin_idx = getattr(getattr(model, c), p).index
    if tin_idx is not None:
        for c in model.componentNames:
            if c.lower() == "nthcomp":
                try:
                    getattr(getattr(model, c), "kT_bb").link = f"p{tin_idx}"
                except Exception:
                    pass
    
    if "zxipcf" in model_expr.lower():
        print("Setting zxipcf default parameters...")
        _set_par("zxipcf", "Nh", [0.3, 0.01, 0.001, 0.001, 100.0, 100.0])
        _set_par("zxipcf", "log_xi", [3.0, 0.01, 0.0, 0.0, 6.0, 6.0])
        _set_par("zxipcf", "CvrFract", [0.8, 0.01, 0.0, 0.0, 1.0, 1.0])
        
        # Freeze zxipcf redshift at 0 to avoid massive instability
        for c in model.componentNames:
            if c.lower() == "zxipcf":
                comp = getattr(model, c)
                getattr(comp, "Redshift").values = 0.0
                getattr(comp, "Redshift").frozen = True
                
    if refit:
        print("Running Fit.perform() for continuum...")
        xspec_mod.Fit.perform()
        print("Continuum fit completed.")


def _run_pn(args: argparse.Namespace, xspec_mod) -> int:
    print(f"Starting PN blind search... obsid={args.obsid}, interval={args.interval}")
    products_root = Path(args.products_root).expanduser().resolve()
    dataset = resolve_pn_dataset(products_root, args.obsid, args.interval, args.grouped)

    suffix = f"{args.interval}_grp" if args.grouped else args.interval
    out_dir = (
        Path(args.out_dir).expanduser().resolve()
        if args.out_dir
        else products_root / args.obsid / "pn" / "spec" / "blind_search" / suffix
    )
    out_csv = out_dir / f"blind_search_{suffix}_native.csv"
    out_png = out_dir / f"blind_search_{suffix}_native.png"
    manifest = out_dir / f"blind_search_{suffix}_manifest.json"

    _safe_overwrite_guard(out_csv, args.overwrite)
    _safe_overwrite_guard(out_png, args.overwrite)
    _safe_overwrite_guard(manifest, args.overwrite)
    out_dir.mkdir(parents=True, exist_ok=True)

    if not args.use_current_state:
        xspec_mod.AllData.clear()
        xspec_mod.AllModels.clear()
        
        # CRITICAL FIX: change working directory to data dir before loading data.
        # This ensures FITS relative paths to background/response resolve correctly inside XSPEC.
        orig_dir = os.getcwd()
        os.chdir(dataset.spec.parent)
        
        print(f"Loading spectrum: {dataset.spec.name}")
        xspec_mod.AllData(dataset.spec.name)

        s = xspec_mod.AllData(1)
        if args.use_background:
            s.background = dataset.bkg.name
        s.response = dataset.rmf.name
        s.response.arf = dataset.arf.name

        xspec_mod.Plot.xAxis = "keV"
        xspec_mod.AllData.ignore("bad")
        s.ignore(f"**-{args.energy_min:.4g} {args.energy_max:.4g}-**")

        # Restore directory
        os.chdir(orig_dir)

    xspec_mod.Plot.device = "/null"
    xspec_mod.Plot.xAxis = "keV"

    if not args.use_current_state:
        _set_xspec_common(xspec_mod, args.fit_stat)
        print("Fitting baseline continuum...")
        _configure_continuum_model(xspec_mod, args.model_expr, refit=args.refit_continuum)
    else:
        print("Using current XSPEC data and model state...")
        _set_xspec_common(xspec_mod, args.fit_stat)

    # Capture baseline unfolded data/residuals for diagnostic plotting.
    print("Extracting baseline spectrum data for plots...")
    xspec_mod.Plot.add = True
    xspec_mod.Plot("data")
    uf_x = np.array(xspec_mod.Plot.x(1))
    uf_xerr = np.array(xspec_mod.Plot.xErr(1))
    uf_data = np.array(xspec_mod.Plot.y(1))
    uf_data_err = np.array(xspec_mod.Plot.yErr(1))
    uf_model = np.array(xspec_mod.Plot.model(1))
    y_label = xspec_mod.Plot.labels()[1] if len(xspec_mod.Plot.labels()) > 1 else "Counts"
    xspec_mod.Plot("delchi")
    uf_resid = np.array(xspec_mod.Plot.y(1))

    print("Extracting effective-area curves for the diagnostic plot...")
    xspec_mod.Plot("eff")
    ea_x = np.array(xspec_mod.Plot.x(1))
    ea_y = np.array(xspec_mod.Plot.y(1))

    m1 = xspec_mod.AllModels(1)
    
    # We do a quick fit here just to make sure we have the baseline stats recorded
    # Note: args.refit_continuum may have done this already, but doing it again
    # with the final dataset loaded sets baseline_stat reliably.
    print("Calculating final baseline fit statistics...")
    xspec_mod.Xset.chatter = 0
    with SuppressC():
        xspec_mod.Fit.perform()
    baseline_stat = float(xspec_mod.Fit.statistic)
    baseline_dof = int(xspec_mod.Fit.dof)
    print(f"Baseline fit complete: {args.fit_stat}={baseline_stat:.2f} dof={baseline_dof}")
    xspec_mod.Xset.chatter = 10

    total_old_params = m1.nParameters
    saved_vals = [float(m1(i).values[0]) for i in range(1, total_old_params + 1)]

    print("Appending gaussian line to model...")
    xspec_mod.Xset.chatter = 0
    with SuppressC():
        m1 = xspec_mod.Model(m1.expression + " + gauss")
    for i in range(1, total_old_params + 1):
        p = m1(i)
        p.link = ""
        p.values = [saved_vals[i - 1]]
        p.frozen = True

    idx_e = m1.nParameters - 2
    idx_sigma = m1.nParameters - 1
    idx_norm = m1.nParameters

    m1(idx_e).frozen = True
    m1(idx_sigma).frozen = True
    m1(idx_norm).values = [args.norm_guess, 1.0e-8, args.norm_min, args.norm_min, args.norm_max, args.norm_max]
    m1(idx_norm).frozen = False

    grid = _build_pn_scan_grid(args.energy_min, args.energy_max, args.dlambda)
    print(f"Starting grid scan with {len(grid)} points...")
    results = []
    
    # We only need chatter off around Fit.perform() inside the loop.
    xspec_mod.Xset.chatter = 0
    
    for step, (energy_keV, lambda_ang) in enumerate(grid, start=1):
        sigma_keV = float((args.velocity_width_kms / C_KM_S) * energy_keV)

        m1(idx_e).values = [energy_keV, -1.0, 0.0, 0.0, 100.0, 100.0]
        m1(idx_sigma).values = [sigma_keV, -1.0, 0.0, 0.0, 10.0, 10.0]
        m1(idx_norm).values = [args.norm_guess, 1.0e-8, args.norm_min, args.norm_min, args.norm_max, args.norm_max]
        m1(idx_norm).link = ""
        m1(idx_norm).frozen = False

        if args.progress_every > 0 and step % args.progress_every == 0:
            print(f"  Step {step}/{len(grid)} at E={energy_keV:.3f} keV (lambda={lambda_ang:.2f} A)... ", end="")

        fit_failed = False
        try:
            with SuppressC():
                xspec_mod.Fit.perform()
        except Exception:
            fit_failed = True

        if fit_failed:
            norm = 0.0
            fit_stat = baseline_stat
            fit_dof = baseline_dof - 1
            err_lo = np.nan
            err_hi = np.nan
        else:
            fit_stat = float(xspec_mod.Fit.statistic)
            fit_dof = int(xspec_mod.Fit.dof)
            norm = float(m1(idx_norm).values[0])
            err_lo = np.nan
            err_hi = np.nan
            if args.with_errors:
                try:
                    with SuppressC():
                        xspec_mod.Fit.error(f"1.0 {idx_norm}")
                    lo = float(m1(idx_norm).error[0])
                    hi = float(m1(idx_norm).error[1])
                    err_lo = norm - lo
                    err_hi = hi - norm
                except Exception:
                    pass

        delta_stat = baseline_stat - fit_stat
        delta_dof = baseline_dof - fit_dof

        results.append(
            {
                "Wavelength_Ang": lambda_ang,
                "E_keV": energy_keV,
                "Norm": norm,
                "Norm_err_lo": err_lo,
                "Norm_err_hi": err_hi,
                "Stat": fit_stat,
                "DoF": fit_dof,
                "Delta_Stat": delta_stat,
                "Delta_DoF": delta_dof,
            }
        )

        if args.progress_every > 0 and step % args.progress_every == 0:
            print(f"Done. DeltaStat={delta_stat:.2f}")

    xspec_mod.Xset.chatter = 10
    print("Scan complete. Writing results...")

    df = pd.DataFrame(results).sort_values("E_keV").reset_index(drop=True)
    df["Signed_Delta_Stat"] = np.abs(df["Delta_Stat"]) * np.sign(df["Norm"])
    df["X"] = df["E_keV"]

    df.to_csv(out_csv, index=False)
    _plot_three_panel(
        title=f"PN blind line search ({suffix})",
        xvals=uf_x,
        xerr=uf_xerr,
        data_y=uf_data,
        data_err=uf_data_err,
        model_y=uf_model,
        residuals=uf_resid,
        y_label=y_label,
        df_plot=df,
        x_label="Energy (keV)",
        out_png=out_png,
        xlim=(args.energy_min, args.energy_max),
        label_data="PN data",
        label_model="PN model",
        eff_area={
            "ylabel": "Effective area",
            "series": [
                {"x": ea_x, "y": ea_y, "label": "PN effective area", "color": "gray", "ls": "-"},
            ],
        },
    )

    payload = {
        "instrument": "pn",
        "obsid": args.obsid,
        "interval": args.interval,
        "grouped": args.grouped,
        "model_expr": args.model_expr,
        "fit_stat": args.fit_stat,
        "continuum_refit": args.refit_continuum,
        "dataset": {
            "spec": str(dataset.spec),
            "bkg": str(dataset.bkg),
            "rmf": str(dataset.rmf),
            "arf": str(dataset.arf),
        },
        "baseline": {"stat": baseline_stat, "dof": baseline_dof},
        "free_params_scan": _n_free_params(m1),
        "scan": {
            "energy_min_keV": args.energy_min,
            "energy_max_keV": args.energy_max,
            "d_lambda_angstrom": args.dlambda,
            "velocity_width_kms": args.velocity_width_kms,
            "grid_points": len(grid),
        },
        "outputs": {"csv": str(out_csv), "png": str(out_png)},
    }
    manifest.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    print(f"Wrote: {out_csv}")
    print(f"Wrote: {out_png}")
    print(f"Wrote: {manifest}")
    return 0


def _run_rgs(args: argparse.Namespace, xspec_mod) -> int:
    print(f"Starting RGS blind search... obsid={args.obsid}, interval={args.interval}, order={args.rgs_order}")
    products_root = Path(args.products_root).expanduser().resolve()
    dataset = resolve_rgs_dataset(products_root, args.obsid, args.interval, args.grouped, order=args.rgs_order)

    suffix = f"{args.interval}_o{args.rgs_order}_grp" if args.grouped else f"{args.interval}_o{args.rgs_order}"
    out_dir = (
        Path(args.out_dir).expanduser().resolve()
        if args.out_dir
        else dataset.rgs1_spec.parent / "blind_search" / suffix
    )
    out_csv = out_dir / f"blind_search_{suffix}_native.csv"
    out_png = out_dir / f"blind_search_{suffix}_native.png"
    manifest = out_dir / f"blind_search_{suffix}_manifest.json"

    _safe_overwrite_guard(out_csv, args.overwrite)
    _safe_overwrite_guard(out_png, args.overwrite)
    _safe_overwrite_guard(manifest, args.overwrite)
    out_dir.mkdir(parents=True, exist_ok=True)

    if not args.use_current_state:
        xspec_mod.AllData.clear()
        xspec_mod.AllModels.clear()
        
        # CRITICAL FIX: change working directory to data dir before loading data.
        orig_dir = os.getcwd()
        os.chdir(dataset.rgs1_spec.parent)
        
        xspec_mod.AllData(f"1:1 {dataset.rgs1_spec.name} 2:2 {dataset.rgs2_spec.name}")
        xspec_mod.AllData(1).background = dataset.rgs1_bkg.name
        xspec_mod.AllData(2).background = dataset.rgs2_bkg.name
        xspec_mod.AllData(1).response = dataset.rgs1_rmf.name
        xspec_mod.AllData(2).response = dataset.rgs2_rmf.name
        
        os.chdir(orig_dir)

        _set_xspec_common(xspec_mod, args.fit_stat)

        # Force XSPEC to build the energy grid by assigning the model first. 
        # When XSPEC evaluates the model, it properly resolves the response matrices.
        print("Loading continuum model to initialize wavelength grid...")
        _configure_continuum_model(xspec_mod, args.model_expr, refit=False)

        xspec_mod.Plot.device = "/null"
        xspec_mod.Plot.xAxis = "ang"
        xspec_mod.AllData.notice("all")
        
        # Now XSPEC knows the physical grid and safely interprets floats as Angstroms!
        xspec_mod.AllData.ignore(f"**-{args.lambda_min:.4g} {args.lambda_max:.4g}-**")
        
        if args.refit_continuum:
            print("Fitting baseline continuum...")
            xspec_mod.Fit.perform()
    else:
        print("Using current XSPEC data and model state...")
        _set_xspec_common(xspec_mod, args.fit_stat)

    # Set plotting axis to Angstroms for the rest of the script
    xspec_mod.Plot.device = "/null"
    xspec_mod.Plot.xAxis = "ang"

    print("Extracting baseline spectrum data for plots...")
    xspec_mod.Plot.add = False
    xspec_mod.Plot("data")
    x1 = np.array(xspec_mod.Plot.x(1))
    x1err = np.array(xspec_mod.Plot.xErr(1))
    y1 = np.array(xspec_mod.Plot.y(1))
    y1err = np.array(xspec_mod.Plot.yErr(1))
    m1y = np.array(xspec_mod.Plot.model(1))
    x2 = np.array(xspec_mod.Plot.x(2))
    x2err = np.array(xspec_mod.Plot.xErr(2))
    y2 = np.array(xspec_mod.Plot.y(2))
    y2err = np.array(xspec_mod.Plot.yErr(2))
    m2y = np.array(xspec_mod.Plot.model(2))
    y_label = xspec_mod.Plot.labels()[1] if len(xspec_mod.Plot.labels()) > 1 else "Counts"
    xspec_mod.Plot("delchi")
    r1 = np.array(xspec_mod.Plot.y(1))
    r2 = np.array(xspec_mod.Plot.y(2))

    print("Extracting effective-area curves for the diagnostic plot...")
    xspec_mod.Plot("eff")
    ea1_x = np.array(xspec_mod.Plot.x(1))
    ea1_y = np.array(xspec_mod.Plot.y(1))
    ea2_x = np.array(xspec_mod.Plot.x(2))
    ea2_y = np.array(xspec_mod.Plot.y(2))

    m1 = xspec_mod.AllModels(1)
    m2 = xspec_mod.AllModels(2)

    print("Calculating final baseline fit statistics...")
    xspec_mod.Xset.chatter = 0
    with SuppressC():
        xspec_mod.Fit.perform()
    baseline_stat = float(xspec_mod.Fit.statistic)
    baseline_dof = int(xspec_mod.Fit.dof)
    print(f"Baseline fit complete: {args.fit_stat}={baseline_stat:.2f} dof={baseline_dof}")
    xspec_mod.Xset.chatter = 10

    total_old = m1.nParameters
    saved_1 = [float(m1(i).values[0]) for i in range(1, total_old + 1)]
    saved_2 = [float(m2(i).values[0]) for i in range(1, total_old + 1)]

    print("Appending gaussian line to model...")
    xspec_mod.Xset.chatter = 0
    baseline_expr = m1.expression.strip()
    new_expr = f"{baseline_expr[:-1]} + gauss)" if baseline_expr.endswith(")") else f"{baseline_expr} + gauss"
    with SuppressC():
        m1 = xspec_mod.Model(new_expr)
        m2 = xspec_mod.AllModels(2)

    for i in range(1, total_old + 1):
        m1(i).link = ""
        m1(i).values = [saved_1[i - 1]]
        m1(i).frozen = True

        m2(i).link = ""
        m2(i).values = [saved_2[i - 1]]
        m2(i).frozen = True

    idx_e = m1.nParameters - 2
    idx_sigma = m1.nParameters - 1
    idx_norm = m1.nParameters

    m1(idx_e).frozen = True
    m1(idx_sigma).frozen = True
    m1(idx_norm).values = [args.norm_guess, 1.0e-8, args.norm_min, args.norm_min, args.norm_max, args.norm_max]
    m1(idx_norm).frozen = False

    m2(idx_e).frozen = True
    m2(idx_sigma).frozen = True
    m2(idx_norm).frozen = True
    m2(idx_e).link = f"p{m1(idx_e).index}"
    m2(idx_sigma).link = f"p{m1(idx_sigma).index}"
    m2(idx_norm).link = f"p{m1(idx_norm).index}"

    grid = _build_rgs_scan_grid(args.lambda_min, args.lambda_max, args.dlambda)
    print(f"Starting grid scan with {len(grid)} points...")
    results = []
    
    xspec_mod.Xset.chatter = 0

    for step, (energy_keV, lambda_ang) in enumerate(grid, start=1):
        sigma_keV = float((args.velocity_width_kms / C_KM_S) * energy_keV)

        m1(idx_e).values = [energy_keV, -1.0, 0.0, 0.0, 100.0, 100.0]
        m1(idx_sigma).values = [sigma_keV, -1.0, 0.0, 0.0, 10.0, 10.0]
        m1(idx_norm).values = [args.norm_guess, 1.0e-8, args.norm_min, args.norm_min, args.norm_max, args.norm_max]
        m1(idx_norm).link = ""
        m1(idx_norm).frozen = False

        # Keep the second spectrum tied to the first line parameters.
        m2(idx_e).link = f"p{m1(idx_e).index}"
        m2(idx_sigma).link = f"p{m1(idx_sigma).index}"
        m2(idx_norm).link = f"p{m1(idx_norm).index}"
        m2(idx_e).frozen = True
        m2(idx_sigma).frozen = True
        m2(idx_norm).frozen = True

        if _n_free_params_groups(xspec_mod, [1, 2]) != 1:
            results.append(
                {
                    "Wavelength_Ang": lambda_ang,
                    "E_keV": energy_keV,
                    "Norm": np.nan,
                    "Norm_err_lo": np.nan,
                    "Norm_err_hi": np.nan,
                    "Stat": baseline_stat,
                    "DoF": baseline_dof,
                    "Delta_Stat": 0.0,
                    "Delta_DoF": 0,
                }
            )
            continue

        if args.progress_every > 0 and step % args.progress_every == 0:
            print(f"  Step {step}/{len(grid)} at lambda={lambda_ang:.2f} A (E={energy_keV:.3f} keV)... ", end="")

        fit_failed = False
        try:
            with SuppressC():
                xspec_mod.Fit.perform()
        except Exception:
            fit_failed = True

        if fit_failed:
            norm = 0.0
            fit_stat = baseline_stat
            fit_dof = baseline_dof - 1
            err_lo = np.nan
            err_hi = np.nan
        else:
            fit_stat = float(xspec_mod.Fit.statistic)
            fit_dof = int(xspec_mod.Fit.dof)
            norm = float(m1(idx_norm).values[0])
            err_lo = np.nan
            err_hi = np.nan
            if args.with_errors:
                try:
                    with SuppressC():
                        xspec_mod.Fit.error(f"1.0 {idx_norm}")
                    lo = float(m1(idx_norm).error[0])
                    hi = float(m1(idx_norm).error[1])
                    err_lo = norm - lo
                    err_hi = hi - norm
                except Exception:
                    pass

        delta_stat = baseline_stat - fit_stat
        delta_dof = baseline_dof - fit_dof

        results.append(
            {
                "Wavelength_Ang": lambda_ang,
                "E_keV": energy_keV,
                "Norm": norm,
                "Norm_err_lo": err_lo,
                "Norm_err_hi": err_hi,
                "Stat": fit_stat,
                "DoF": fit_dof,
                "Delta_Stat": delta_stat,
                "Delta_DoF": delta_dof,
            }
        )

        if args.progress_every > 0 and step % args.progress_every == 0:
            print(f"Done. DeltaStat={delta_stat:.2f}")

    xspec_mod.Xset.chatter = 10
    print("Scan complete. Writing results...")

    df = pd.DataFrame(results).sort_values("Wavelength_Ang").reset_index(drop=True)
    df["Signed_Delta_Stat"] = np.abs(df["Delta_Stat"]) * np.sign(df["Norm"].fillna(0.0))
    df["X"] = df["Wavelength_Ang"]

    df.to_csv(out_csv, index=False)
    _plot_three_panel(
        title=f"RGS blind line search ({suffix})",
        xvals=x1,
        xerr=x1err,
        data_y=y1,
        data_err=y1err,
        model_y=m1y,
        residuals=r1,
        y_label=y_label,
        df_plot=df,
        x_label="Wavelength (A)",
        out_png=out_png,
        xlim=(args.lambda_min, args.lambda_max),
        label_data="RGS1 data",
        label_model="RGS1 model",
        second={
            "x": x2,
            "xerr": x2err,
            "data": y2,
            "data_err": y2err,
            "model": m2y,
            "resid": r2,
            "label_data": "RGS2 data",
            "label_model": "RGS2 model",
        },
        eff_area={
            "ylabel": "Effective area",
            "series": [
                {"x": ea1_x, "y": ea1_y, "label": "RGS1 effective area", "color": "C2", "ls": "-"},
                {"x": ea2_x, "y": ea2_y, "label": "RGS2 effective area", "color": "C4", "ls": "-"},
            ],
        },
    )

    payload = {
        "instrument": "rgs",
        "obsid": args.obsid,
        "interval": args.interval,
        "order": args.rgs_order,
        "grouped": args.grouped,
        "model_expr": args.model_expr,
        "fit_stat": args.fit_stat,
        "continuum_refit": args.refit_continuum,
        "dataset": {
            "rgs1_spec": str(dataset.rgs1_spec),
            "rgs1_bkg": str(dataset.rgs1_bkg),
            "rgs1_rmf": str(dataset.rgs1_rmf),
            "rgs2_spec": str(dataset.rgs2_spec),
            "rgs2_bkg": str(dataset.rgs2_bkg),
            "rgs2_rmf": str(dataset.rgs2_rmf),
        },
        "baseline": {"stat": baseline_stat, "dof": baseline_dof},
        "free_params_scan": _n_free_params_groups(xspec_mod, [1, 2]),
        "scan": {
            "lambda_min_ang": args.lambda_min,
            "lambda_max_ang": args.lambda_max,
            "d_lambda_angstrom": args.dlambda,
            "velocity_width_kms": args.velocity_width_kms,
            "grid_points": len(grid),
        },
        "outputs": {"csv": str(out_csv), "png": str(out_png)},
    }
    manifest.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    print(f"Wrote: {out_csv}")
    print(f"Wrote: {out_png}")
    print(f"Wrote: {manifest}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Run native PyXspec blind line search for PN or RGS")
    sub = p.add_subparsers(dest="instrument", required=True)

    def add_common(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--products-root", default="products", help="Path to products root (default: products)")
        sp.add_argument("--obsid", required=True)
        sp.add_argument("--interval", required=True)
        sp.add_argument("--grouped", action="store_true")
        sp.add_argument("--model-expr", required=True, help="Continuum model expression, e.g. 'tbabs*(nthcomp+diskbb)'")
        sp.add_argument("--fit-stat", default="cstat", choices=["cstat", "chi"], help="XSPEC fit statistic")
        sp.add_argument("--refit-continuum", action="store_true", help="Fit continuum once before blind scan")
        sp.add_argument("--velocity-width-kms", type=float, default=1000.0)
        sp.add_argument("--dlambda", type=float, default=0.01, help="Constant wavelength step in Angstrom")
        sp.add_argument("--norm-guess", type=float, default=1.0e-4)
        sp.add_argument("--norm-min", type=float, default=-1.0)
        sp.add_argument("--norm-max", type=float, default=1.0)
        sp.add_argument("--progress-every", type=int, default=50)
        sp.add_argument("--with-errors", action="store_true", help="Run XSPEC error command on line norm at each step")
        sp.add_argument("--out-dir", help="Output folder for CSV/PNG/manifest")
        sp.add_argument("--overwrite", action="store_true")
        sp.add_argument("--use-current-state", action="store_true", help="Skip clearing data/models and use the current XSPEC state")

    pn = sub.add_parser("pn", help="Run blind search on one PN spectrum")
    add_common(pn)
    pn.add_argument("--energy-min", type=float, default=0.7)
    pn.add_argument("--energy-max", type=float, default=7.0)
    pn.add_argument("--use-background", action="store_true", help="Attach background spectrum")
    pn.set_defaults(func=_run_pn)

    rgs = sub.add_parser("rgs", help="Run blind search on RGS1+RGS2 order-selected spectra")
    add_common(rgs)
    rgs.add_argument("--lambda-min", type=float, default=5.0)
    rgs.add_argument("--lambda-max", type=float, default=25.0)
    rgs.add_argument("--rgs-order", type=int, choices=[1, 2], default=1, help="RGS spectral order to use (1 or 2)")
    rgs.set_defaults(func=_run_rgs)

    return p


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        import xspec as xspec_mod
    except Exception as exc:
        print("ERROR: Could not import xspec. Activate the HEASOFT/PyXspec environment first.")
        print(f"Import detail: {exc}")
        return 1

    try:
        return args.func(args, xspec_mod)
    except Exception as exc:
        print(f"ERROR: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())