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

# --- USER CONFIGURATION - EDIT THIS SECTION ---

# Set to "yes" if epatplot showed pile-up, otherwise "no".
IS_PILED_UP="yes"

# The standard (FULL) source region.
SRC_RAWX_FILTER_STD="RAWX in [27:47]"

# The BACKGROUND region (used always)
BKG_RAWX_FILTER="RAWX in [3:5]"

# --- Only needed if IS_PILED_UP="yes" ---
# The PILE-UP EXCISION filter (the columns to REMOVE from SRC_RAWX_FILTER_STD)
SRC_EXCISION_FILTER="!(RAWX in [36:38])"
# --- End Pile-up Specific ---

# The grouping specification for the final spectrum
GROUPING_SPEC="25"

# Time binning for the output lightcurves (in seconds)
LC_BIN_SIZE="100"

# --- END OF CONFIGURATION ---

# --- 1. CHECK FOR ENVIRONMENT VARIABLES & SET PATHS ---
if [ -z "${PROJECT_ROOT}" ]; then
    echo "ERROR: Environment variable PROJECT_ROOT is not set."
    exit 1
fi
if [ -z "${OBSID}" ]; then
    echo "ERROR: Environment variable OBSID is not set."
    exit 1
fi
export OBS_DIR_ODF="${PROJECT_ROOT}/data/${OBSID}"
if [ ! -d "${OBS_DIR_ODF}" ]; then
    echo "ERROR: ODF directory not found: ${OBS_DIR_ODF}"
    exit 1
fi
echo "Using ODF from: ${OBS_DIR_ODF}"

# --- Re-establish SAS Setup Variables ---
ODF_DIR_CLEAN=$(echo "${OBS_DIR_ODF}" | sed 's:/*$::')
CCF_FILE="${ODF_DIR_CLEAN}/ccf.cif"
SUMMARY_FILE_NAME=$(find "${ODF_DIR_CLEAN}" -maxdepth 1 -name "*SUM.SAS" -printf "%f\n" | head -n 1)
if [ -z "${SUMMARY_FILE_NAME}" ]; then
    echo "ERROR: Cannot find *SUM.SAS file in ${ODF_DIR_CLEAN}"
    exit 1
fi
SUMMARY_FILE="${ODF_DIR_CLEAN}/${SUMMARY_FILE_NAME}"
if [ ! -f "${CCF_FILE}" ]; then echo "ERROR: Cannot find CCF file: ${CCF_FILE}"; exit 1; fi
if [ ! -f "${SUMMARY_FILE}" ]; then echo "ERROR: Cannot find Summary file: ${SUMMARY_FILE}"; exit 1; fi

export SAS_CCF="${CCF_FILE}"
export SAS_ODF="${SUMMARY_FILE}"
echo "SAS_CCF re-established: $(basename "${SAS_CCF}")"
echo "SAS_ODF re-established: $(basename "${SAS_ODF}")"
# --- End Re-establish ---

set -e
echo "--- Starting Spectral and Lightcurve Extraction ---"
if [ "${IS_PILED_UP}" == "yes" ]; then
    echo "*** PILE-UP CORRECTION ENABLED ***"
else
    echo "*** STANDARD EXTRACTION (NO PILE-UP) ***"
fi
export PROC_DIR="${PROJECT_ROOT}"
echo "Using ObsID: ${OBSID}"

# --- Define Directories ---
export PN_DIR="${PROJECT_ROOT}/products/${OBSID}/pn"
export SPEC_DIR="${PROJECT_ROOT}/products/${OBSID}/pn/spec"
export LC_DIR="${PROJECT_ROOT}/products/${OBSID}/pn/lc"
echo "Input file from: ${PN_DIR}"
echo "Spectral products to: ${SPEC_DIR}"
echo "Lightcurve products to: ${LC_DIR}"

# --- 1. Create output directories ---
mkdir -p "${SPEC_DIR}"
mkdir -p "${LC_DIR}"

# --- 2. Define filenames ---
CLEAN_EVT_FILE="${PN_DIR}/pn_clean.evt"
SRC_SPEC="${SPEC_DIR}/pn_source_spectrum.fits"
RMF_FILE="${SPEC_DIR}/pn_rmf.rmf"
ARF_FILE="${SPEC_DIR}/pn_arf.arf"
GRP_SPEC_FILE="${SPEC_DIR}/pn_source_spectrum_grp.fits"
BKG_SPEC="${SPEC_DIR}/pn_bkg_spectrum.fits"
SRC_LC_RAW_FILE="${LC_DIR}/pn_source_lc_raw.fits"
BKG_LC_RAW_FILE="${LC_DIR}/pn_bkg_lc_raw.fits"
CORR_LC_FILE="${LC_DIR}/pn_source_lc_corrected.fits"
# (Temp files...)
SRC_SPEC_FULL_TEMP="${PN_DIR}/pn_source_spectrum_full_temp.fits"
SRC_SPEC_INNER_TEMP="${PN_DIR}/pn_source_spectrum_inner_temp.fits"
ARF_FILE_FULL_TEMP="${PN_DIR}/pn_arf_full_temp.arf"
ARF_FILE_INNER_TEMP="${PN_DIR}/pn_arf_inner_temp.arf"

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
# Use the user-requested energy range for LCs
# *** RESTORED PI FILTER AS REQUESTED ***
LC_BASE_FILTER_EXPR="(FLAG==0)&&(PATTERN<=4)&&(PI in [500:10000])"
# *** RESTORED piled-up filter for source LC ***
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
# *** REMOVED 'timing=yes' as requested ***
echo "Running epiclccorr to create corrected lightcurve: ${CORR_LC_FILE}"
epiclccorr srctslist="${SRC_LC_RAW_FILE}" \
    eventlist="${CLEAN_EVT_FILE}" \
    outset="${CORR_LC_FILE}" \
    bkgtslist="${BKG_LC_RAW_FILE}" \
    withbkgset=yes \
    applyabsolutecorrections=yes

# --- 4. Extract Source Spectrum ---
# Use the standard spectral energy range
# *** RESTORED PI range as requested ***
SPECTRAL_BASE_FILTER_EXPR="(FLAG==0)&&(PI in [200:15000])&&(PATTERN<=4)"
FINAL_SRC_SPEC_FILTER_EXPR="${SPECTRAL_BASE_FILTER_EXPR} && ${FINAL_SRC_RAWX_FILTER}"

echo "Extracting source spectrum: ${SRC_SPEC}"
evselect table="${CLEAN_EVT_FILE}" \
    withspectrumset=yes spectrumset="${SRC_SPEC}" \
    energycolumn=PI spectralbinsize=5 \
    withspecranges=yes specchannelmin=0 specchannelmax=20479 \
    expression="${FINAL_SRC_SPEC_FILTER_EXPR}" \
    writedss=yes

# --- 5. Extract Background Spectrum ---
echo "Extracting background spectrum: ${BKG_SPEC}"
BKG_FILTER_EXPR="${SPECTRAL_BASE_FILTER_EXPR} && ${BKG_RAWX_FILTER}"
evselect table="${CLEAN_EVT_FILE}" \
    withspectrumset=yes spectrumset="${BKG_SPEC}" \
    energycolumn=PI spectralbinsize=5 \
    withspecranges=yes specchannelmin=0 specchannelmax=20479 \
    expression="${BKG_FILTER_EXPR}" \
    writedss=yes

# --- 6. Calculate BACKSCAL Keywords ---
echo "Calculating BACKSCAL for source spectrum..."
backscale spectrumset="${SRC_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"
echo "Calculating BACKSCAL for background spectrum..."
backscale spectrumset="${BKG_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"

# --- 7. Generate RMF ---
echo "Generating RMF: ${RMF_FILE}"
rmfgen spectrumset="${SRC_SPEC}" rmfset="${RMF_FILE}"

# --- 8. Generate ARF (Conditional Method) ---
if [ "${IS_PILED_UP}" == "yes" ]; then
    echo "--- Generating ARF via subtraction method (for pile-up) ---"
    INNER_CORE_RAWX=$(echo "${SRC_EXCISION_FILTER}" | sed -e 's/!//' -e 's/(//' -e 's/)//')
    INNER_CORE_FILTER_EXPR="${SPECTRAL_BASE_FILTER_EXPR} && ${INNER_CORE_RAWX}"
    FULL_SRC_FILTER_EXPR_TEMP="${SPECTRAL_BASE_FILTER_EXPR} && ${SRC_RAWX_FILTER_STD}"

    echo "  Extracting FULL source spectrum (temp)..."
    evselect table="${CLEAN_EVT_FILE}" \
        withspectrumset=yes spectrumset="${SRC_SPEC_FULL_TEMP}" \
        expression="${FULL_SRC_FILTER_EXPR_TEMP}" \
        energycolumn=PI spectralbinsize=5 \
        withspecranges=yes specchannelmin=0 specchannelmax=20479 \
        writedss=yes

    echo "  Extracting INNER CORE spectrum (temp)..."
    evselect table="${CLEAN_EVT_FILE}" \
        withspectrumset=yes spectrumset="${SRC_SPEC_INNER_TEMP}" \
        expression="${INNER_CORE_FILTER_EXPR}" \
        energycolumn=PI spectralbinsize=5 \
        withspecranges=yes specchannelmin=0 specchannelmax=20479 \
        writedss=yes

    echo "  Generating ARF for FULL spectrum (temp)..."
    arfgen spectrumset="${SRC_SPEC_FULL_TEMP}" arfset="${ARF_FILE_FULL_TEMP}" \
        withrmfset=yes rmfset="${RMF_FILE}" \
        badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf

    echo "  Generating ARF for INNER CORE spectrum (temp)..."
    arfgen spectrumset="${SRC_SPEC_INNER_TEMP}" arfset="${ARF_FILE_INNER_TEMP}" \
        withrmfset=yes rmfset="${RMF_FILE}" \
        badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf

    echo "  Subtracting ARFs to create final ARF: ${ARF_FILE}"
    addarf "${ARF_FILE_FULL_TEMP} ${ARF_FILE_INNER_TEMP}" "1.0 -1.0" "${ARF_FILE}" clobber=yes
    echo "--- ARF subtraction complete ---"
else
    echo "--- Generating ARF via standard method (no pile-up) ---"
    arfgen spectrumset="${SRC_SPEC}" arfset="${ARF_FILE}" \
        withrmfset=yes rmfset="${RMF_FILE}" \
        badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf
    echo "--- Standard ARF generation complete ---"
fi

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

# Define filenames
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
cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}"; exit 1; }
# --- End Plotting Section ---

# --- 10. Clean up temporary files ---
echo "Cleaning up temporary files..."
if [ "${IS_PILED_UP}" == "yes" ]; then
    rm -f "${SRC_SPEC_FULL_TEMP}" "${SRC_SPEC_INNER_TEMP}" \
          "${ARF_FILE_FULL_TEMP}" "${ARF_FILE_INNER_TEMP}"
fi
# Keep raw LCs for inspection
# rm -f "${SRC_LC_RAW_FILE}" "${BKG_LC_RAW_FILE}"

# --- 11. Completion ---
echo "--------------------------------------------------"
echo "Spectral and Lightcurve extraction complete for ObsID ${OBSID}."
echo ""
echo "Final grouped spectrum: ${GRP_SPEC_FILE}"
echo "Background spectrum:    ${BKG_SPEC}"
echo "Response matrix (RMF):  ${RMF_FILE}"
echo "Ancillary file (ARF):   ${ARF_FILE}"
echo "Corrected lightcurve:   ${CORR_LC_FILE}"
echo ""
echo "Plots created in: ${LC_DIR}"
echo "  - ${LC_SRC_RAW_PNG}"
echo "  - ${LC_BKG_RAW_PNG}"
echo "  - ${LC_CORR_PNG}"
echo ""
echo "These files are ready for analysis in XSPEC or SPEX (after conversion)."
echo "--------------------------------------------------"
