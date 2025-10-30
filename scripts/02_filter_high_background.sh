#!/bin/bash
#
# SCRIPT: 02_filter_background.sh
#
# DESCRIPTION:
# Creates high-energy background and source lightcurves for a specific ObsID.
# Based on user-set variables, it then applies a flare filter (or not)
# to create the final 'pn_clean.evt' file in products/[ObsID]/pn/.
#
# ASSUMES:
# - OBS_DIR_ODF environment variable points to data/[OBSID]
#
# USAGE:
# 1. Run this script once from the repository root:
#    ./scripts/02_filter_background.sh
#
# 2. Open the new plots in 'products/[ObsID]/pn/':
#    - 'pn_bkg_lc.jpg' (the background lightcurve)
#    - 'pn_src_lc.jpg' (the source lightcurve)
#
# 3. Based on the bkg plot, edit the "USER CONFIGURATION" section below.
#    - If you see flares:
#      Set APPLY_FILTER="yes"
#      Set RATE_THRESHOLD to your chosen cutoff (e.g., "0.4")
#    - If you see NO flares:
#      Leave APPLY_FILTER="no"
#
# 4. Run the script again. It will now create 'products/[ObsID]/pn/pn_clean.evt'.
#
################################################################################

# --- USER CONFIGURATION - EDIT THIS SECTION ---

# Set to "yes" to apply the filter, "no" to skip it.
APPLY_FILTER="no"

# If APPLY_FILTER="yes", set your count rate cutoff here.
RATE_THRESHOLD="0.4"

# --- END OF CONFIGURATION ---


# Set strict error checking
set -e

echo "--- Starting Background Flare Filtering ---"
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
echo "Looking for input/output files in: ${PN_DIR}"

# --- 1. Find the input EPIC-pn event file ---
# This looks for the calibrated event file created by epproc
echo "Locating PN event file from epproc..."

PN_EVT_FILE=$(find "${PN_DIR}" -name "*EPN*Evts.ds" -type f | head -n 1) 

if [ -z "${PN_EVT_FILE}" ]; then
    echo "ERROR: Could not find the primary PN event file (*EPN*Evts.ds) in ${PN_DIR}"
    echo "Please ensure the 01_setup_and_reprocess.sh script ran correctly for ObsID ${OBSID}."
    exit 1
fi
echo "Found event file: ${PN_EVT_FILE}"

# --- 2. Define output filenames ---

SRC_LC="${PN_DIR}/pn_src_lc.fits"
SRC_LC_PLOT="${PN_DIR}/pn_src_lc.jpg" 
BKG_LC="${PN_DIR}/pn_bkg_lc.fits"
BKG_LC_PLOT="${PN_DIR}/pn_bkg_lc.jpg" 
GTI_FILE="${PN_DIR}/gti_bkg.fits"
CLEAN_EVT_FILE="${PN_DIR}/pn_clean.evt"

# Base SAS filter expression.
# Timing mode specific background filter might differ, check SAS threads.
# Using standard Imaging mode background expression as placeholder:
# For Timing Mode, often use RAWX instead of spatial region, e.g., low RAWX values.
BKG_EXPR="#XMMEA_EP && (PI in [10000:12000]) && (PATTERN==0)" # Placeholder, refine if needed
SRC_EXPR="#XMMEA_EP && (PI in [500:10000]) && (PATTERN<=4)" # Standard source expression

# --- 3. Create Source Lightcurve Plots ---
echo "Creating source lightcurve: ${SRC_LC}"
evselect table="${PN_EVT_FILE}" \
    withrateset=yes rateset="${SRC_LC}" \
    maketimecolumn=yes timebinsize=50 makeratecolumn=yes \
    expression="${SRC_EXPR}"
    
# --- 4. Create Background Lightcurve ---
echo "Creating background lightcurve: ${BKG_LC}"
evselect table="${PN_EVT_FILE}" \
    withrateset=yes rateset="${BKG_LC}" \
    maketimecolumn=yes timebinsize=100 makeratecolumn=yes \
    expression="${BKG_EXPR}"


# --- 4b. Create Plots ---
echo "Changing to ${PN_DIR} to create plots..."
cd "${PN_DIR}" || { echo "Failed to cd into ${PN_DIR}"; exit 1; }

echo "Creating diagnostic plots..."

# Source Lightcurve (Time vs. Rate)
echo "  Generating pn_src_lc.ps..."

fplot "pn_src_lc.fits[RATE]" xparm="TIME" yparm="RATE" mode='h' device="pn_src_lc.ps/PS" </dev/null
convert "pn_src_lc.ps[0]" pn_src_lc.jpg

echo "  Created ${SRC_LC_PLOT}"

# Background Lightcurve (Time vs. Rate)
echo "  Generating pn_bkg_lc.ps..."

fplot "pn_bkg_lc.fits[RATE]" xparm="TIME" yparm="RATE" mode='h' device="pn_bkg_lc.ps/PS" </dev/null
convert "pn_bkg_lc.ps[0]" pn_bkg_lc.jpg

echo "  Created ${BKG_LC_PLOT}"

# Return to the root directory
echo "Plots created. Returning to root directory..."
cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}"; exit 1; }

echo ""
echo "Plots created in ${PN_DIR}. Please inspect background lightcurve: ${BKG_LC_PLOT}"
echo ""
echo "--> Set APPLY_FILTER in this script and re-run. <--"
echo ""

# --- 5. Apply Filter (or not) based on user flag ---

# Base science filter expression (Timing Mode often PI>200 or PI>500)
SCIENCE_EXPR="#XMMEA_EP && (PI>200)" # Adjust PI range if needed for Timing Mode

if [ "${APPLY_FILTER}" == "yes" ]; then
    echo "--- Applying flare filter ---"
    echo "Using count rate threshold: <= ${RATE_THRESHOLD}"

    # 1. Create a Good Time Interval (GTI) file from the background lightcurve
    # Need full path for tabgtigen table parameter
    tabgtigen table="${BKG_LC}" \
        expression="RATE<=${RATE_THRESHOLD}" \
        gtiset="${GTI_FILE}"

    # 2. Create the final clean event file by applying the GTI
    echo "Creating clean event file: ${CLEAN_EVT_FILE}"
    evselect table="${PN_EVT_FILE}" \
        withfilteredset=yes filteredset="${CLEAN_EVT_FILE}" \
        keepfilteroutput=yes \
        expression="${SCIENCE_EXPR} && gti(${GTI_FILE},TIME)" \
        updateexposure=yes

    echo "Filtering complete."

else
    echo "--- Skipping flare filter (APPLY_FILTER=no) ---"
    
    # Create the "clean" file, applying only the base science filter.
    echo "Creating clean event file: ${CLEAN_EVT_FILE}"
    evselect table="${PN_EVT_FILE}" \
        withfilteredset=yes filteredset="${CLEAN_EVT_FILE}" \
        keepfilteroutput=yes \
        expression="${SCIENCE_EXPR}" \
        updateexposure=yes

    echo "File creation complete (no flare filter applied)."
fi

echo "--- Background filtering script finished ---"
