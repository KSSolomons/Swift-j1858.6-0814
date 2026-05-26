
def plot_hardness_mode(mode='full'):
    if mode == 'full':
        s_path, h_path = soft_path_full, hard_path_full
        t_path = total_path_full
        title_suffix = "(NO Pile-up Correction)"
    else:
        s_path, h_path = soft_path_excised, hard_path_excised
        t_path = total_path_excised
        title_suffix = "(WITH Pile-up Correction)"

    bkg_s_path = f"{project_root}/products/{obsid}/pn/lc/pn_bkg_lc_raw_soft_{mode}.fits"
    bkg_h_path = f"{project_root}/products/{obsid}/pn/lc/pn_bkg_lc_raw_hard_{mode}.fits"
    bkg_t_path = f"{project_root}/products/{obsid}/pn/lc/pn_bkg_lc_raw_full_band_{mode}.fits"

    # Quick check if excised full band exists, fallback to total_path if not generated yet.
    # The bash script is currently only generating the 'full' mode, so this might fail for 'excised'.
    if not os.path.exists(t_path):
        print(f"Warning: {t_path} not found. Ensure 07_extract_energy_bands_lc.sh extracts this region.")
        return

    with fits.open(s_path) as hdul_s, fits.open(h_path) as hdul_h, fits.open(t_path) as hdul_t, fits.open(bkg_s_path) as hdul_bs, fits.open(bkg_h_path) as hdul_bh, fits.open(bkg_t_path) as hdul_bt:
        t_soft = Table(hdul_s[1].data)
        t_hard = Table(hdul_h[1].data)
        t_tot = Table(hdul_t[1].data)
        t_bkg_s = Table(hdul_bs[1].data)
        t_bkg_h = Table(hdul_bh[1].data)
        t_bkg_t = Table(hdul_bt[1].data)

    time = t_soft['TIME']
    soft_rate = t_soft['RATE']
    hard_rate = t_hard['RATE']
    tot_rate = t_tot['RATE']
    soft_err = t_soft['ERROR']
    hard_err = t_hard['ERROR']

    bkg_s_rate = t_bkg_s['RATE']
    bkg_h_rate = t_bkg_h['RATE']
    bkg_t_rate = t_bkg_t['RATE']

    mask = np.isfinite(soft_rate) & np.isfinite(hard_rate) & (soft_rate > 0) & (hard_rate > 0) & np.isfinite(tot_rate)
    time_clean = time[mask]
    soft_clean = soft_rate[mask]
    hard_clean = hard_rate[mask]
    soft_err_clean = soft_err[mask]
    hard_err_clean = hard_err[mask]
    tot_clean = tot_rate[mask]

    bkg_mask = np.isfinite(bkg_s_rate) & np.isfinite(bkg_h_rate) & np.isfinite(bkg_t_rate)
    bkg_time_clean = time[bkg_mask]
    bkg_s_clean = bkg_s_rate[bkg_mask]
    bkg_h_clean = bkg_h_rate[bkg_mask]
    bkg_t_clean = bkg_t_rate[bkg_mask]

    hardness = hard_clean / soft_clean
    hardness_err = hardness * np.sqrt((hard_err_clean / hard_clean) ** 2 + (soft_err_clean / soft_clean) ** 2)

    time_rel = time_clean - time_clean[0]
    bkg_time_rel = bkg_time_clean - time_clean[0]

    persistent_intervals = [(50000, 65760)]
    dipping_intervals = (3510, 32430)
    eclipse_intervals = (35780, 40000)
    shallow_dip_intervals = [(time_rel[0], 3510), (32430, 35780), (40000, 50000), (65760, time_rel[-1])]

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8), dpi=150, sharex=True, gridspec_kw={'hspace': 0})

    ax1.set_ylabel('Count Rate (c/s)', fontsize=14)
    ax1.plot(time_rel, soft_clean, marker='o', linestyle='-',
             markersize=3, alpha=0.5, label='Soft (0.5-2 keV)', color='tab:blue')
    ax1.plot(time_rel, hard_clean, marker='o', linestyle='-',
             markersize=3, alpha=0.5, label='Hard (2-10 keV)', color='tab:orange')
    ax1.legend(loc='upper right')
    ax1.set_title(f"X-ray Lightcurves and Hardness Ratio {title_suffix}")

    ax2.set_xlabel('Time (s)', fontsize=14)
    ax2.set_ylabel('Hardness (Hard / Soft)', fontsize=14)
    ax2.errorbar(
        time_rel, hardness, yerr=hardness_err,
        marker='o', linestyle='-', markersize=3, alpha=0.7,
        color='tab:green', ecolor='tab:green',
        elinewidth=0.7, capsize=1.5, capthick=0.7
    )
    if mode == 'full':
        ax2.set_ylim(5E-1, 1.2)
    else:
        ax2.set_ylim(5E-2, 1.2)

    for ax in (ax1, ax2):
        for i, (start, end) in enumerate(persistent_intervals):
            ax.axvspan(start, end, color='orange', alpha=0.3, label='Persistent' if (i == 0 and ax == ax1) else None)
        ax.axvspan(dipping_intervals[0], dipping_intervals[1], color='blue', alpha=0.3, label='Dipping' if ax == ax1 else None)
        ax.axvspan(eclipse_intervals[0], eclipse_intervals[1], color='green', alpha=0.3, label='Eclipse' if ax == ax1 else None)
        for i, (start, end) in enumerate(shallow_dip_intervals):
            ax.axvspan(start, end, color='purple', alpha=0.3, label='Shallow Dip' if (i == 0 and ax == ax1) else None)

    handles, labels = ax1.get_legend_handles_labels()
    ax1.legend(handles, labels, loc='lower right', fontsize=10, ncol=2)

    from matplotlib.ticker import MultipleLocator, FuncFormatter
    ax3 = ax1.twiny()
    period_seconds = 21.3 * 3600
    t0 = (eclipse_intervals[0] + eclipse_intervals[1]) / 2

    while t0 > time_rel[0]:
        t0 -= period_seconds

    def time_to_phase(t):
        return (t - t0) / period_seconds

    x_min, x_max = ax1.get_xlim()
    ax3.set_xlim(time_to_phase(x_min), time_to_phase(x_max))

    ax3.set_xlabel("Phase", fontsize=14)
    ax3.xaxis.set_major_locator(MultipleLocator(0.1))
    ax3.xaxis.set_minor_locator(MultipleLocator(0.05))
    ax3.xaxis.set_major_formatter(FuncFormatter(lambda x, pos: f"{x % 1.0:.1f}"))

    plt.tight_layout()
    fig.subplots_adjust(hspace=0)
    plt.savefig(f"{project_root}/products/{obsid}/pn/lc/lightcurves_and_hardness_{mode}.png", dpi=300)
    plt.show()

    # --- Background Figure ---
    fig_bg, ax_bg = plt.subplots(figsize=(12, 4), dpi=150)
    ax_bg.set_xlabel('Time (s)', fontsize=14)
    ax_bg.set_ylabel('Bkg Rate (c/s)', fontsize=14)
    ax_bg.plot(bkg_time_rel, bkg_s_clean, marker='x', linestyle=':',
               markersize=2, alpha=1, label='Soft Bkg', color='blue')
    ax_bg.plot(bkg_time_rel, bkg_h_clean, marker='x', linestyle=':',
               markersize=2, alpha=1, label='Hard Bkg', color='orange')
    ax_bg.legend(loc='upper right')
    ax_bg.set_title(f"Background Lightcurves {title_suffix}")

    ax_bg.set_ylim(-0.01, 0.12)

    ax_bg_phase = ax_bg.twiny()
    ax_bg_phase.set_xlim(ax3.get_xlim())
    ax_bg_phase.set_xlabel("Phase", fontsize=14)
    ax_bg_phase.xaxis.set_major_locator(MultipleLocator(0.1))
    ax_bg_phase.xaxis.set_minor_locator(MultipleLocator(0.05))
    ax_bg_phase.xaxis.set_major_formatter(FuncFormatter(lambda x, pos: f"{x % 1.0:.1f}"))

    plt.tight_layout()
    plt.savefig(f"{project_root}/products/{obsid}/pn/lc/background_lightcurves_{mode}.png", dpi=300)
    plt.show()

    # --- Full Energy Lightcurve Figure ---
    fig_full, (ax_full1, ax_full2) = plt.subplots(2, 1, figsize=(12, 8), dpi=150, sharex=True, gridspec_kw={'hspace': 0})

    ax_full1.set_ylabel('Count Rate (c/s)', fontsize=14)
    ax_full1.plot(time_rel, tot_clean, marker='o', linestyle='-',
                  markersize=3, alpha=0.7, label='Full Energy (0.5-10 keV)', color='tab:gray')
    ax_full1.legend(loc='upper right')
    ax_full1.set_title(f"Full Energy Lightcurve {title_suffix}")

    ax_full2.set_xlabel('Time (s)', fontsize=14)
    ax_full2.set_ylabel('Hardness (Hard / Soft)', fontsize=14)
    ax_full2.errorbar(
        time_rel, hardness, yerr=hardness_err,
        marker='o', linestyle='-', markersize=3, alpha=0.7,
        color='tab:green', ecolor='tab:green',
        elinewidth=0.7, capsize=1.5, capthick=0.7
    )
    if mode == 'full':
        ax_full2.set_ylim(5E-1, 1.2)
    else:
        ax_full2.set_ylim(5E-2, 1.2)

    for ax in (ax_full1, ax_full2):
        for i, (start, end) in enumerate(persistent_intervals):
            ax.axvspan(start, end, color='orange', alpha=0.3, label='Persistent' if (i == 0 and ax == ax_full1) else None)
        ax.axvspan(dipping_intervals[0], dipping_intervals[1], color='blue', alpha=0.3, label='Dipping' if ax == ax_full1 else None)
        ax.axvspan(eclipse_intervals[0], eclipse_intervals[1], color='green', alpha=0.3, label='Eclipse' if ax == ax_full1 else None)
        for i, (start, end) in enumerate(shallow_dip_intervals):
            ax.axvspan(start, end, color='purple', alpha=0.3, label='Shallow Dip' if (i == 0 and ax == ax_full1) else None)

    handles_full, labels_full = ax_full1.get_legend_handles_labels()
    ax_full1.legend(handles_full, labels_full, loc='lower right', fontsize=10, ncol=2)

    ax_full3 = ax_full1.twiny()
    x_min_full, x_max_full = ax_full1.get_xlim()
    ax_full3.set_xlim(time_to_phase(x_min_full), time_to_phase(x_max_full))

    ax_full3.set_xlabel("Phase", fontsize=14)
    ax_full3.xaxis.set_major_locator(MultipleLocator(0.1))
    ax_full3.xaxis.set_minor_locator(MultipleLocator(0.05))
    ax_full3.xaxis.set_major_formatter(FuncFormatter(lambda x, pos: f"{x % 1.0:.1f}"))

    plt.tight_layout()
    fig_full.subplots_adjust(hspace=0)
    plt.savefig(f"{project_root}/products/{obsid}/pn/lc/full_energy_lightcurve_{mode}.png", dpi=300)
    plt.show()

    # --- Full Energy Background Figure ---
    fig_full_bg, ax_full_bg = plt.subplots(figsize=(12, 4), dpi=150)
    ax_full_bg.set_xlabel('Time (s)', fontsize=14)
    ax_full_bg.set_ylabel('Bkg Rate (c/s)', fontsize=14)
    ax_full_bg.plot(bkg_time_rel, bkg_t_clean, marker='x', linestyle=':',
                    markersize=2, alpha=1, label='Full Bkg (0.5-10 keV)', color='tab:gray')
    ax_full_bg.legend(loc='upper right')
    ax_full_bg.set_title(f"Full Energy Background Lightcurve {title_suffix}")

    ax_full_bg.set_ylim(-0.01, 0.12)

    ax_full_bg_phase = ax_full_bg.twiny()
    ax_full_bg_phase.set_xlim(ax3.get_xlim())
    ax_full_bg_phase.set_xlabel("Phase", fontsize=14)
    ax_full_bg_phase.xaxis.set_major_locator(MultipleLocator(0.1))
    ax_full_bg_phase.xaxis.set_minor_locator(MultipleLocator(0.05))
    ax_full_bg_phase.xaxis.set_major_formatter(FuncFormatter(lambda x, pos: f"{x % 1.0:.1f}"))

    plt.tight_layout()
    plt.savefig(f"{project_root}/products/{obsid}/pn/lc/full_energy_background_{mode}.png", dpi=300)
    plt.show()

plot_hardness_mode('full')
# Note: Since the bash script currently only loops over region_suffixes=(full),
# the 'excised' mode will print a warning and return early unless you update the bash script to extract it too.
plot_hardness_mode('excised')
