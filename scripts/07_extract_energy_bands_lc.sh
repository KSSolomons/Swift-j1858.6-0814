#!/bin/bash
# SCRIPT: 07_extract_energy_bands_lc.sh
# DESCRIPTION: Extract energy-resolved pn light curves for the soft (0.5-2.0 keV) and hard (2.0-10.0 keV) bands.

# --- Source shared setup (env checks, SAS, paths, instrument config) ---
source "$(dirname "$0")/sas_common.sh"

# --- USER CONFIGURATION - EDIT THIS SECTION ---

# Time binning for the output light curves (seconds).
LC_BIN_SIZE="100"

# --- END OF CONFIGURATION ---

set -euo pipefail

# Validate SAS tools are available
for cmd in evselect epiclccorr; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: ${cmd} is not available in PATH. Load SAS before running this script."
        exit 1
    fi
done

if [[ ! -f "${CLEAN_EVT_FILE}" ]]; then
    echo "ERROR: Clean event file not found: ${CLEAN_EVT_FILE}"
    exit 1
fi

mkdir -p "${LC_DIR}"

FILTER_FULL="${SRC_RAWX_FILTER_STD}"

extract_band_lc() {
    local band_name=$1
    local pi_min=$2
    local pi_max=$3
    local suffix=$4
    local filter_expr=$5

    echo "=== Extracting ${band_name} band (${pi_min}-${pi_max} eV) [${suffix}] ==="

    local pi_expr="PI in [${pi_min}:${pi_max}]"
    local lc_base_filter="(FLAG==0)&&(PATTERN<=4)&&(${pi_expr})"
    local src_expr="${lc_base_filter} && ${filter_expr}"
    local bkg_expr="${lc_base_filter} && ${BKG_RAWX_FILTER}"

    local src_raw="${LC_DIR}/pn_source_lc_raw_${band_name}_${suffix}.fits"
    local bkg_raw="${LC_DIR}/pn_bkg_lc_raw_${band_name}_${suffix}.fits"
    local src_corr="${LC_DIR}/pn_source_lc_corrected_${band_name}_${suffix}.fits"

    evselect table="${CLEAN_EVT_FILE}" \
        withrateset=yes rateset="${src_raw}" \
        maketimecolumn=yes timebinsize="${LC_BIN_SIZE}" \
        makeratecolumn=yes \
        expression="${src_expr}"

    evselect table="${CLEAN_EVT_FILE}" \
        withrateset=yes rateset="${bkg_raw}" \
        maketimecolumn=yes timebinsize="${LC_BIN_SIZE}" \
        makeratecolumn=yes \
        expression="${bkg_expr}"

    epiclccorr srctslist="${src_raw}" \
        eventlist="${CLEAN_EVT_FILE}" \
        outset="${src_corr}" \
        bkgtslist="${bkg_raw}" \
        withbkgset=yes \
        applyabsolutecorrections=yes
}

band_names=(soft hard)
band_pi_min=(500 2000)
band_pi_max=(2000 10000)
region_suffixes=(full)
region_filters=("${FILTER_FULL}")

for region_index in "${!region_suffixes[@]}"; do
    suffix="${region_suffixes[region_index]}"
    filter_expr="${region_filters[region_index]}"

    for band_index in "${!band_names[@]}"; do
        extract_band_lc \
            "${band_names[band_index]}" \
            "${band_pi_min[band_index]}" \
            "${band_pi_max[band_index]}" \
            "${suffix}" \
            "${filter_expr}"
    done
done

echo "=== Done extracting energy-resolved light curves ==="
