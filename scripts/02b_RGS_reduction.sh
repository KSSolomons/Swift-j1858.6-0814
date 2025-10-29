#!/bin/bash
#
# SCRIPT: 05_rgs_reduction.sh
#
# DESCRIPTION:
# Performs post-rgsproc RGS data reduction steps for a specific ObsID:
# 1. (Optional) Creates diagnostic plots (spatial, PI) with region overlays.
# 2. Creates background lightcurves (CCD9, background region) and plots for flare inspection.
# 3. (On second run, IF filtering is requested) Applies GTI filtering and re-runs rgsproc
#    from 'filter' through 'fluxing' stages to produce final filtered spectra/responses.
#    Output files are placed in products/[ObsID]/rgs/
#
# ASSUMES:
# - OBS_DIR_ODF environment variable points to data/[OBSID]
# - Script 01_setup_and_reprocess.sh has been run successfully for the target ObsID.
# - RGS event lists (*EVENLI*.FIT) and source lists (*SRCLI*.FIT) exist
#   in the products/[ObsID]/rgs/ directory.
#
# USAGE:
# 1. (Optional) Set CREATE_DIAGNOSTIC_PLOTS="yes".
# 2. Run the script once: ./scripts/05_rgs_reduction.sh
# 3. Inspect the background lightcurve plots in products/[ObsID]/rgs/plots/.
# 4. Edit this script:
#    - If flares are present: Set APPLY_RGS_FILTER="yes" and adjust RGS_RATE_THRESHOLD.
#    - If no flares: Leave APPLY_RGS_FILTER="no".
# 5. Run the script again. If filtering was selected, it will re-run rgsproc.
#
################################################################################

# --- USER CONFIGURATION - EDIT THIS SECTION ---

# Set to "yes" to create the initial spatial/PI diagnostic plots
CREATE_DIAGNOSTIC_PLOTS="yes"

# Set to "yes" to apply flare filtering, "no" to skip it.
APPLY_RGS_FILTER="no"

# If APPLY_RGS_FILTER="yes", set your count rate cutoff here (e.g., "0.1").
RGS_RATE_THRESHOLD="0.1"

# --- END OF CONFIGURATION ---


# Set strict error checking
set -e

echo "--- Starting RGS Post-Processing ---"
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

export RGS_DIR="products/${OBSID}/rgs"
export PLOT_DIR="${RGS_DIR}/plots"
echo "Looking for input/output files in: ${RGS_DIR}"


# --- FUNCTION DEFINITIONS ---

create_rgs_diag_plots() {
    local rgs_num=$1
    local evt_file_base=$2 # Just the filename, not full path
    local src_file_base=$3 # Just the filename

    if [ -z "${evt_file_base}" ] || [ -z "${src_file_base}" ]; then
        echo "Skipping RGS${rgs_num} diagnostic plots (missing input files)."
        return
    fi

    local spatial_img="rgs${rgs_num}_spatial.fit"
    local pi_img="rgs${rgs_num}_pi.fit"
    local plot_ps="plots/rgs${rgs_num}_diag_regions.ps" # Relative path within RGS_DIR
    local plot_png="plots/rgs${rgs_num}_diag_regions.png" # Relative path within RGS_DIR

    echo "Creating RGS${rgs_num} spatial image..."
    evselect table="${evt_file_base}:EVENTS" \
        imageset="${spatial_img}" withimageset=yes \
        xcolumn='M_LAMBDA' ycolumn='XDSP_CORR'

    echo "Creating RGS${rgs_num} PI image..."
    evselect table="${evt_file_base}:EVENTS" \
        imageset="${pi_img}" withimageset=yes \
        xcolumn='M_LAMBDA' ycolumn='PI' \
        yimagemin=0 yimagemax=3000 \
        expression="REGION(${src_file_base}:RGS${rgs_num}_SRC1_SPATIAL,M_LAMBDA,XDSP_CORR)"

    echo "Generating RGS${rgs_num} region overlay plot..."
    rm -f "${plot_ps}" # Remove old plot if exists
    rgsimplot endispset="${pi_img}" spatialset="${spatial_img}" \
        srcidlist='1' srclistset="${src_file_base}" \
        plotfile="${plot_ps}" \
        device="/CPS" </dev/null

    convert "${plot_ps}[0]" "${plot_png}"
    
    echo " -> ${plot_png}"
}

create_rgs_bkg_lc() {
    local rgs_num=$1
    local evt_file_base=$2 # Just the filename
    local src_file_base=$3 # Just the filename for the REGION expression
    local lc_fits="rgs${rgs_num}_bkg_lc.fits"
    local lc_ps="plots/rgs${rgs_num}_bkg_lc.ps"     # Relative path within RGS_DIR
    local lc_png="plots/rgs${rgs_num}_bkg_lc.png"   # Relative path within RGS_DIR

    if [ -z "${evt_file_base}" ] || [ -z "${src_file_base}" ]; then
        echo "Skipping RGS${rgs_num} background lightcurve (missing event or source file)."
        return
    fi

    # Correct expression including background region filter
    local bkg_expr="(CCDNR==9)&&(REGION(${src_file_base}:RGS${rgs_num}_BACKGROUND,M_LAMBDA,XDSP_CORR))"

    echo "Creating RGS${rgs_num} background lightcurve (${lc_fits})..."
    evselect table="${evt_file_base}" \
        withrateset=yes rateset="${lc_fits}" \
        maketimecolumn=yes timebinsize=100 makeratecolumn=yes \
        expression="${bkg_expr}"

    echo "Generating RGS${rgs_num} background lightcurve plot..."
    rm -f "${lc_ps}" # Remove old plot if exists
    fplot "${lc_fits}[RATE]" xparm="TIME" yparm="RATE" \
        device="${lc_ps}/CPS" mode="h" </dev/null

    convert "${lc_ps}[0]" "${lc_png}"
    
    echo " -> ${lc_png}"
}

generate_gti() {
    local rgs_num=$1
    local lc_fits="rgs${rgs_num}_bkg_lc.fits"
    local gti_fits="gti_rgs${rgs_num}.fits" # Created within RGS_DIR

    if [ ! -f "${lc_fits}" ]; then
        echo "Skipping GTI generation for RGS${rgs_num} (missing lightcurve file)."
        return "" # Return empty string
    fi

    echo "Generating GTI for RGS${rgs_num}: ${gti_fits}"
    tabgtigen table="${lc_fits}" expression="RATE<=${RGS_RATE_THRESHOLD}" gtiset="${gti_fits}"

    echo "${gti_fits}" # Return the filename
}

run_rgsproc_filter() {
    local rgs_num=$1
    local gti_file=$2 # Can be empty if no filter
    local log_file="rgsproc_filter_rgs${rgs_num}.log" # Created within RGS_DIR

    # Need to check if the instrument exists based on initial file finding
    local evt_exists_flag=""
    # Check against the global variables RGS1_EVT_FILE/RGS2_EVT_FILE
    if [ "${rgs_num}" == "1" ] && [ ! -z "${RGS1_EVT_FILE}" ]; then evt_exists_flag="yes"; fi
    if [ "${rgs_num}" == "2" ] && [ ! -z "${RGS2_EVT_FILE}" ]; then evt_exists_flag="yes"; fi

    if [ -z "${evt_exists_flag}" ]; then
      echo "Skipping rgsproc run for RGS${rgs_num} (no event file found earlier)."
      return
    fi

    echo "Running rgsproc for RGS${rgs_num}..."
    local other_rgs=$((3-rgs_num)) # Determine the *other* RGS number (1 or 2)

    if [ -z "${gti_file}" ]; then
        # This case should ideally not happen if APPLY_RGS_FILTER is 'yes', but handle it
        echo " (Warning: Filtering requested but no GTI file provided)"
        rgsproc entrystage=3:filter finalstage=5:fluxing orders='1 2' \
                excludeexp='R?S000' RGS${rgs_num}=yes RGS${other_rgs}=no >& "${log_file}"
    else
        echo " (Using GTI file: ${gti_file})"
        # Run with GTI
        rgsproc entrystage=3:filter finalstage=5:fluxing orders='1 2' \
                auxgtitables="${gti_file}" excludeexp='R?S000' \
                RGS${rgs_num}=yes RGS${other_rgs}=no >& "${log_file}"
    fi
    echo " -> Log file: ${log_file}"
}

# --- END OF FUNCTION DEFINITIONS ---


# --- 1. Create Plot Directory ---
mkdir -p "${PLOT_DIR}"

# --- 2. Find RGS Files ---
echo "Locating RGS files from initial rgsproc run in ${RGS_DIR}..."

RGS1_EVT_FILE=$(find "${RGS_DIR}" -maxdepth 1 -name "*R1S*EVENLI*.FIT" -type f | head -n 1)
RGS2_EVT_FILE=$(find "${RGS_DIR}" -maxdepth 1 -name "*R2S*EVENLI*.FIT" -type f | head -n 1)
RGS1_SRC_FILE=$(find "${RGS_DIR}" -maxdepth 1 -name "*R1S*SRCLI*.FIT" -type f | head -n 1)
RGS2_SRC_FILE=$(find "${RGS_DIR}" -maxdepth 1 -name "*R2S*SRCLI*.FIT" -type f | head -n 1)

# Check if essential files exist
if [ -z "${RGS1_EVT_FILE}${RGS2_EVT_FILE}" ]; then
    echo "ERROR: No RGS event lists (*EVENLI*.FIT) found in ${RGS_DIR}. Did script 01 run correctly for ObsID ${OBSID}?"
    exit 1
fi
if [ -z "${RGS1_SRC_FILE}${RGS2_SRC_FILE}" ]; then
    echo "ERROR: No RGS source lists (*SRCLI*.FIT) found in ${RGS_DIR}. Did script 01 run correctly for ObsID ${OBSID}?"
    exit 1
fi

echo "Found Files:"
[ ! -z "${RGS1_EVT_FILE}" ] && echo " RGS1 Event: $(basename "${RGS1_EVT_FILE}")"
[ ! -z "${RGS2_EVT_FILE}" ] && echo " RGS2 Event: $(basename "${RGS2_EVT_FILE}")"
[ ! -z "${RGS1_SRC_FILE}" ] && echo " RGS1 Source: $(basename "${RGS1_SRC_FILE}")"
[ ! -z "${RGS2_SRC_FILE}" ] && echo " RGS2 Source: $(basename "${RGS2_SRC_FILE}")"


# --- 3. Create Diagnostic Plots (Optional) ---
if [ "${CREATE_DIAGNOSTIC_PLOTS}" == "yes" ]; then
    echo "--- Creating Diagnostic Plots ---"
    cd "${RGS_DIR}" || { echo "Failed to cd into ${RGS_DIR}"; exit 1; }
    # Call the function
    create_rgs_diag_plots 1 "$(basename "${RGS1_EVT_FILE}")" "$(basename "${RGS1_SRC_FILE}")"
    create_rgs_diag_plots 2 "$(basename "${RGS2_EVT_FILE}")" "$(basename "${RGS2_SRC_FILE}")"
    cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}"; exit 1; }
    echo "Diagnostic plots created (if applicable) in ${PLOT_DIR}"
fi

# --- 4. Create Background Lightcurves and Plots ---
echo "--- Creating Background Lightcurves (CCD9 & Background Region) ---"
cd "${RGS_DIR}" || { echo "Failed to cd into ${RGS_DIR}"; exit 1; }
# Call the function
create_rgs_bkg_lc 1 "$(basename "${RGS1_EVT_FILE}")" "$(basename "${RGS1_SRC_FILE}")"
create_rgs_bkg_lc 2 "$(basename "${RGS2_EVT_FILE}")" "$(basename "${RGS2_SRC_FILE}")"
cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}"; exit 1; }

echo ""
echo "Background lightcurve plots created in ${PLOT_DIR}"
echo "--> Inspect plots, edit APPLY_RGS_FILTER/RGS_RATE_THRESHOLD in this script, and re-run. <--"
echo ""


# --- 5. Apply Filter and Re-run rgsproc (Conditional) ---
if [ "${APPLY_RGS_FILTER}" == "yes" ]; then
    echo "--- Applying Flare Filter & Re-running rgsproc ---"
    echo "Using count rate threshold: <= ${RGS_RATE_THRESHOLD}"

    GTI1_FILE=""
    GTI2_FILE=""

    cd "${RGS_DIR}" || { echo "Failed to cd into ${RGS_DIR}"; exit 1; }

    # Call the function
    GTI1_FILE=$(generate_gti 1)
    GTI2_FILE=$(generate_gti 2)

    if [ -z "${GTI1_FILE}" ] && [ -z "${GTI2_FILE}" ]; then
      echo "WARNING: Filtering requested, but no valid GTI files could be generated. Skipping rgsproc."
    else
      # Call the function
      run_rgsproc_filter 1 "${GTI1_FILE}"
      run_rgsproc_filter 2 "${GTI2_FILE}"
    fi

    cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}"; exit 1; }

else
    echo "--- Skipping Flare Filter (APPLY_RGS_FILTER=no). No rgsproc re-run needed. ---"
fi


# --- 6. Completion ---
echo "--------------------------------------------------"
echo "RGS processing script finished for ObsID ${OBSID}."
if [ "${APPLY_RGS_FILTER}" == "yes" ]; then
    echo "Check log files in ${RGS_DIR} for details of the rgsproc re-run."
    echo "Final filtered spectra and response files are located in ${RGS_DIR}"
else
    echo "No filtering applied. Products from initial rgsproc run in ${RGS_DIR} are final."
fi
echo "--------------------------------------------------"
