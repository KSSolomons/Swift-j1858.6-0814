#!/bin/bash
# SCRIPT: 07_extract_energy_bands_lc.sh
# DESCRIPTION: Extracts energy-resolved source and background light curves (Soft: 0.5-2.0 keV, Hard: 2.0-10.0 keV).

# --- USER CONFIGURATION - EDIT THIS SECTION ---

# Set to "yes" if epatplot showed pile-up, otherwise "no".
IS_PILED_UP="no"

# The standard (FULL) source region.
SRC_RAWX_FILTER_STD="RAWX in [27:47]"

# The BACKGROUND region (used always)
BKG_RAWX_FILTER="RAWX in [1:3]"

# --- Only needed if IS_PILED_UP="yes" ---
# The PILE-UP EXCISION filter (the columns to REMOVE from SRC_RAWX_FILTER_STD)
SRC_EXCISION_FILTER="!(RAWX in [36:38])"
# --- End Pile-up Specific ---

# Time binning for the output lightcurves (in seconds)
LC_BIN_SIZE="100"

# --- END OF CONFIGURATION ---

if [ -z "${PROJECT_ROOT}" ] || [ -z "${OBSID}" ]; then
    echo "ERROR: PROJECT_ROOT or OBSID is not set."
    exit 1
fi

export SAS_CCFPATH="/home/kyle/CCF"
export SAS_CCF="${PROJECT_ROOT}/data/${OBSID}/ccf.cif"
export SAS_ODF=$(find "${PROJECT_ROOT}/data/${OBSID}" -name "*SUM.SAS" | head -n 1)

if [ -n "${SAS_PATH}" ] && [ -z "${SAS_DIR}" ]; then
    export SAS_DIR="${SAS_PATH}"
fi

PN_DIR="${PROJECT_ROOT}/products/${OBSID}/pn"
CLEAN_EVT_FILE="${PN_DIR}/pn_clean.evt"
LC_DIR="${PN_DIR}/lc"
mkdir -p "${LC_DIR}"

FILTER_FULL="${SRC_RAWX_FILTER_STD}"
FILTER_EXCISED="${SRC_RAWX_FILTER_STD} && ${SRC_EXCISION_FILTER}"

extract_band_lc() {
    local band_name=$1
    local pi_min=$2
    local pi_max=$3
    local suffix=$4
    local filter_expr=$5

    echo "=== Extracting ${band_name} band (${pi_min}-${pi_max} eV) [${suffix}] ==="
    local PI_EXPR="PI in [${pi_min}:${pi_max}]"
    local LC_BASE_FILTER="(FLAG==0)&&(PATTERN<=4)&&(${PI_EXPR})"
    local SRC_EXPR="${LC_BASE_FILTER} && ${filter_expr}"
    local BKG_EXPR="${LC_BASE_FILTER} && ${BKG_RAWX_FILTER}"

    local SRC_RAW="${LC_DIR}/pn_source_lc_raw_${band_name}_${suffix}.fits"
    local BKG_RAW="${LC_DIR}/pn_bkg_lc_raw_${band_name}_${suffix}.fits"
    local SRC_CORR="${LC_DIR}/pn_source_lc_corrected_${band_name}_${suffix}.fits"

    evselect table="${CLEAN_EVT_FILE}" \
        withrateset=yes rateset="${SRC_RAW}" \
        maketimecolumn=yes timebinsize="${LC_BIN_SIZE}" \
        makeratecolumn=yes \
        expression="${SRC_EXPR}"

    evselect table="${CLEAN_EVT_FILE}" \
        withrateset=yes rateset="${BKG_RAW}" \
        maketimecolumn=yes timebinsize="${LC_BIN_SIZE}" \
        makeratecolumn=yes \
        expression="${BKG_EXPR}"

    epiclccorr srctslist="${SRC_RAW}" \
        eventlist="${CLEAN_EVT_FILE}" \
        outset="${SRC_CORR}" \
        bkgtslist="${BKG_RAW}" \
        withbkgset=yes \
        applyabsolutecorrections=yes
}

# Extract FULL regions (No pile-up correction)
extract_band_lc "soft" 500 2000 "full" "${FILTER_FULL}"
extract_band_lc "hard" 2000 10000 "full" "${FILTER_FULL}"

# Extract EXCISED regions (Pile-up corrected)
extract_band_lc "soft" 500 2000 "excised" "${FILTER_EXCISED}"
extract_band_lc "hard" 2000 10000 "excised" "${FILTER_EXCISED}"

echo "=== Done extracting energy-resolved light curves ==="
