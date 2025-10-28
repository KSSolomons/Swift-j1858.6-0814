#!/bin/bash
#
# SCRIPT: 03_check_pileup.sh
#
# DESCRIPTION:
# 1. Creates a RAWX/RAWY image to help select regions.
# 2. Creates a 'epatplot_FULL.png' of the entire source region.
# 3. If enabled, creates an 'epatplot_EXCISED.png' to test pile-up removal.
#
# USAGE:
# 1. Run this script once. It will create 'products/pn/pn_rawx_rawy_image.fits'
#    and '.../pile_up/epatplot_FULL.png'.
# 2. Open both:
#    ds9 products/pn/pn_rawx_rawy_image.fits
#    xdg-open products/pn/pile_up/epatplot_FULL.png
# 3. Based on the plots, edit the 'USER CONFIGURATION' section:
#    - Set RUN_EXCISION_TEST="yes".
#    - Set SRC_EXCISION_FILTER to the RAWX columns you want to cut out.
# 4. Run the script again. It will now create an 'epatplot_EXCISED.png'.
# 5. Inspect the new plot. If it's not flat, adjust SRC_EXCISION_FILTER
#    and re-run.
#
################################################################################

# --- USER CONFIGURATION - EDIT THIS SECTION ---

# Set the RAWX filter for your FULL SOURCE
# Example: "RAWX in [30:45]"
SRC_RAWX_FILTER="RAWX in [27:47]"

# Set the RAWX filter for your BACKGROUND
# Example: "RAWX in [3:5]"
BKG_RAWX_FILTER="RAWX in [3:5]"

# --- Pile-up Excision Test ---
# Set this to "yes" to run the test
RUN_EXCISION_TEST="yes"

# Set the filter for the central columns you want to REMOVE

SRC_EXCISION_FILTER="!(RAWX in [36:38])"

# --- END OF CONFIGURATION ---


# Set strict error checking
set -e

echo "--- Starting Pile-up Check (epatplot) for TIMING MODE ---"
export PROC_DIR=$(pwd)
export PN_DIR="products/pn"
export PU_DIR="products/pn/pile_up"

# --- 1. Create the output directory ---
echo "Creating plot directory: ${PU_DIR}"
mkdir -p "${PU_DIR}"

# --- 2. Define filenames ---
CLEAN_EVT_FILE="${PN_DIR}/pn_clean.evt"
IMAGE_FILE="${PN_DIR}/pn_rawx_rawy_image.fits" # For inspection
BKG_EVT_TEMP="${PN_DIR}/pn_bkg_temp.evt"

# Base filter expression
BASE_FILTER_EXPR="(FLAG==0)&&(PI in [500:15000])&&(PATTERN<=4)"

if [ ! -f "${CLEAN_EVT_FILE}" ]; then
    echo "ERROR: Could not find ${CLEAN_EVT_FILE}"
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

evselect table="${CLEAN_EVT_FILE}" \
    withfilteredset=yes \
    filteredset="${SRC_EVT_FULL_TEMP}" \
    keepfilteroutput=yes \
    expression="${FULL_SRC_FILTER_EXPR}" 
    
epatplot set="${SRC_EVT_FULL_TEMP}" \
    plotfile="${PU_DIR}/epatplot_FULL.pdf" \
    useplotfile=yes \
    withbackgroundset=yes \
    backgroundset="${BKG_EVT_TEMP}" 

convert "${PU_DIR}/epatplot_FULL.pdf[0]" "${PU_DIR}/epatplot_FULL.png"
echo "--> Full region plot created: ${PU_DIR}/epatplot_FULL.png"


# --- 6. Create EXCISED Source Region epatplot (Conditional) ---
if [ "${RUN_EXCISION_TEST}" == "yes" ]; then
    echo "--- Creating EXCISED region pile-up plot ---"
    
    
    EXCISED_SRC_FILTER_EXPR="${BASE_FILTER_EXPR} && ${SRC_RAWX_FILTER} && ${SRC_EXCISION_FILTER}"
    SRC_EVT_EXCISED_TEMP="${PN_DIR}/pn_src_excised_temp.evt"
    
    echo "Using filter: ${EXCISED_SRC_FILTER_EXPR}"
    
    evselect table="${CLEAN_EVT_FILE}" \
        withfilteredset=yes \
        filteredset="${SRC_EVT_EXCISED_TEMP}" \
        keepfilteroutput=yes \
        expression="${EXCISED_SRC_FILTER_EXPR}" 

    epatplot set="${SRC_EVT_EXCISED_TEMP}" \
        plotfile="${PU_DIR}/epatplot_EXCISED.pdf" \
        useplotfile=yes \
        withbackgroundset=yes \
        backgroundset="${BKG_EVT_TEMP}" 
      
    convert "${PU_DIR}/epatplot_EXCISED.pdf[0]" "${PU_DIR}/epatplot_EXCISED.png"
    echo "--> Excised region plot created: ${PU_DIR}/epatplot_EXCISED.png"
    
    # Clean up excised temp file
    rm "${SRC_EVT_EXCISED_TEMP}"
fi

# --- 7. Clean up common temporary files ---
echo "Cleaning up temporary event files..."
rm "${SRC_EVT_FULL_TEMP}"
rm "${BKG_EVT_TEMP}"

# --- 8. Instruct ---
echo ""
echo "------------------------------------------------------------------"
echo "ACTION REQUIRED: Inspect your plot(s)."
echo ""
echo "1. Look at 'epatplot_FULL.png' to confirm pile-up."
if [ "${RUN_EXCISION_TEST}" == "yes" ]; then
    echo "2. Look at 'epatplot_EXCISED.png' to check your fix."
    echo "   -> If it is NOT flat, adjust 'SRC_EXCISION_FILTER' and re-run."
    echo "   -> If it IS flat, pile-up is removed."
else
    echo "2. To test an excision, edit this script:"
    echo "   -> Set RUN_EXCISION_TEST=\"yes\""
    echo "   -> Set SRC_EXCISION_FILTER (e.g., \"!(RAWX in [36:38])\")"
fi
echo "------------------------------------------------------------------"
