"""Reusable SPEX blind line-search helper.

This module ports the PN blind-search strategy into SPEX/pyspex:
- freeze the fitted continuum
- add a narrow additive Gaussian line (`gaus`)
- scan line centroid on a fixed wavelength grid
- fit only the line normalization at each step
- save CSV + diagnostic plot

It is designed to be imported from a notebook cell, e.g.:

    from spex_blind_search import run_blind_line_search
    df, csv_path, png_path = run_blind_line_search(s, artifact_dir=fit_artifact_dir, fit_tag=fit_tag)
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

C_KM_S = 299_792.458
KEV_ANGSTROM = 12.398_419_75
XSPEC_GAUS_SIGMA_TO_FWHM = 2.354_820_045


@dataclass
class BlindLineSearchResult:
    dataframe: pd.DataFrame
    csv_path: Path
    plot_path: Path


def _safe_float(value, default=np.nan):
    try:
        out = float(value)
    except Exception:
        return default
    return out if np.isfinite(out) else default


def _as_dataframe(tab) -> pd.DataFrame:
    if tab is None:
        return pd.DataFrame()
    if isinstance(tab, pd.DataFrame):
        return tab.copy()
    if hasattr(tab, "to_pandas"):
        return tab.to_pandas().copy()
    raise TypeError(f"Unsupported table type: {type(tab)!r}")


def _get_table(session, method_name: str) -> pd.DataFrame:
    try:
        tab = getattr(session, method_name)()
    except Exception:
        return pd.DataFrame()
    try:
        return _as_dataframe(tab)
    except Exception:
        return pd.DataFrame()


def _get_param_df(session) -> pd.DataFrame:
    # `par_show_param()` exists in this pyspex build and returns the full parameter table.
    return _get_table(session, "par_show_param")


def _get_free_df(session) -> pd.DataFrame:
    return _get_table(session, "par_show_free")


def _iter_param_rows(df: pd.DataFrame) -> Iterable[dict]:
    if df is None or df.empty:
        return []

    cols = {str(c).lower(): c for c in df.columns}
    sect_col = cols.get("sect") or cols.get("sector") or cols.get("isect")
    comp_col = cols.get("comp") or cols.get("component") or cols.get("icomp")
    name_col = cols.get("acro") or cols.get("param") or cols.get("parameter") or cols.get("name")
    value_col = cols.get("value")
    status_col = cols.get("status")

    required = [sect_col, comp_col, name_col, value_col, status_col]
    if any(c is None for c in required):
        return []

    rows = []
    for _, row in df.iterrows():
        sect_val = _safe_float(row.get(sect_col), default=np.nan)
        comp_val = _safe_float(row.get(comp_col), default=np.nan)
        if not np.isfinite(sect_val) or not np.isfinite(comp_val):
            continue
        rows.append(
            {
                "sect": int(sect_val),
                "comp": int(comp_val),
                "name": str(row.get(name_col, "")).strip(),
                "value": _safe_float(row.get(value_col), default=np.nan),
                "status": str(row.get(status_col, "")).strip().lower(),
            }
        )
    return rows


def _component_column(df: pd.DataFrame) -> str | None:
    cols = {str(c).lower(): c for c in df.columns}
    return cols.get("comp") or cols.get("component") or cols.get("icomp")


def _row_columns(df: pd.DataFrame) -> tuple[str | None, str | None, str | None, str | None]:
    cols = {str(c).lower(): c for c in df.columns}
    sect_col = cols.get("sect") or cols.get("sector") or cols.get("isect")
    comp_col = cols.get("comp") or cols.get("component") or cols.get("icomp")
    name_col = cols.get("acro") or cols.get("param") or cols.get("parameter") or cols.get("name")
    value_col = cols.get("value")
    return sect_col, comp_col, name_col, value_col


def _enforce_only_line_norm_free(session, line_comp: int, line_norm_name: str = "norm") -> tuple[int, int]:
    """Freeze any accidental free parameters and keep only line norm free.

    Returns (n_frozen, n_free_after).
    """
    frozen = 0
    free_df = _get_free_df(session)
    if free_df.empty:
        _set_param(session, 1, line_comp, line_norm_name, _safe_float(getattr(session.par_get(1, line_comp, line_norm_name), "value", 0.0), default=0.0), thaw=True)
        return 0, 1

    sect_col, comp_col, name_col, value_col = _row_columns(free_df)
    if None in (sect_col, comp_col, name_col):
        return 0, 0

    for _, row in free_df.iterrows():
        sect_val = _safe_float(row.get(sect_col), default=np.nan)
        comp_val = _safe_float(row.get(comp_col), default=np.nan)
        if not np.isfinite(sect_val) or not np.isfinite(comp_val):
            continue
        sect = int(sect_val)
        comp = int(comp_val)
        name = str(row.get(name_col, "")).strip()
        if sect <= 0 or comp <= 0 or name == "":
            continue

        keep_free = (sect == 1 and comp == int(line_comp) and name.lower() == line_norm_name.lower())
        if keep_free:
            continue

        val = _safe_float(row.get(value_col), default=np.nan) if value_col is not None else np.nan
        if not np.isfinite(val):
            val = _safe_float(getattr(session.par_get(sect, comp, name), "value", np.nan), default=np.nan)
        if not np.isfinite(val):
            continue
        _set_param(session, sect, comp, name, val, thaw=False)
        frozen += 1

    # Ensure the scan parameter is free even after defensive freezing.
    line_norm_val = _safe_float(getattr(session.par_get(1, line_comp, line_norm_name), "value", 0.0), default=0.0)
    _set_param(session, 1, line_comp, line_norm_name, line_norm_val, thaw=True)

    free_after_df = _get_free_df(session)
    n_free_after = len(free_after_df) if free_after_df is not None else 0
    return frozen, int(n_free_after)


def _set_param(session, sect: int, comp: int, name: str, value: float, thaw: bool) -> None:
    try:
        session.par(sect, comp, name, value, thawn=thaw)
        return
    except Exception:
        pass

    # Fallback through the live Parameter object if the high-level setter fails.
    p = session.par_get(sect, comp, name)
    if p is None:
        raise RuntimeError(f"Could not access parameter {sect}:{comp}:{name}")
    p.value = value
    p.free = bool(thaw)


def _freeze_baseline(session, param_df: pd.DataFrame) -> None:
    for row in _iter_param_rows(param_df):
        if row["comp"] <= 0 or row["sect"] <= 0:
            continue
        if not np.isfinite(row["value"]):
            continue
        _set_param(session, row["sect"], row["comp"], row["name"], row["value"], thaw=False)


def _restore_baseline(session, param_df: pd.DataFrame) -> None:
    for row in _iter_param_rows(param_df):
        if row["comp"] <= 0 or row["sect"] <= 0:
            continue
        if not np.isfinite(row["value"]):
            continue
        thaw = "thawn" in row["status"] or "free" in row["status"]
        _set_param(session, row["sect"], row["comp"], row["name"], row["value"], thaw=thaw)


def _make_scan_grid(energy_min_keV: float, energy_max_keV: float, d_lambda_angstrom: float) -> list[tuple[float, float]]:
    """Return [(E_keV, lambda_A), ...] using fixed wavelength stepping.

    The loop matches the PN workflow: convert the current energy to wavelength,
    subtract a fixed dLambda, then convert back to energy.
    """
    energy = float(energy_min_keV)
    out: list[tuple[float, float]] = []

    while energy < energy_max_keV:
        lam = KEV_ANGSTROM / energy
        out.append((energy, lam))
        next_lam = lam - float(d_lambda_angstrom)
        if next_lam <= 0:
            break
        energy = KEV_ANGSTROM / next_lam

    return out


def _set_line_defaults(
    session,
    line_comp: int,
    line_norm_guess: float,
    line_norm_min: float,
    line_norm_max: float,
    energy_keV: float,
    fwhm_keV: float,
) -> None:
    _set_param(session, 1, line_comp, "e", float(energy_keV), thaw=False)
    _set_param(session, 1, line_comp, "fwhm", float(fwhm_keV), thaw=False)
    try:
        session.par_range(1, line_comp, "norm", float(line_norm_min), float(line_norm_max))
    except Exception:
        pass
    _set_param(session, 1, line_comp, "norm", float(line_norm_guess), thaw=True)


def _default_line_plot(session, df: pd.DataFrame, title: str, out_path: Path, energy_min_keV: float, energy_max_keV: float) -> Path:
    mgr = session.plot_data(ylog=True)

    fig, (ax1, ax2, ax3) = plt.subplots(
        3,
        1,
        figsize=(14, 12),
        dpi=100,
        sharex=True,
        gridspec_kw={"height_ratios": [2.2, 1.0, 1.3], "hspace": 0.0},
    )

    mgr.plot_data(ax1)
    if hasattr(mgr, "plot_chi"):
        try:
            mgr.plot_chi(ax2)
        except TypeError:
            mgr.chiplot(ax2)
    elif hasattr(mgr, "chiplot"):
        mgr.chiplot(ax2)

    plot_df = df.sort_values("E_keV")
    plot_df["Signed_Delta_Stat"] = np.abs(plot_df["Delta_Stat"]) * np.sign(plot_df["Norm"])

    ax3.plot(
        plot_df["E_keV"],
        plot_df["Signed_Delta_Stat"],
        color="red",
        lw=2,
        label=r"Signed $\Delta$stat ($|\Delta|\times$ sign(norm))",
    )
    ax3.axhline(0, color="black", linestyle="--")
    ax3.axhline(9, color="blue", linestyle=":", label=r"~3$\sigma$ threshold (stat=9)")
    ax3.axhline(-9, color="blue", linestyle=":", alpha=0.7)
    ax3.set_xlim(energy_min_keV, energy_max_keV)
    ax3.set_xlabel("Energy (keV)")
    ax3.set_ylabel(r"Signed $\Delta$stat")
    ax3.grid(alpha=0.3)
    ax3.legend(loc="best")

    ax1.set_yscale("log")
    ax1.set_ylabel("Counts")
    ax1.set_title(title)
    ax1.grid(alpha=0.3)
    ax2.set_ylabel("Residuals")
    ax2.grid(alpha=0.3)

    fig.tight_layout()
    fig.savefig(out_path, dpi=300, bbox_inches="tight")
    plt.show()
    return out_path


def run_blind_line_search(
    session,
    *,
    artifact_dir: Path,
    fit_tag: str,
    energy_min_keV: float = 0.7,
    energy_max_keV: float = 7.0,
    d_lambda_angstrom: float = 0.1,
    velocity_width_km_s: float = 1000.0,
    line_component_name: str = "gaus",
    line_norm_guess: float = 1.0e-1,
    line_norm_min: float = -1.0,
    line_norm_max: float = 1.0,
    fit_stat: str = "cstat",
    fit_iter_cap: Optional[int] = None,
    refit_baseline: bool = True,
    line_width_scale: float = XSPEC_GAUS_SIGMA_TO_FWHM,
    progress_every: int = 50,
    make_plot: bool = True,
    max_grid_points: Optional[int] = None,
    enforce_single_free_param: bool = True,
) -> BlindLineSearchResult:
    """Run a PN-style blind line search inside an already-loaded SPEX session.

    Parameters
    ----------
    session:
        Active `pyspex.spex.Session` with the best-fit continuum already defined.
    artifact_dir:
        Folder where CSV and PNG outputs will be written.
    fit_tag:
        Short tag added to the output filenames.
    energy_min_keV, energy_max_keV:
        Energy range searched.
    d_lambda_angstrom:
        Constant wavelength step, matching the original PN workflow.
    velocity_width_km_s:
        Velocity width used to set the trial line width.
        The SPEX `gaus` component uses FWHM, so the XSPEC-style sigma equivalent
        is converted by `line_width_scale` (default = 2.3548...).
    line_component_name:
        SPEX additive line component; `gaus` works in this environment.
    line_norm_guess, line_norm_min, line_norm_max:
        Starting value and allowed range for the line normalization.
    fit_stat:
        Fit statistic to use; typically `cstat`.
    fit_iter_cap:
        Optional iteration cap passed to SPEX before each fit.
    refit_baseline:
        If True, rerun the baseline fit once before scanning so the baseline
        statistic is measured under the same fit settings.
    line_width_scale:
        Multiply the XSPEC sigma-like width by this factor to obtain the SPEX
        `gaus` FWHM. Leave at 1.0 if you want to treat `velocity_width_km_s` as
        a direct FWHM-equivalent scale instead.
    progress_every:
        Print a progress message every N grid points.
    make_plot:
        If True, create a combined spectrum/residual/search plot.
    max_grid_points:
        Optional cap on the number of searched grid points. If provided and the
        native grid is denser, it is downsampled uniformly.
    enforce_single_free_param:
        If True, defensively freeze all free parameters except the line norm
        before the scan starts.

    Returns
    -------
    BlindLineSearchResult
        Dataclass containing the dataframe plus saved CSV/PNG paths.
    """

    artifact_dir = Path(artifact_dir)
    artifact_dir.mkdir(parents=True, exist_ok=True)

    try:
        session.command(f"fit stat {fit_stat}")
    except Exception:
        pass

    if fit_iter_cap is not None:
        try:
            session.command(f"fit iter {int(fit_iter_cap)}")
        except Exception:
            pass

    baseline_df = _get_param_df(session)
    if baseline_df.empty:
        raise RuntimeError("Could not read the current SPEX parameter table before the line search.")

    if refit_baseline:
        session.fit()

    baseline_stat = _safe_float(getattr(session.opt_fit, "cstat", np.nan))
    baseline_dof = _safe_float(getattr(session.opt_fit, "dof", np.nan), default=np.nan)

    comp_col = _component_column(baseline_df)
    if comp_col is None:
        raise RuntimeError("Could not identify the component-number column in par_show_param() output.")
    base_components = int(pd.to_numeric(baseline_df[comp_col], errors="coerce").max())

    # Add the trial line and freeze the continuum.
    session.com(line_component_name)
    line_comp = base_components + 1
    _freeze_baseline(session, baseline_df)

    # Configure the line parameters.
    sigma_like_width = float((velocity_width_km_s / C_KM_S) * energy_min_keV)
    line_fwhm = float(line_width_scale * sigma_like_width)
    _set_line_defaults(
        session,
        line_comp=line_comp,
        line_norm_guess=line_norm_guess,
        line_norm_min=line_norm_min,
        line_norm_max=line_norm_max,
        energy_keV=energy_min_keV,
        fwhm_keV=line_fwhm,
    )

    # The active line should be the only free fit parameter in the scan.
    scan_grid = _make_scan_grid(energy_min_keV, energy_max_keV, d_lambda_angstrom)
    if max_grid_points is not None and int(max_grid_points) > 0 and len(scan_grid) > int(max_grid_points):
        stride = int(np.ceil(len(scan_grid) / float(max_grid_points)))
        scan_grid = scan_grid[::stride]
        print(f"Downsampled blind-search grid with stride={stride}; using {len(scan_grid)} points.")

    if enforce_single_free_param:
        n_frozen, n_free_after = _enforce_only_line_norm_free(session, line_comp=line_comp, line_norm_name="norm")
        print(
            "Free-parameter check: "
            f"frozen {n_frozen} unexpected free params; {n_free_after} free param(s) remain."
        )

    print(f"Starting blind search across {len(scan_grid)} grid points...")

    results = []
    for idx, (energy_keV, wavelength_ang) in enumerate(scan_grid, start=1):
        width_like = float((velocity_width_km_s / C_KM_S) * energy_keV)
        fwhm_keV = float(line_width_scale * width_like)

        _set_param(session, 1, line_comp, "e", energy_keV, thaw=False)
        _set_param(session, 1, line_comp, "fwhm", fwhm_keV, thaw=False)
        _set_param(session, 1, line_comp, "norm", line_norm_guess, thaw=True)

        fit_failed = False
        try:
            session.fit()
        except Exception:
            fit_failed = True

        if fit_failed:
            norm = 0.0
            fit_stat_val = baseline_stat
            dof_val = baseline_dof - 1 if np.isfinite(baseline_dof) else np.nan
            norm_err_lo = np.nan
            norm_err_hi = np.nan
        else:
            norm = _safe_float(getattr(session.par_get(1, line_comp, "norm"), "value", np.nan))
            fit_stat_val = _safe_float(getattr(session.opt_fit, "cstat", np.nan))
            dof_val = _safe_float(getattr(session.opt_fit, "dof", np.nan))
            norm_err_lo = np.nan
            norm_err_hi = np.nan

        delta_stat = baseline_stat - fit_stat_val
        delta_dof = baseline_dof - dof_val if np.isfinite(baseline_dof) and np.isfinite(dof_val) else np.nan
        results.append(
            {
                "Wavelength_Ang": wavelength_ang,
                "E_keV": energy_keV,
                "FWHM_keV": fwhm_keV,
                "Norm": norm,
                "Norm_err_lo": norm_err_lo,
                "Norm_err_hi": norm_err_hi,
                "Stat": fit_stat_val,
                "DoF": dof_val,
                "Delta_Stat": delta_stat,
                "Delta_DoF": delta_dof,
            }
        )

        if progress_every and idx % int(progress_every) == 0:
            print(
                f"Progress: {idx}/{len(scan_grid)} | E = {energy_keV:.3f} keV "
                f"(λ = {wavelength_ang:.2f} Å) | ΔStat = {delta_stat:.2f}"
            )

    df = pd.DataFrame(results).sort_values("E_keV").reset_index(drop=True)
    df["Signed_Delta_Stat"] = np.abs(df["Delta_Stat"]) * np.sign(df["Norm"])

    csv_path = artifact_dir / f"blind_search_{fit_tag}_spex.csv"
    df.to_csv(csv_path, index=False)

    # Restore the original baseline state as closely as possible for the notebook.
    _restore_baseline(session, baseline_df)
    try:
        _set_param(session, 1, line_comp, "e", energy_min_keV, thaw=False)
        _set_param(session, 1, line_comp, "fwhm", float(line_width_scale * ((velocity_width_km_s / C_KM_S) * energy_min_keV)), thaw=False)
        _set_param(session, 1, line_comp, "norm", 0.0, thaw=False)
    except Exception:
        pass

    plot_path = artifact_dir / f"blind_search_{fit_tag}_spex.png"
    if make_plot:
        title = f"SPEX blind line search ({fit_tag})"
        _default_line_plot(session, df, title, plot_path, energy_min_keV, energy_max_keV)
    else:
        plot_path.touch(exist_ok=True)

    return BlindLineSearchResult(dataframe=df, csv_path=csv_path, plot_path=plot_path)


