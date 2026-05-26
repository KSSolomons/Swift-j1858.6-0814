import re
from pathlib import Path
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
import os

def parse_blind_search_log(log_path: Path, csv_path: Path, plot_path: Path | None, grid: list[tuple[float, float]]):
    """
    Parse a SPEX log to extract blind search results.
    Matches the last N+1 C-stat values and last N gaus norm values.
    """
    text = log_path.read_text(encoding="utf-8", errors="replace")
    n_points = len(grid)
    # 1. Extract all C-stat values
    cstat_matches = re.findall(r"Fit statistic used:\s+([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)", text)
    # 2. Extract all DOF values
    dof_matches = re.findall(r"Degrees of freedom:\s+([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)", text)

    # 3. Extract additional fit statistics for summary
    fit_method = re.search(r"Fit method\s*:\s*(.*)", text)
    fit_statistic = re.search(r"Fit statistic\s*:\s*(.*)", text)
    cstatistic = re.search(r"C-statistic\s*:\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)", text)
    expected_cstat = re.search(r"Expected C-stat\s*:\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)(?:\s*\+/-\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?))?", text)
    chi2_value = re.search(r"Chi-squared value\s*:\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)", text)
    wstatistic = re.search(r"W-statistic\s*:\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)", text)

    # Collect fit statistics in a dictionary for return
    fit_stats = {}
    if fit_method:
        fit_stats["Fit method"] = fit_method.group(1)
    if fit_statistic:
        fit_stats["Fit statistic"] = fit_statistic.group(1)
    if cstat_matches:
        fit_stats["Fit statistic used"] = float(cstat_matches[-(n_points + 1)] if len(cstat_matches) >= n_points + 1 else cstat_matches[-1])
    if cstatistic:
        fit_stats["C-statistic"] = float(cstatistic.group(1))
    if expected_cstat:
        if expected_cstat.group(2):
            fit_stats["Expected C-stat"] = f"{expected_cstat.group(1)} +/- {expected_cstat.group(2)}"
        else:
            fit_stats["Expected C-stat"] = expected_cstat.group(1)
    if chi2_value:
        fit_stats["Chi-squared value"] = float(chi2_value.group(1))
    if dof_matches:
        fit_stats["Degrees of freedom"] = float(dof_matches[-(n_points + 1)] if len(dof_matches) >= n_points + 1 else dof_matches[-1])
    if wstatistic:
        fit_stats["W-statistic"] = float(wstatistic.group(1))

    # --- Print additional diagnostics from log ---
    diagnostic_keywords = ["warning", "error", "converged", "not converged", "fail", "parameter", "statistic", "chi-squared", "expected c-stat", "w-statistic"]
    print("\n--- Additional Diagnostics ---")
    for line in text.splitlines():
        if any(kw in line.lower() for kw in diagnostic_keywords):
            print(line)
    print("--- End Diagnostics ---\n")

    # Print last 20 lines of log for context
    print("--- Last 20 lines of log ---")
    for l in text.splitlines()[-20:]:
        print(l)
    print("--- End of log tail ---\n")

    # 3. Extract all gaus norm values
    norm_matches = []
    for line in text.splitlines():
        if "gaus" in line and "norm" in line and ("thawn" in line or "frozen" in line):
            m = re.search(r"gaus\s+norm.*?([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)\s+(?:thawn|frozen)", line)
            if m:
                norm_matches.append(float(m.group(1)))

    if len(cstat_matches) < n_points + 1:
        print(f"Warning: Found {len(cstat_matches)} C-stat values, expected at least {n_points + 1}. Blind search may have failed.")
        return

    baseline_cstat = float(cstat_matches[-(n_points + 1)])
    baseline_dof = float(dof_matches[-(n_points + 1)]) if len(dof_matches) >= n_points + 1 else np.nan

    grid_cstats = [float(x) for x in cstat_matches[-n_points:]]
    grid_dofs = [float(x) for x in dof_matches[-n_points:]] if len(dof_matches) >= n_points else [np.nan]*n_points

    if len(norm_matches) < n_points:
        print(f"Warning: Found only {len(norm_matches)} gaus norm values, expected {n_points}. Padding with NaNs.")
        grid_norms = norm_matches + [np.nan] * (n_points - len(norm_matches))
    else:
        grid_norms = norm_matches[-n_points:]

    results = []
    C_KM_S = 299792.458
    line_width_scale = 2.3548200450309493
    velocity_width_km_s = 100.0

    for i, (e_kev, lam_ang) in enumerate(grid):
        cstat = grid_cstats[i]
        dof = grid_dofs[i]
        norm = grid_norms[i]
        delta_stat = baseline_cstat - cstat
        delta_dof = baseline_dof - dof
        fwhm_kev = line_width_scale * (velocity_width_km_s / C_KM_S) * e_kev
        results.append({
            "Wavelength_Ang": lam_ang,
            "E_keV": e_kev,
            "FWHM_keV": fwhm_kev,
            "Norm": norm,
            "Norm_err_lo": np.nan,
            "Norm_err_hi": np.nan,
            "Stat": cstat,
            "DoF": dof,
            "Delta_Stat": delta_stat,
            "Delta_DoF": delta_dof,
            "Signed_Delta_Stat": abs(delta_stat) * np.sign(norm) if not np.isnan(norm) else np.nan,
            "Expected_Cstat": baseline_cstat
        })

    df = pd.DataFrame(results)
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(csv_path, index=False)
    print(f"Wrote blind search CSV: {csv_path}")

    # --- SIGNIFICANCE REPORTING ---
    # Find points where Delta_Stat >= 9.0 (approx 3 sigma for 1 DoF)
    sig_threshold = 9.0
    significant_points = df[df["Delta_Stat"] >= sig_threshold].copy()
    print("\n--- Fit Statistics Summary ---")
    for k, v in fit_stats.items():
        print(f"{k:<20}: {v}")
    print("------------------------------\n")
    if not significant_points.empty:
        # Group adjacent significant points to find the local peaks
        significant_points['Group'] = (significant_points.index.to_series().diff() > 1).cumsum()
        peaks = significant_points.loc[significant_points.groupby('Group')['Delta_Stat'].idxmax()]
        print("\n" + "="*60)
        print(f" SIGNIFICANT LINES DETECTED (Delta C-stat >= {sig_threshold})")
        print("="*60)
        print(f"{'Energy (keV)':<15} {'Wavelength (A)':<18} {'Delta C-stat':<15} {'Type'}")
        print("-" * 60)
        for _, row in peaks.iterrows():
            line_type = "Emission" if row["Norm"] > 0 else "Absorption"
            print(f"{row['E_keV']:<15.4f} {row['Wavelength_Ang']:<18.3f} {row['Delta_Stat']:<15.2f} {line_type}")
        print("="*60 + "\n")
    else:
        print(f"\nNo significant lines detected above Delta C-stat = {sig_threshold}.\n")

    # --- PLOTTING ---
    if plot_path:
        plt.figure(figsize=(10, 6))
        plt.plot(df["E_keV"], df["Signed_Delta_Stat"], 'k-', drawstyle='steps-mid', label="Scan Data")
        # Add baseline and significance thresholds
        plt.axhline(0, color='black', linestyle='--')
        plt.axhline(sig_threshold, color='blue', linestyle=':', label=r"$\approx 3\sigma$ ($\Delta C = 9$)")
        plt.axhline(-sig_threshold, color='blue', linestyle=':')
        plt.xlabel("Energy (keV)")
        plt.ylabel(r"Signed $\Delta$ C-stat ($|\Delta C| \times$ sign(norm))")
        plt.title("SPEX Blind Line Search")
        plt.legend(loc="best")
        plt.tight_layout()
        plt.savefig(plot_path)
        plt.close()
        print(f"Wrote blind search plot: {plot_path}")

    # --- PURGE UNNECESSARY FOLDERS ---
    # Remove csv_path.parent if it is empty and not the current directory
    try:
        if csv_path.parent.exists() and csv_path.parent.is_dir() and csv_path.parent != Path('.'):
            if not any(csv_path.parent.iterdir()):
                os.rmdir(csv_path.parent)
    except Exception as e:
        print(f"Warning: Could not remove directory {csv_path.parent}: {e}")

    return fit_stats

