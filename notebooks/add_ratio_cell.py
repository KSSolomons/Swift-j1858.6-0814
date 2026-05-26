import nbformat

notebook_path = '/media/kyle/kyle_phd/Swift-j1858.6-0814/notebooks/(07)energy_bands_and_hid.ipynb'
nb = nbformat.read(notebook_path, as_version=4)

cell_code = """# Calculate and plot the ratio of excised to full light curves
import numpy as np
import matplotlib.pyplot as plt
from astropy.io import fits
from astropy.table import Table

def load_lc_raw(filepath):
    with fits.open(filepath) as hdul:
        t = Table(hdul[1].data)
    return t['TIME'], t['RATE'], t['ERROR']

# --- Soft Band Ratio ---
time_sf, rate_sf, err_sf = load_lc_raw(soft_path_full)
time_se, rate_se, err_se = load_lc_raw(soft_path_excised)

# Use a common mask where both are valid and > 0
mask_s = np.isfinite(rate_sf) & (rate_sf > 0) & np.isfinite(rate_se) & (rate_se > 0)
time_s = time_sf[mask_s]
ratio_s = rate_se[mask_s] / rate_sf[mask_s]
ratio_err_s = ratio_s * np.sqrt((err_se[mask_s] / rate_se[mask_s])**2 + (err_sf[mask_s] / rate_sf[mask_s])**2)

# --- Hard Band Ratio ---
time_hf, rate_hf, err_hf = load_lc_raw(hard_path_full)
time_he, rate_he, err_he = load_lc_raw(hard_path_excised)

# Use a common mask where both are valid and > 0
mask_h = np.isfinite(rate_hf) & (rate_hf > 0) & np.isfinite(rate_he) & (rate_he > 0)
time_h = time_hf[mask_h]
ratio_h = rate_he[mask_h] / rate_hf[mask_h]
ratio_err_h = ratio_h * np.sqrt((err_he[mask_h] / rate_he[mask_h])**2 + (err_hf[mask_h] / rate_hf[mask_h])**2)

t0 = time_sf[0]

# --- Plotting ---
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8), dpi=150, sharex=True)

ax1.set_ylabel('Ratio (Excised / Full)', fontsize=14)
ax1.errorbar(time_s - t0, ratio_s, yerr=ratio_err_s, fmt='o', markersize=3, alpha=0.5, color='tab:blue', label='Soft Band Ratio (0.5-2 keV)')
ax1.axhline(1.0, color='black', linestyle='--', alpha=0.5)
ax1.legend(loc='upper right')
ax1.set_title('Ratio of Excised to Full Count Rates', fontsize=14)

ax2.set_xlabel('Time (s)', fontsize=14)
ax2.set_ylabel('Ratio (Excised / Full)', fontsize=14)
ax2.errorbar(time_h - t0, ratio_h, yerr=ratio_err_h, fmt='o', markersize=3, alpha=0.5, color='tab:orange', label='Hard Band Ratio (2-10 keV)')
ax2.axhline(1.0, color='black', linestyle='--', alpha=0.5)
ax2.legend(loc='upper right')

# Set y-limits to focus on the main distribution, avoiding extreme outliers
# The excised region is smaller, so ratio is typically < 1
ax1.set_ylim(0, 1.2)
ax2.set_ylim(0, 1.2)

plt.tight_layout()
plt.show()
"""

new_cell = nbformat.v4.new_code_cell(cell_code)
# insert before the plt.close("all") cell if it exists
nb.cells.insert(-1, new_cell)

nbformat.write(nb, notebook_path)
print("Ratio cell appended successfully.")
