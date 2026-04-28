#!/bin/bash
#
# SCRIPT: 04_extract_spectrum.sh
#
# DESCRIPTION:
# Extracts the final source spectrum, background spectrum, RMF, ARF,
# AND a fully corrected source lightcurve for an EPIC-pn TIMING MODE observation.
# Handles BOTH standard extraction AND piled-up cases.
# Runs 'epiclccorr' for the definitive lightcurve.
# ** Also creates plots for raw and corrected lightcurves. **
#
# ** Applies barycentric correction ('barycen') IN-PLACE
# ** to the pn_clean.evt:EVENTS HDU. Creates a persistent backup
# ** 'no_barycorr_pn_clean.fits' on the first run, and restores from
# ** this backup on subsequent runs to prevent re-correcting.
#
# ASSUMES:
# - $PROJECT_ROOT, $OBSID are set.
# - HEASOFT and SAS are initialized.
#
# USAGE:
# 1. Ensure you have run scripts 01, 02, and 03.
# 2. Update the RAWX filters below based on your findings in script 03.
# 3. SET THE 'IS_PILED_UP' FLAG ("yes" or "no").
# 4. If IS_PILED_UP="yes", set the 'SRC_EXCISION_FILTER'.
# 5. Run the script: ./scripts/04_extract_spectrum.sh
#
################################################################################

# --- Source shared setup (env checks, SAS, paths, instrument config) ---
source "$(dirname "$0")/sas_common.sh"

# --- SCRIPT-SPECIFIC CONFIGURATION ---

# The grouping specification for the final spectrum
GROUPING_SPEC="20"

# Time binning for the output lightcurves (in seconds)
LC_BIN_SIZE="100"

# --- END OF CONFIGURATION ---

set -e
echo "--- Starting Spectral and Lightcurve Extraction ---"
if [ "${IS_PILED_UP}" == "yes" ]; then
    echo "*** PILE-UP CORRECTION ENABLED ***"
else
    echo "*** STANDARD EXTRACTION (NO PILE-UP) ***"
fi
echo "Using ObsID: ${OBSID}"
echo "Input file from: ${PN_DIR}"
echo "Spectral products to: ${SPEC_DIR}"
echo "Lightcurve products to: ${LC_DIR}"

# --- 1. Create output directories ---
mkdir -p "${SPEC_DIR}"
mkdir -p "${LC_DIR}"

# --- 2. Define filenames ---
BACKUP_EVT_FILE="${PN_DIR}/no_barycorr_pn_clean.fits"

SRC_SPEC="${SPEC_DIR}/pn_source_spectrum.fits"
RMF_FILE="${SPEC_DIR}/pn_rmf.rmf"
ARF_FILE="${SPEC_DIR}/pn_arf.arf"
GRP_SPEC_FILE="${SPEC_DIR}/pn_source_spectrum_grp.fits"
BKG_SPEC="${SPEC_DIR}/pn_bkg_spectrum.fits"
SRC_LC_RAW_FILE="${LC_DIR}/pn_source_lc_raw.fits"
BKG_LC_RAW_FILE="${LC_DIR}/pn_bkg_lc_raw.fits"
CORR_LC_FILE="${LC_DIR}/pn_source_lc_corrected.fits"

# --- 2b. Apply Barycentric Correction ---
echo "--- 2b. Applying Barycentric Correction (in-place) ---"

echo "Changing to ${PN_DIR} to run barycen..."
START_DIR=$(pwd)
cd "${PN_DIR}" || { echo "Failed to cd to ${PN_DIR}"; exit 1; }

CLEAN_EVT_FILENAME=$(basename "${CLEAN_EVT_FILE}")
BACKUP_EVT_FILENAME=$(basename "${BACKUP_EVT_FILE}")
echo $CLEAN_EVT_FILENAME
# Check if the backup file (the *original*) already exists.
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

echo "Returning to ${START_DIR}..."
cd "${START_DIR}"
# --- End of Barycen Section ---

# --- 3. Determine Final Spatial Filter Based on Pile-up Flag ---
if [ "${IS_PILED_UP}" == "yes" ]; then
    FINAL_SRC_RAWX_FILTER="${SRC_RAWX_FILTER_STD} && ${SRC_EXCISION_FILTER}"
    echo "Using PILED-UP spatial filter: ${FINAL_SRC_RAWX_FILTER}"
else
    FINAL_SRC_RAWX_FILTER="${SRC_RAWX_FILTER_STD}"
    echo "Using STANDARD spatial filter: ${FINAL_SRC_RAWX_FILTER}"
fi

if [ ! -f "${CLEAN_EVT_FILE}" ]; then
    echo "ERROR: Could not find ${CLEAN_EVT_FILE}"
    exit 1
fi

# --- 3b. Extract Raw Lightcurves ---
LC_BASE_FILTER_EXPR="(FLAG==0)&&(PATTERN<=4)&&(PI in [500:10000])"
FINAL_SRC_LC_FILTER_EXPR="${LC_BASE_FILTER_EXPR} && ${SRC_RAWX_FILTER_STD}"
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

# --- 3c. Run epiclccorr ---
echo "Running epiclccorr to create corrected lightcurve: ${CORR_LC_FILE}"
epiclccorr srctslist="${SRC_LC_RAW_FILE}" \
    eventlist="${CLEAN_EVT_FILE}" \
    outset="${CORR_LC_FILE}" \
    bkgtslist="${BKG_LC_RAW_FILE}" \
    withbkgset=yes \
    applyabsolutecorrections=yes

# --- 4. Extract Source Spectrum ---
SPECTRAL_BASE_FILTER_EXPR="(FLAG==0)&&(PI in [200:15000])&&(PATTERN<=4)"
FINAL_SRC_SPEC_FILTER_EXPR="${SPECTRAL_BASE_FILTER_EXPR} && ${FINAL_SRC_RAWX_FILTER}"

echo "Extracting source spectrum: ${SRC_SPEC}"
extract_spectrum "${SRC_SPEC}" "${FINAL_SRC_SPEC_FILTER_EXPR}"

# --- 5. Extract Background Spectrum ---
echo "Extracting background spectrum: ${BKG_SPEC}"
BKG_FILTER_EXPR="${SPECTRAL_BASE_FILTER_EXPR} && ${BKG_RAWX_FILTER}"
extract_spectrum "${BKG_SPEC}" "${BKG_FILTER_EXPR}"

# --- 6. Calculate BACKSCAL Keywords ---
echo "Calculating BACKSCAL for source spectrum..."
backscale spectrumset="${SRC_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"
echo "Calculating BACKSCAL for background spectrum..."
backscale spectrumset="${BKG_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"

# --- 7. Generate RMF ---
echo "Generating RMF: ${RMF_FILE}"
rmfgen spectrumset="${SRC_SPEC}" rmfset="${RMF_FILE}"

# --- 8. Generate ARF (Conditional Method) ---
generate_arf "${SRC_SPEC}" "${ARF_FILE}" "${RMF_FILE}" "${SPECTRAL_BASE_FILTER_EXPR}"

# --- 9. Group the Source Spectrum ---
echo "Grouping the final spectrum: ${GRP_SPEC_FILE}"
specgroup spectrumset="${SRC_SPEC}" \
    groupedset="${GRP_SPEC_FILE}" \
    backgndset="${BKG_SPEC}" \
    rmfset="${RMF_FILE}" \
    arfset="${ARF_FILE}" \
    mincounts="${GROUPING_SPEC}"

# --- 9b. Plot Lightcurves (EXPANDED SECTION) ---
echo "--- Plotting final lightcurves ---"

LC_SRC_RAW_PS="pn_source_lc_raw.ps"
LC_SRC_RAW_PNG="pn_source_lc_raw.png"
LC_BKG_RAW_PS="pn_bkg_lc_raw.ps"
LC_BKG_RAW_PNG="pn_bkg_lc_raw.png"
LC_CORR_PS="pn_source_lc_corrected.ps"
LC_CORR_PNG="pn_source_lc_corrected.png"

echo "Changing to ${LC_DIR} to create plots..."
cd "${LC_DIR}" || { echo "Failed to cd to ${LC_DIR}"; exit 1; }

# Plot 1: Raw Source LC
echo "  Generating ${LC_SRC_RAW_PNG}..."
fplot "pn_source_lc_raw.fits[RATE]" xparm="TIME" yparm="RATE" mode='h' device="${LC_SRC_RAW_PS}/PS" </dev/null
convert -density 300 "${LC_SRC_RAW_PS}[0]" "${LC_SRC_RAW_PNG}"


# Plot 2: Raw Background LC
echo "  Generating ${LC_BKG_RAW_PNG}..."
fplot "pn_bkg_lc_raw.fits[RATE]" xparm="TIME" yparm="RATE" mode='h' device="${LC_BKG_RAW_PS}/PS" </dev/null
convert -density 300 "${LC_BKG_RAW_PS}[0]" "${LC_BKG_RAW_PNG}"


# Plot 3: Corrected Source LC
echo "  Generating ${LC_CORR_PNG}..."
fplot "pn_source_lc_corrected.fits[RATE]" xparm="TIME" yparm="RATE" mode='h' device="${LC_CORR_PS}/PS" </dev/null
convert -density 300 "${LC_CORR_PS}[0]" "${LC_CORR_PNG}"


echo "All plots created in: ${LC_DIR}"
echo "Returning to project root directory..."
cd "${PROJECT_ROOT}" || { echo "Failed to cd back to ${PROJECT_ROOT}"; exit 1; }
# --- End Plotting Section ---

# --- 10. Completion ---
echo "--------------------------------------------------"
echo "Spectral and Lightcurve extraction complete for ObsID ${OBSID}."
echo ""
echo "Final grouped spectrum: ${GRP_SPEC_FILE}"
echo "Background spectrum:    ${BKG_SPEC}"
echo "Response matrix (RMF):  ${RMF_FILE}"
echo "Ancillary file (ARF):   ${ARF_FILE}"
echo "Corrected lightcurve:   ${CORR_LC_FILE}"
echo "Original non-barycorr:  ${BACKUP_EVT_FILE}"
echo ""
echo "Plots created in: ${LC_DIR}"
echo "  - ${LC_SRC_RAW_PNG}"
echo "  - ${LC_BKG_RAW_PNG}"
echo "  - ${LC_CORR_PNG}"
echo ""
echo "These files are ready for analysis in XSPEC or SPEX (after conversion)."
echo "--------------------------------------------------"
