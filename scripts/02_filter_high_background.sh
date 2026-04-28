#!/bin/bash
#
# SCRIPT: 02_filter_high_background.sh
#
# DESCRIPTION:
# Creates a high-energy background lightcurve for a specific ObsID.
# Based on user-set variables, it then applies a flare filter (or not)
# to create the final 'pn_clean.evt' file in products/[ObsID]/pn/.
#
# ASSUMES:
# - $PROJECT_ROOT environment variable points to the project root directory.
# - $OBSID environment variable is set to the 10-digit observation ID.
# - HEASOFT and SAS are initialized.
#
# USAGE:
# 1. Ensure $PROJECT_ROOT and $OBSID are set.
# 2. Run this script once:
#    ./scripts/02_filter_background.sh
#
# 3. Open 'products/[ObsID]/pn/pn_bkg_lc.jpg'.
#
# 4. Based on the bkg plot, edit the "USER CONFIGURATION" section below.
#    - If you see flares:
#      Set APPLY_FILTER="yes"
#      Set RATE_THRESHOLD to your chosen cutoff (e.g., "0.4")
#    - If you see NO flares:
#      Leave APPLY_FILTER="no"
#
# 5. Run the script again. It will now create 'products/[ObsID]/pn/pn_clean.evt'.
#
################################################################################

# --- USER CONFIGURATION - EDIT THIS SECTION ---

# Set to "yes" to apply the filter, "no" to skip it.
APPLY_FILTER="yes"

# If APPLY_FILTER="yes", set your count rate cutoff here.
RATE_THRESHOLD="0.3"

# --- END OF CONFIGURATION ---

# --- Source shared setup ---
source "$(dirname "$0")/sas_common.sh"

# Set strict error checking
set -e

echo "--- Starting Background Flare Filtering ---"
echo "Looking for input/output files in: ${PN_DIR}"

# --- 1. Find the input EPIC-pn event file ---
echo "Locating PN event file from epproc..."

PN_EVT_FILE=$(find "${PN_DIR}" -name "*EPN*Evts.ds" -type f | head -n 1)

if [ -z "${PN_EVT_FILE}" ]; then
    echo "ERROR: Could not find the primary PN event file (*EPN*Evts.ds) in ${PN_DIR}"
    echo "Please ensure the 01_setup_and_reprocess.sh script ran correctly for ObsID ${OBSID}."
    exit 1
fi
echo "Found event file: ${PN_EVT_FILE}"

# --- 2. Define output filenames ---
BKG_LC="${PN_DIR}/pn_bkg_lc.fits"
BKG_LC_PLOT="${PN_DIR}/pn_bkg_lc.jpg"
GTI_FILE="${PN_DIR}/gti_bkg.fits"

# Define filter expressions
BKG_EXPR="#XMMEA_EP && (PI in [10000:12000]) && (PATTERN==0)"
# Note: #XMMEA_EP is for IMAGING mode. For TIMING mode, this should be (RAWX in [3:5]) or similar.
# Assuming BKG_EXPR is correct for your mode.

# --- 3. Create Background Lightcurve ---
echo "Creating background lightcurve: ${BKG_LC}"
evselect table="${PN_EVT_FILE}" \
    withrateset=yes rateset="${BKG_LC}" \
    maketimecolumn=yes timebinsize=30 makeratecolumn=yes \
    expression="${BKG_EXPR}"


# --- 4. Create Plots ---
echo "Changing to ${PN_DIR} to create plots..."
cd "${PN_DIR}" || { echo "Failed to cd into ${PN_DIR}"; exit 1; }

echo "Creating diagnostic plots..."

# Background Lightcurve (Time vs. Rate)
echo "  Generating pn_bkg_lc.ps..."
fplot "pn_bkg_lc.fits[RATE]" xparm="TIME" yparm="RATE" mode='h' device="pn_bkg_lc.ps/PS" </dev/null
convert -density 300 "pn_bkg_lc.ps[0]" pn_bkg_lc.jpg
echo "  Created ${BKG_LC_PLOT}"
rm -f "pn_bkg_lc.ps" # Clean up postscript file

# Return to the root directory
echo "Plots created. Returning to root directory..."
cd "${PROJECT_ROOT}" || { echo "Failed to cd back to ${PROJECT_ROOT}"; exit 1; }

echo ""
echo "Plots created in ${PN_DIR}. Please inspect background lightcurve: ${BKG_LC_PLOT}"
echo ""
echo "--> Set APPLY_FILTER in this script and re-run. <--"
echo ""

# --- 5. Apply Filter (or not) based on user flag ---

# Base science filter expression
# For TIMING Mode: (PATTERN<=4) && (FLAG==0)
# For IMAGING Mode: #XMMEA_EP && (PATTERN<=12)
SCIENCE_EXPR="#XMMEA_EP && (PATTERN<=4) && (PI>200)" # Using TIMING mode expression

if [ "${APPLY_FILTER}" == "yes" ]; then
    echo "--- Applying flare filter ---"
    echo "Using count rate threshold: <= ${RATE_THRESHOLD}"

    # 1. Create a Good Time Interval (GTI) file from the background lightcurve
    tabgtigen table="${BKG_LC}" \
        expression="RATE<=${RATE_THRESHOLD}" \
        gtiset="${GTI_FILE}"

    # 2. Create the final clean event file by applying the GTI
    echo "Creating clean event file: ${CLEAN_EVT_FILE}"
    evselect table="${PN_EVT_FILE}" \
        withfilteredset=yes filteredset="${CLEAN_EVT_FILE}" \
        keepfilteroutput=yes \
        expression="${SCIENCE_EXPR} && gti(${GTI_FILE},TIME)" \
        updateexposure=yes writedss=yes

    echo "Filtering complete."

else
    echo "--- Skipping flare filter (APPLY_FILTER=no) ---"
    
    # Create the "clean" file, applying only the base science filter.
    echo "Creating clean event file: ${CLEAN_EVT_FILE}"
    evselect table="${PN_EVT_FILE}" \
        withfilteredset=yes filteredset="${CLEAN_EVT_FILE}" \
        keepfilteroutput=yes \
        expression="${SCIENCE_EXPR}" \
        updateexposure=yes writedss=yes

    echo "File creation complete (no flare filter applied)."
fi

echo "--- Background filtering script finished ---"
