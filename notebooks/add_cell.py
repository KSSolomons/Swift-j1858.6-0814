import nbformat

notebook_path = '/media/kyle/kyle_phd/Swift-j1858.6-0814/notebooks/(07)energy_bands_and_hid.ipynb'
nb = nbformat.read(notebook_path, as_version=4)

cell_code = """# Compare the excised vs full energy light curves for soft and hard bands
import numpy as np
import matplotlib.pyplot as plt
from astropy.io import fits
from astropy.table import Table

def load_lc_clean(filepath):
    with fits.open(filepath) as hdul:
        t = Table(hdul[1].data)
    time = t['TIME']
    rate = t['RATE']
    mask = np.isfinite(rate) & (rate > 0)
    return time[mask], rate[mask]

# Load soft lightcurves
time_soft_full, rate_soft_full = load_lc_clean(soft_path_full)
time_soft_excised, rate_soft_excised = load_lc_clean(soft_path_excised)

# Load hard lightcurves
time_hard_full, rate_hard_full = load_lc_clean(hard_path_full)
time_hard_excised, rate_hard_excised = load_lc_clean(hard_path_excised)

# Align time to start at 0 (using soft_full as reference)
t0 = time_soft_full[0]

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 10), dpi=150, sharex=True)

# --- Soft Band Comparison ---
color1 = 'tab:blue'
ax1.set_ylabel('Soft Full Rate (c/s)', color=color1, fontsize=14)
ax1.plot(time_soft_full - t0, rate_soft_full, marker='o', linestyle='-', markersize=2, alpha=0.5, color=color1, label='Soft Full')
ax1.tick_params(axis='y', labelcolor=color1)

ax1_twin = ax1.twinx()
color2 = 'tab:cyan'
ax1_twin.set_ylabel('Soft Excised Rate (c/s)', color=color2, fontsize=14)
ax1_twin.plot(time_soft_excised - t0, rate_soft_excised, marker='x', linestyle='-', markersize=2, alpha=0.5, color=color2, label='Soft Excised')
ax1_twin.tick_params(axis='y', labelcolor=color2)

ax1.set_title('Soft Band (0.5-2.0 keV): Full vs Excised Light Curve Shapes', fontsize=14)

# --- Hard Band Comparison ---
color3 = 'tab:orange'
ax2.set_xlabel('Time (s)', fontsize=14)
ax2.set_ylabel('Hard Full Rate (c/s)', color=color3, fontsize=14)
ax2.plot(time_hard_full - t0, rate_hard_full, marker='o', linestyle='-', markersize=2, alpha=0.5, color=color3, label='Hard Full')
ax2.tick_params(axis='y', labelcolor=color3)

ax2_twin = ax2.twinx()
color4 = 'tab:red'
ax2_twin.set_ylabel('Hard Excised Rate (c/s)', color=color4, fontsize=14)
ax2_twin.plot(time_hard_excised - t0, rate_hard_excised, marker='x', linestyle='-', markersize=2, alpha=0.5, color=color4, label='Hard Excised')
ax2_twin.tick_params(axis='y', labelcolor=color4)

ax2.set_title('Hard Band (2.0-10.0 keV): Full vs Excised Light Curve Shapes', fontsize=14)

# Add legends
lines1, labels1 = ax1.get_legend_handles_labels()
lines1_twin, labels1_twin = ax1_twin.get_legend_handles_labels()
ax1.legend(lines1 + lines1_twin, labels1 + labels1_twin, loc='upper right')

lines2, labels2 = ax2.get_legend_handles_labels()
lines2_twin, labels2_twin = ax2_twin.get_legend_handles_labels()
ax2.legend(lines2 + lines2_twin, labels2 + labels2_twin, loc='upper right')

plt.tight_layout()
plt.show()
"""

new_cell = nbformat.v4.new_code_cell(cell_code)
# insert before the plt.close("all") cell if it exists
nb.cells.insert(-1, new_cell)

nbformat.write(nb, notebook_path)
print("Cell appended successfully.")
