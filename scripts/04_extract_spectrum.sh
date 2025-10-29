#!/bin/bash
#
# SCRIPT: 04_extract_spectrum.sh
#
# DESCRIPTION:
# Extracts the final source spectrum, background spectrum, RMF, and ARF
# for an EPIC-pn TIMING MODE observation for a specific ObsID.
# Handles BOTH standard extraction (no pile-up) AND piled-up cases
# where RAWX columns need excision.
# Output files are placed in products/[ObsID]/pn/spec/
#
# ASSUMES:
# - OBS_DIR_ODF environment variable points to data/[OBSID]
#
# USAGE:
# 1. Ensure you have run scripts 01, 02, and 03 for the target ObsID.
# 2. Update the RAWX filters below based on your findings in script 03.
# 3. SET THE 'IS_PILED_UP' FLAG ("yes" or "no").
# 4. If IS_PILED_UP="yes", set the 'SRC_EXCISION_FILTER'.
# 5. Run the script: ./scripts/04_extract_spectrum.sh
#
################################################################################

# --- USER CONFIGURATION - EDIT THIS SECTION ---

# Set to "yes" if epatplot showed pile-up, otherwise "no".
IS_PILED_UP="yes"

# The standard source region (used if IS_PILED_UP="no")
# Example: "RAWX in [30:45]"
SRC_RAWX_FILTER_STD="RAWX in [27:47]"

# The BACKGROUND region (used always)
# Example: "RAWX in [5:15]"
BKG_RAWX_FILTER="RAWX in [3:5]"

# --- Only needed if IS_PILED_UP="yes" ---
# The PILE-UP EXCISION filter (the columns to REMOVE from SRC_RAWX_FILTER_STD)
# Example: "!(RAWX in [36:38])"
SRC_EXCISION_FILTER="!(RAWX in [36:38])"
# --- End Pile-up Specific ---

# The grouping specification for the final spectrum
# Example: Minimum 25 counts per bin
GROUPING_SPEC="25"

# --- END OF CONFIGURATION ---

# --- Re-establish SAS Setup Variables ---
# Assumes OBS_DIR_ODF points to data/[OBSID]
ODF_DIR_CLEAN=$(echo "${OBS_DIR_ODF}" | sed 's:/*$::') # Clean path to data dir

CCF_FILE="${ODF_DIR_CLEAN}/ccf.cif"

# Find the specific *SUM.SAS file within the data directory
SUMMARY_FILE_NAME=$(find "${ODF_DIR_CLEAN}" -maxdepth 1 -name "*SUM.SAS" -printf "%f\n" | head -n 1)
if [ -z "${SUMMARY_FILE_NAME}" ]; then
    echo "ERROR: Cannot find *SUM.SAS file in ${ODF_DIR_CLEAN}"
    echo "Please ensure script 01 ran successfully."
    exit 1
fi
SUMMARY_FILE="${ODF_DIR_CLEAN}/${SUMMARY_FILE_NAME}" # Construct full path

# Check if both files exist
if [ ! -f "${CCF_FILE}" ]; then
    echo "ERROR: Cannot find CCF file: ${CCF_FILE}"
    echo "Please ensure script 01 ran successfully."
    exit 1
fi
if [ ! -f "${SUMMARY_FILE}" ]; then
    # This check is somewhat redundant due to the find check, but good for clarity
    echo "ERROR: Cannot find Summary file: ${SUMMARY_FILE}"
    echo "Please ensure script 01 ran successfully."
    exit 1
fi

export SAS_CCF="${CCF_FILE}"
export SAS_ODF="${SUMMARY_FILE}"
echo "SAS_CCF re-established: $(basename "${SAS_CCF}")"
echo "SAS_ODF re-established: $(basename "${SAS_ODF}")"
# --- End Re-establish ---

# Set strict error checking
set -e

echo "--- Starting Spectral Extraction for PN Timing Mode ---"
if [ "${IS_PILED_UP}" == "yes" ]; then
    echo "*** PILE-UP CORRECTION ENABLED ***"
else
    echo "*** STANDARD EXTRACTION (NO PILE-UP) ***"
fi

export PROC_DIR=$(pwd)

# --- Get ObsID ---
if [ -z "${OBS_DIR_ODF}" ]; then
    echo "ERROR: Environment variable OBS_DIR_ODF is not set."
    echo "Should point to e.g., /path/to/data/0123456789"
    exit 1
fi
OBSID=$(basename "${OBS_DIR_ODF}")
if ! [[ "${OBSID}" =~ ^[0-9]{10}$ ]]; then
    echo "WARNING: Could not reliably determine 10-digit ObsID from OBS_DIR_ODF path ('${OBS_DIR_ODF}'). Got '${OBSID}'."
    OBSID="unknown_obsid" # Fallback
fi
echo "Using ObsID: ${OBSID}"

# --- Define Directories ---
export PN_DIR="products/${OBSID}/pn"
export SPEC_DIR="products/${OBSID}/pn/spec" # Output directory for final spectra
echo "Looking for input/output files in: ${PN_DIR} and ${SPEC_DIR}"

# --- 1. Create output directory ---
echo "Creating output directory: ${SPEC_DIR}"
mkdir -p "${SPEC_DIR}"

# --- 2. Define filenames (Generic Names) ---
CLEAN_EVT_FILE="${PN_DIR}/pn_clean.evt"

SRC_SPEC="${SPEC_DIR}/pn_source_spectrum.fits"
RMF_FILE="${SPEC_DIR}/pn_rmf.rmf"
ARF_FILE="${SPEC_DIR}/pn_arf.arf"
GRP_SPEC_FILE="${SPEC_DIR}/pn_source_spectrum_grp.fits"

BKG_SPEC="${SPEC_DIR}/pn_bkg_spectrum.fits"

# Temporary files only needed for pile-up ARF subtraction
# Placed in PN_DIR not SPEC_DIR
SRC_SPEC_FULL_TEMP="${PN_DIR}/pn_source_spectrum_full_temp.fits"
SRC_SPEC_INNER_TEMP="${PN_DIR}/pn_source_spectrum_inner_temp.fits"
ARF_FILE_FULL_TEMP="${PN_DIR}/pn_arf_full_temp.arf"
ARF_FILE_INNER_TEMP="${PN_DIR}/pn_arf_inner_temp.arf"

# Standard filter expression
BASE_FILTER_EXPR="(FLAG==0)&&(PI in [500:15000])&&(PATTERN<=4)"

# --- 3. Determine Final Source Filter Based on Pile-up Flag ---
if [ "${IS_PILED_UP}" == "yes" ]; then
    FINAL_SRC_FILTER_EXPR="${BASE_FILTER_EXPR} && ${SRC_RAWX_FILTER_STD} && ${SRC_EXCISION_FILTER}"
    echo "Using PILED-UP source filter: ${FINAL_SRC_FILTER_EXPR}"
else
    FINAL_SRC_FILTER_EXPR="${BASE_FILTER_EXPR} && ${SRC_RAWX_FILTER_STD}"
    echo "Using STANDARD source filter: ${FINAL_SRC_FILTER_EXPR}"
fi

if [ ! -f "${CLEAN_EVT_FILE}" ]; then
    echo "ERROR: Could not find ${CLEAN_EVT_FILE}"
    echo "Please run script 02 for ObsID ${OBSID} first."
    exit 1
fi

# --- 4. Extract Source Spectrum ---
echo "Extracting source spectrum: ${SRC_SPEC}"
evselect table="${CLEAN_EVT_FILE}" \
    withspectrumset=yes spectrumset="${SRC_SPEC}" \
    energycolumn=PI spectralbinsize=5 \
    withspecranges=yes specchannelmin=0 specchannelmax=20479 \
    expression="${FINAL_SRC_FILTER_EXPR}"

# --- 5. Extract Background Spectrum ---
echo "Extracting background spectrum: ${BKG_SPEC}"
BKG_FILTER_EXPR="${BASE_FILTER_EXPR} && ${BKG_RAWX_FILTER}"
evselect table="${CLEAN_EVT_FILE}" \
    withspectrumset=yes spectrumset="${BKG_SPEC}" \
    energycolumn=PI spectralbinsize=5 \
    withspecranges=yes specchannelmin=0 specchannelmax=20479 \
    expression="${BKG_FILTER_EXPR}"

# --- 6. Calculate BACKSCAL Keywords ---
echo "Calculating BACKSCAL for source spectrum..."
backscale spectrumset="${SRC_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"

echo "Calculating BACKSCAL for background spectrum..."
backscale spectrumset="${BKG_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"

# --- 7. Generate RMF ---
# RMF generation is the same for both cases
echo "Generating RMF: ${RMF_FILE}"
rmfgen spectrumset="${SRC_SPEC}" rmfset="${RMF_FILE}"

# --- 8. Generate ARF (Conditional Method) ---
if [ "${IS_PILED_UP}" == "yes" ]; then
    echo "--- Generating ARF via subtraction method (for pile-up) ---"

    # Filter for the INNER CORE (the part being excised)
    INNER_CORE_RAWX=$(echo "${SRC_EXCISION_FILTER}" | sed -e 's/!//' -e 's/(//' -e 's/)//')
    INNER_CORE_FILTER_EXPR="${BASE_FILTER_EXPR} && ${INNER_CORE_RAWX}"

    # 8a-Pileup. Extract FULL source spectrum (temporary)
    echo "  Extracting FULL source spectrum (temp)..."
    FULL_SRC_FILTER_EXPR_TEMP="${BASE_FILTER_EXPR} && ${SRC_RAWX_FILTER_STD}"
    evselect table="${CLEAN_EVT_FILE}" \
        withspectrumset=yes spectrumset="${SRC_SPEC_FULL_TEMP}" \
        energycolumn=PI spectralbinsize=5 \
        withspecranges=yes specchannelmin=0 specchannelmax=20479 \
        expression="${FULL_SRC_FILTER_EXPR_TEMP}"

    # 8b-Pileup. Extract INNER CORE spectrum (temporary)
    echo "  Extracting INNER CORE spectrum (temp)..."
    evselect table="${CLEAN_EVT_FILE}" \
        withspectrumset=yes spectrumset="${SRC_SPEC_INNER_TEMP}" \
        energycolumn=PI spectralbinsize=5 \
        withspecranges=yes specchannelmin=0 specchannelmax=20479 \
        expression="${INNER_CORE_FILTER_EXPR}"

    # 8c-Pileup. Generate ARF for FULL spectrum
    echo "  Generating ARF for FULL spectrum (temp)..."
    arfgen spectrumset="${SRC_SPEC_FULL_TEMP}" arfset="${ARF_FILE_FULL_TEMP}" \
        withrmfset=yes rmfset="${RMF_FILE}" \
        badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf

    # 8d-Pileup. Generate ARF for INNER CORE spectrum
    echo "  Generating ARF for INNER CORE spectrum (temp)..."
    arfgen spectrumset="${SRC_SPEC_INNER_TEMP}" arfset="${ARF_FILE_INNER_TEMP}" \
        withrmfset=yes rmfset="${RMF_FILE}" \
        badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf

    # 8e-Pileup. Subtract ARFs using addarf
    echo "  Subtracting ARFs to create final ARF: ${ARF_FILE}"
    # Use clobber=yes for addarf
    addarf "${ARF_FILE_FULL_TEMP} ${ARF_FILE_INNER_TEMP}" "1.0 -1.0" "${ARF_FILE}" clobber=yes

    echo "--- ARF subtraction complete ---"

else
    echo "--- Generating ARF via standard method (no pile-up) ---"
    # Standard ARF generation using the extracted source spectrum
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

# --- 10. Clean up temporary files ---
echo "Cleaning up temporary files..."
# Only remove pile-up temp files if they were created
if [ "${IS_PILED_UP}" == "yes" ]; then
    rm -f "${SRC_SPEC_FULL_TEMP}" "${SRC_SPEC_INNER_TEMP}" \
          "${ARF_FILE_FULL_TEMP}" "${ARF_FILE_INNER_TEMP}"
fi

# --- 11. Completion ---
echo "--------------------------------------------------"
echo "Spectral extraction complete for ObsID ${OBSID}."
echo "Final grouped spectrum: ${GRP_SPEC_FILE}"
echo "Background spectrum:    ${BKG_SPEC}"
echo "Response matrix (RMF):  ${RMF_FILE}"
echo "Ancillary file (ARF):   ${ARF_FILE}"
echo "These files are ready for analysis in XSPEC or SPEX (after conversion)."
echo "Open XSPEC in root directory to import grouped spectra."
echo "--------------------------------------------------"
