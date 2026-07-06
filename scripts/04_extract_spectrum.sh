#!/bin/bash
#
# SCRIPT: 04_extract_spectrum.sh
#
# DESCRIPTION:
# Extracts the final source spectrum, background spectrum, RMF, ARF,
# and groups the spectrum for an EPIC-pn TIMING MODE observation.
# Handles BOTH standard extraction AND piled-up cases.
# (Note: Lightcurve extraction has been split out into 04_extract_lc.sh)
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
# 5. Run the script: ./scripts/04_extract_spectrum.sh
#
################################################################################

source "$(dirname "$0")/sas_common.sh"

# The grouping specification for the final spectrum
GROUPING_SPEC="20"

set -e
echo "--- Starting Spectral Extraction ---"
if [ "${IS_PILED_UP}" == "yes" ]; then
    echo "*** PILE-UP CORRECTION ENABLED ***"
else
    echo "*** STANDARD EXTRACTION (NO PILE-UP) ***"
fi
echo "Using ObsID: ${OBSID}"
echo "Input file from: ${PN_DIR}"
echo "Spectral products to: ${SPEC_DIR}"

mkdir -p "${SPEC_DIR}"

SRC_SPEC="${SPEC_DIR}/pn_source_spectrum.fits"
RMF_FILE="${SPEC_DIR}/pn_rmf.rmf"
ARF_FILE="${SPEC_DIR}/pn_arf.arf"
GRP_SPEC_FILE="${SPEC_DIR}/pn_source_spectrum_grp.fits"
BKG_SPEC="${SPEC_DIR}/pn_bkg_spectrum.fits"

# --- Spatial Filters ---
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

# --- Extract Source Spectrum ---
SPECTRAL_BASE_FILTER_EXPR="(FLAG==0)&&(PI in [200:15000])&&(PATTERN<=4)"
FINAL_SRC_SPEC_FILTER_EXPR="${SPECTRAL_BASE_FILTER_EXPR} && ${FINAL_SRC_RAWX_FILTER}"

echo "Extracting source spectrum: ${SRC_SPEC}"
extract_spectrum "${SRC_SPEC}" "${FINAL_SRC_SPEC_FILTER_EXPR}"

# --- Extract Background Spectrum ---
echo "Extracting background spectrum: ${BKG_SPEC}"
BKG_FILTER_EXPR="${SPECTRAL_BASE_FILTER_EXPR} && ${BKG_RAWX_FILTER}"
extract_spectrum "${BKG_SPEC}" "${BKG_FILTER_EXPR}"

# --- Calculate BACKSCAL Keywords ---
echo "Calculating BACKSCAL for source spectrum..."
backscale spectrumset="${SRC_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"
echo "Calculating BACKSCAL for background spectrum..."
backscale spectrumset="${BKG_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"

# --- Generate RMF ---
echo "Generating RMF: ${RMF_FILE}"
rmfgen spectrumset="${SRC_SPEC}" rmfset="${RMF_FILE}"

# --- Generate ARF (Conditional Method) ---
generate_arf "${SRC_SPEC}" "${ARF_FILE}" "${RMF_FILE}" "${SPECTRAL_BASE_FILTER_EXPR}"

# --- Group the Source Spectrum ---
echo "Grouping the final spectrum: ${GRP_SPEC_FILE}"
specgroup spectrumset="${SRC_SPEC}" \
    groupedset="${GRP_SPEC_FILE}" \
    backgndset="${BKG_SPEC}" \
    rmfset="${RMF_FILE}" \
    arfset="${ARF_FILE}" \
    mincounts="${GROUPING_SPEC}"

# --- Completion ---
echo "--------------------------------------------------"
echo "Spectral extraction complete for ObsID ${OBSID}."
echo ""
echo "Final grouped spectrum: ${GRP_SPEC_FILE}"
echo "Background spectrum:    ${BKG_SPEC}"
echo "Response matrix (RMF):  ${RMF_FILE}"
echo "Ancillary file (ARF):   ${ARF_FILE}"
echo ""
echo "These files are ready for analysis in XSPEC or SPEX (after conversion)."
echo "--------------------------------------------------"
