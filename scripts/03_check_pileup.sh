#!/bin/bash
#
# SCRIPT: 03_check_pileup.sh
#
# DESCRIPTION:
# For a specific ObsID:
# 1. Creates a RAWX/RAWY image to help select regions.
# 2. Creates a 'epatplot_FULL.jpg' of the entire source region.
# 3. If enabled, creates an 'epatplot_EXCISED.jpg' to test pile-up removal.
# Output files are placed in products/[ObsID]/pn/ and products/[ObsID]/pn/pile_up/
#
# ASSUMES:
# - $PROJECT_ROOT environment variable points to the project root directory.
# - $OBSID environment variable is set to the 10-digit observation ID.
# - HEASOFT and SAS are initialized.
#
# USAGE:
# 1. Ensure $PROJECT_ROOT and $OBSID are set.
# 2. Run this script once. It will create 'products/[ObsID]/pn/pn_rawx_rawy_image.fits'
#    and '.../pile_up/epatplot_FULL.jpg'.
# 3. Open both (paths will be in the log output).
# 4. Based on the plots, edit the 'USER CONFIGURATION' section:
#    - Set RUN_EXCISION_TEST="yes".
#    - Set SRC_EXCISION_FILTER to the RAWX columns you want to cut out.
# 5. Run the script again. It will now create an 'epatplot_EXCISED.jpg'.
#
################################################################################

# --- Source shared setup ---
source "$(dirname "$0")/sas_common.sh"

# --- USER CONFIGURATION - EDIT THIS SECTION ---

# Override source/background regions for pile-up checking if needed
# (defaults come from sas_common.sh)
SRC_RAWX_FILTER="${SRC_RAWX_FILTER_STD}"
# BKG_RAWX_FILTER is inherited from sas_common.sh

# --- epatplot Energy Range (in eV) ---
# Default: 0.5-10 keV. Adjust to focus on a specific band.
# Examples: soft band (500-2000), hard band (2000-10000)
EPAT_PIMIN=500
EPAT_PIMAX=2000

# --- Pile-up Excision Test ---
# Set this to "yes" to run the test
RUN_EXCISION_TEST="yes"

# --- END OF CONFIGURATION ---

# Set strict error checking
set -e

echo "--- Starting Pile-up Check (epatplot) for TIMING MODE ---"
echo "Using ObsID: ${OBSID}"

# --- Define Directories ---
export PU_DIR="${PN_DIR}/pile_up"
echo "Looking for input/output files in: ${PN_DIR}"
echo "Placing plots in: ${PU_DIR}"

# --- 1. Create the output directory ---
echo "Creating plot directory: ${PU_DIR}"
mkdir -p "${PU_DIR}"

# --- 2. Define filenames ---
IMAGE_FILE="${PN_DIR}/pn_rawx_rawy_image.fits" # For inspection
BKG_EVT_TEMP="${PN_DIR}/pn_bkg_temp.evt"

# Base filter expression
BASE_FILTER_EXPR="(FLAG==0)&&(PI in [500:15000])&&(PATTERN<=4)"

if [ ! -f "${CLEAN_EVT_FILE}" ]; then
    echo "ERROR: Could not find ${CLEAN_EVT_FILE}"
    echo "Please run script 02 for ObsID ${OBSID} first."
    exit 1
fi

# --- 3. Create RAWX/RAWY Image for Inspection (Always runs) ---
echo "Creating RAWX/RAWY image: ${IMAGE_FILE}"
evselect table="${CLEAN_EVT_FILE}" \
    imageset="${IMAGE_FILE}" \
    withimageset=yes \
    xcolumn=RAWX ycolumn=RAWY \
    imagebinning=binSize ximagebinsize=1 yimagebinsize=1 \
    expression="${BASE_FILTER_EXPR}"

echo "--> Image created: ${IMAGE_FILE}"
echo "    (Use ds9 to inspect and choose your RAWX regions)"

# --- 4. Create Background Event File (Always runs) ---
echo "Creating temporary background event file..."
BKG_FILTER_EXPR="${BASE_FILTER_EXPR} && ${BKG_RAWX_FILTER}"
evselect table="${CLEAN_EVT_FILE}" \
    withfilteredset=yes \
    filteredset="${BKG_EVT_TEMP}" \
    keepfilteroutput=yes \
    expression="${BKG_FILTER_EXPR}"
    
# --- 5. Create FULL Source Region epatplot (Always runs) ---
echo "--- Creating FULL region pile-up plot ---"
FULL_SRC_FILTER_EXPR="${BASE_FILTER_EXPR} && ${SRC_RAWX_FILTER}"
SRC_EVT_FULL_TEMP="${PN_DIR}/pn_src_full_temp.evt"
EPAT_PLOT_FULL_PDF="epatplot_FULL.pdf"
EPAT_PLOT_FULL_JPG="epatplot_FULL.jpg"
evselect table="${CLEAN_EVT_FILE}" \
    withfilteredset=yes \
    filteredset="${SRC_EVT_FULL_TEMP}" \
    keepfilteroutput=yes \
    expression="${FULL_SRC_FILTER_EXPR}"

echo "Changing to plot directory to work around epatplot bug..."
cd "${PU_DIR}" || { echo "Failed to cd to ${PU_DIR}"; exit 1; }

epatplot set="${SRC_EVT_FULL_TEMP}" \
    plotfile="${EPAT_PLOT_FULL_PDF}" \
    useplotfile=yes \
    withbackgroundset=yes \
    backgroundset="${BKG_EVT_TEMP}" \
    pileupnumberenergyrange="${EPAT_PIMIN} ${EPAT_PIMAX}" \
    </dev/null # Added non-interactive flag

# Convert PDF to JPG
echo "Converting plot to JPG: ${EPAT_PLOT_FULL_JPG}"
convert -density 300 "${EPAT_PLOT_FULL_PDF}[1]" "${EPAT_PLOT_FULL_JPG}"


# --- 6. Create EXCISED Source Region epatplot (Conditional) ---
SRC_EVT_EXCISED_TEMP="${PN_DIR}/pn_src_excised_temp.evt" # Define here for cleanup
if [ "${RUN_EXCISION_TEST}" == "yes" ]; then
    echo "--- Creating EXCISED region pile-up plot ---"
    
    EXCISED_SRC_FILTER_EXPR="${BASE_FILTER_EXPR} && ${SRC_RAWX_FILTER} && ${SRC_EXCISION_FILTER}"
    EPAT_PLOT_EXCISED_PDF="epatplot_EXCISED.pdf"
    EPAT_PLOT_EXCISED_JPG="epatplot_EXCISED.jpg"
    
    echo "Using filter: ${EXCISED_SRC_FILTER_EXPR}"
    
    evselect table="${CLEAN_EVT_FILE}" \
        withfilteredset=yes \
        filteredset="${SRC_EVT_EXCISED_TEMP}" \
        keepfilteroutput=yes \
        expression="${EXCISED_SRC_FILTER_EXPR}"

    epatplot set="${SRC_EVT_EXCISED_TEMP}" \
        plotfile="${EPAT_PLOT_EXCISED_PDF}" \
        useplotfile=yes \
        withbackgroundset=yes \
        backgroundset="${BKG_EVT_TEMP}" \
        pileupnumberenergyrange="${EPAT_PIMIN} ${EPAT_PIMAX}" \
        </dev/null # Added non-interactive flag
    
    # Convert PDF to JPG
    echo "Converting plot to JPG: ${EPAT_PLOT_EXCISED_JPG}"
    convert -density 300 "${EPAT_PLOT_EXCISED_PDF}[1]" "${EPAT_PLOT_EXCISED_JPG}"
 
    
fi

# --- 7. Clean up common temporary files ---
echo "Cleaning up temporary event files..."
rm -f "${SRC_EVT_FULL_TEMP}"
rm -f "${BKG_EVT_TEMP}"
if [ "${RUN_EXCISION_TEST}" == "yes" ]; then
    rm -f "${SRC_EVT_EXCISED_TEMP}"
fi

echo "Returning to project root directory..."
cd "${PROJECT_ROOT}" || { echo "Failed to cd back to ${PROJECT_ROOT}"; exit 1; }

# --- 8. Instruct ---
echo ""
echo "------------------------------------------------------------------"
echo "ACTION REQUIRED: Inspect your plot(s) in ${PU_DIR}"
echo ""
echo "1. Look at 'epatplot_FULL.jpg' to confirm pile-up."
if [ "${RUN_EXCISION_TEST}" == "yes" ]; then
    echo "2. Look at 'epatplot_EXCISED.jpg' to check your fix."
    echo "   -> If it is NOT flat, adjust 'SRC_EXCISION_FILTER' and re-run."
    echo "   -> If it IS flat, pile-up is removed."
else
    echo "2. To test an excision, edit this script:"
    echo "   -> Set RUN_EXCISION_TEST=\"yes\""
    echo "   -> Set SRC_EXCISION_FILTER (e.g., \"!(RAWX in [36:38])\")"
fi
echo "------------------------------------------------------------------"
