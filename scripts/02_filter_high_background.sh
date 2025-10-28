#!/bin/bash
#
# SCRIPT: 02_filter_background.sh
#
# DESCRIPTION:
# Creates a high-energy background lightcurve 
# Based on user-set variables, it then applies a flare filter (or not)
# to create the final 'pn_clean.evt' file.
#
# USAGE:
# 1. Run this script once from the repository root:
#    ./scripts/02_filter_background.sh
#
# 2. Open the new plots in 'products/pn/':
#    - 'pn_bkg_lc.ps' (the lightcurve)
#    
#
# 3. Based on the plots, edit the "USER CONFIGURATION" section below.
#    - If you see flares:
#      Set APPLY_FILTER="yes"
#      Set RATE_THRESHOLD to your chosen cutoff (e.g., "0.4")
#    - If you see NO flares:
#      Leave APPLY_FILTER="no"
#
# 4. Run the script again. It will now create 'products/pn/pn_clean.evt'.
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
export PN_DIR="products/pn"

# --- 1. Find the input EPIC-pn event file ---
# This looks for the calibrated event file created by epproc
echo "Locating PN event file from epproc..."
PN_EVT_FILE=$(find ${PN_DIR} -name "*EPN*Evts.ds" | head -n 1)

if [ -z "${PN_EVT_FILE}" ]; then
    echo "ERROR: Could not find the primary PN event file in ${PN_DIR}"
    echo "Please run the 01_setup_and_reprocess.sh script first."
    exit 1
fi
echo "Found event file: ${PN_EVT_FILE}"

# --- 2. Define output filenames ---
BKG_LC="${PN_DIR}/pn_bkg_lc.fits"
BKG_LC_PLOT="${PN_DIR}/pn_bkg_lc.png"
GTI_FILE="${PN_DIR}/gti_bkg.fits"
CLEAN_EVT_FILE="${PN_DIR}/pn_clean.evt"

# Base SAS filter expression.
# We filter for high-energy (10-12 keV) single-pixel events
# outside the main field of view (RAWX > 0) to get pure background.
# NOTE: This expression may need to be adjusted for your specific observation mode.
# This one is for standard Full Frame (FF) mode.
BKG_EXPR="#XMMEA_EP && (PI in [10000:12000]) && (PATTERN==0)"

# --- 3. Create Background Lightcurve & Plots ---
echo "Creating background lightcurve: ${BKG_LC}"
evselect table="${PN_EVT_FILE}" \
    withrateset=yes rateset="${BKG_LC}" \
    maketimecolumn=yes timebinsize=200 makeratecolumn=yes \
    expression="${BKG_EXPR}"


# We cd into the directory
echo "Changing to ${PN_DIR} to create plots..."
cd "${PN_DIR}" || { echo "Failed to cd into ${PN_DIR}"; exit 1; }

echo "Creating diagnostic plots (using fplot, .ps, then .png)..."

# ---  Lightcurve (Time vs. Rate) ---

#Save copy of lightcurve as PS file (known error of making two identical plots)
echo "  Generating pn_bkg_lc.ps..."
fplot "pn_bkg_lc.fits[RATE]" xparm="TIME" yparm="RATE" mode='h' device="pn_bkg_lc.ps/PS" </dev/null

convert "pn_bkg_lc.ps[0]" pn_bkg_lc.jpg


#Open light curve in dsplot
dsplot table=pn_bkg_lc.fits x=TIME y=RATE.ERROR &


# Return to the root directory
echo "Plots created. Returning to root directory..."
cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}"; exit 1; }



echo ""
echo "Plots created. Please inspect lightcurve"

echo ""
echo "--> Set APPLY_FILTER in this script and re-run. <--"
echo ""

# --- 4. Apply Filter (or not) based on user flag ---

# This is the base expression for good science events
# We filter out very low energy noise (PI<150)
SCIENCE_EXPR="#XMMEA_EP && (PI>150)"

if [ "${APPLY_FILTER}" == "yes" ]; then
    echo "--- Applying flare filter ---"
    echo "Using count rate threshold: <= ${RATE_THRESHOLD}"

    # 1. Create a Good Time Interval (GTI) file from the lightcurve
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
    
    # We still create the "clean" file, but just apply the base science filter.
    # This ensures that 'pn_clean.evt' ALWAYS exists for the next script.
    echo "Creating clean event file: ${CLEAN_EVT_FILE}"
    evselect table="${PN_EVT_FILE}" \
        withfilteredset=yes filteredset="${CLEAN_EVT_FILE}" \
        keepfilteroutput=yes \
        expression="${SCIENCE_EXPR}" \
        updateexposure=yes

    echo "File creation complete (no flare filter applied)."
fi

echo "--- Background filtering script finished ---"
