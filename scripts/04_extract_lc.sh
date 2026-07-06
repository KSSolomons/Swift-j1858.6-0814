#!/bin/bash
#
# SCRIPT: 04_extract_lc.sh
#
# DESCRIPTION:
# Extracts the source and background lightcurves for an EPIC-pn TIMING MODE observation,
# runs 'epiclccorr' for the definitive lightcurve, and creates plots.
# Applies barycentric correction ('barycen') IN-PLACE to the pn_clean.evt:EVENTS HDU.
#
# ASSUMES:
# - $PROJECT_ROOT, $OBSID are set.
# - HEASOFT and SAS are initialized.
#
# USAGE:
# 1. Ensure you have run scripts 01, 02, and 03.
# 2. Update the RAWX filters below based on your findings in script 03.
# 3. SET THE 'IS_PILED_UP' FLAG ("yes" or "no") in sas_common.sh.
# 4. If IS_PILED_UP="yes", set the 'SRC_EXCISION_FILTER'.
# 5. Run the script: ./scripts/04_extract_lc.sh
#
################################################################################

source "$(dirname "$0")/sas_common.sh"

# Time binning for the output lightcurves (in seconds)
LC_BIN_SIZE="50"

# Energy limits for the lightcurve extraction (in eV)
# 500 = 0.5 keV, 10000 = 10 keV
# Consider narrowing this (e.g., 1000:10000) if background noise is high
LC_ENERGY_MIN="500"
LC_ENERGY_MAX="10000"

set -e
echo "--- Starting Lightcurve Extraction ---"
if [ "${IS_PILED_UP}" == "yes" ]; then
    echo "*** PILE-UP CORRECTION ENABLED ***"
else
    echo "*** STANDARD EXTRACTION (NO PILE-UP) ***"
fi
echo "Using ObsID: ${OBSID}"
echo "Input file from: ${PN_DIR}"
echo "Lightcurve products to: ${LC_DIR}"

mkdir -p "${LC_DIR}"

BACKUP_EVT_FILE="${PN_DIR}/no_barycorr_pn_clean.fits"
SRC_LC_RAW_FILE="${LC_DIR}/pn_source_lc_raw.fits"
BKG_LC_RAW_FILE="${LC_DIR}/pn_bkg_lc_raw.fits"
CORR_LC_FILE="${LC_DIR}/pn_source_lc_corrected.fits"

# --- Barycentric Correction ---
echo "--- Applying Barycentric Correction (in-place) ---"
START_DIR=$(pwd)
cd "${PN_DIR}" || { echo "Failed to cd to ${PN_DIR}"; exit 1; }

CLEAN_EVT_FILENAME=$(basename "${CLEAN_EVT_FILE}")
BACKUP_EVT_FILENAME=$(basename "${BACKUP_EVT_FILE}")

if [ ! -f "${BACKUP_EVT_FILENAME}" ]; then
    if [ ! -f "${CLEAN_EVT_FILENAME}" ]; then
        echo "ERROR: Original file ${CLEAN_EVT_FILENAME} not found. Cannot create backup."
        cd "${START_DIR}"
        exit 1
    fi
    echo "Backup file not found. Assuming ${CLEAN_EVT_FILENAME} is the original."
    echo "Creating backup: ${BACKUP_EVT_FILENAME}"
    cp "${CLEAN_EVT_FILENAME}" "${BACKUP_EVT_FILENAME}"
    echo "Running barycen (in-place) on ${CLEAN_EVT_FILENAME}:EVENTS..."
    barycen table="${CLEAN_EVT_FILENAME}:EVENTS"
else
    echo "Backup ${BACKUP_EVT_FILENAME} found."
    echo "Restoring ${CLEAN_EVT_FILENAME} from backup to ensure fresh correction."
    cp "${BACKUP_EVT_FILENAME}" "${CLEAN_EVT_FILENAME}"
    echo "Running barycen (in-place) on ${CLEAN_EVT_FILENAME}:EVENTS..."
    barycen table="${CLEAN_EVT_FILENAME}:EVENTS"
fi
echo "Barycen complete. ${CLEAN_EVT_FILENAME} is now barycentered."
cd "${START_DIR}"

# --- Spatial Filters ---
if [ "${IS_PILED_UP}" == "yes" ]; then
    FINAL_SRC_RAWX_FILTER="${SRC_RAWX_FILTER_STD} && ${SRC_EXCISION_FILTER}"
else
    FINAL_SRC_RAWX_FILTER="${SRC_RAWX_FILTER_STD}"
fi

if [ ! -f "${CLEAN_EVT_FILE}" ]; then
    echo "ERROR: Could not find ${CLEAN_EVT_FILE}"
    exit 1
fi

# --- Extract Raw Lightcurves ---
LC_BASE_FILTER_EXPR="(FLAG==0)&&(PATTERN<=4)&&(PI in [${LC_ENERGY_MIN}:${LC_ENERGY_MAX}])"
FINAL_SRC_LC_FILTER_EXPR="${LC_BASE_FILTER_EXPR} && ${FINAL_SRC_RAWX_FILTER}"
FINAL_BKG_LC_FILTER_EXPR="${LC_BASE_FILTER_EXPR} && ${BKG_RAWX_FILTER}"

echo "Extracting RAW source lightcurve: ${SRC_LC_RAW_FILE}"
evselect table="${CLEAN_EVT_FILE}" \
    withrateset=yes rateset="${SRC_LC_RAW_FILE}" \
    maketimecolumn=yes timebinsize="${LC_BIN_SIZE}" \
    makeratecolumn=yes \
    expression="${FINAL_SRC_LC_FILTER_EXPR}"

echo "Extracting RAW background lightcurve: ${BKG_LC_RAW_FILE}"
evselect table="${CLEAN_EVT_FILE}" \
    withrateset=yes rateset="${BKG_LC_RAW_FILE}" \
    maketimecolumn=yes timebinsize="${LC_BIN_SIZE}" \
    makeratecolumn=yes \
    expression="${FINAL_BKG_LC_FILTER_EXPR}"

# --- epiclccorr ---
echo "Running epiclccorr to create corrected lightcurve: ${CORR_LC_FILE}"
epiclccorr srctslist="${SRC_LC_RAW_FILE}" \
    eventlist="${CLEAN_EVT_FILE}" \
    outset="${CORR_LC_FILE}" \
    bkgtslist="${BKG_LC_RAW_FILE}" \
    withbkgset=yes \
    applyabsolutecorrections=yes

# --- Plot Lightcurves ---
echo "--- Plotting final lightcurves ---"
LC_SRC_RAW_PS="pn_source_lc_raw.ps"
LC_SRC_RAW_PNG="pn_source_lc_raw.png"
LC_BKG_RAW_PS="pn_bkg_lc_raw.ps"
LC_BKG_RAW_PNG="pn_bkg_lc_raw.png"
LC_CORR_PS="pn_source_lc_corrected.ps"
LC_CORR_PNG="pn_source_lc_corrected.png"

cd "${LC_DIR}" || { echo "Failed to cd to ${LC_DIR}"; exit 1; }

echo "  Generating ${LC_SRC_RAW_PNG}..."
fplot "pn_source_lc_raw.fits[RATE]" xparm="TIME" yparm="RATE" mode='h' device="${LC_SRC_RAW_PS}/PS" </dev/null
convert -density 300 "${LC_SRC_RAW_PS}[0]" "${LC_SRC_RAW_PNG}" || true

echo "  Generating ${LC_BKG_RAW_PNG}..."
fplot "pn_bkg_lc_raw.fits[RATE]" xparm="TIME" yparm="RATE" mode='h' device="${LC_BKG_RAW_PS}/PS" </dev/null
convert -density 300 "${LC_BKG_RAW_PS}[0]" "${LC_BKG_RAW_PNG}" || true

echo "  Generating ${LC_CORR_PNG}..."
fplot "pn_source_lc_corrected.fits[RATE]" xparm="TIME" yparm="RATE" mode='h' device="${LC_CORR_PS}/PS" </dev/null
convert -density 300 "${LC_CORR_PS}[0]" "${LC_CORR_PNG}" || true

echo "All plots created in: ${LC_DIR}"
cd "${PROJECT_ROOT}" || { echo "Failed to cd back to ${PROJECT_ROOT}"; exit 1; }

echo "--------------------------------------------------"
echo "Lightcurve extraction complete for ObsID ${OBSID}."
echo "Corrected lightcurve:   ${CORR_LC_FILE}"
echo "--------------------------------------------------"
