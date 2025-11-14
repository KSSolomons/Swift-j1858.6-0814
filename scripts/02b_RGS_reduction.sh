#!/bin/bash
#
# SCRIPT: 02b_rgs_reduction.sh
#
# DESCRIPTION:
# Performs post-rgsproc RGS data reduction steps for a specific ObsID:
# 1. (Optional) Creates diagnostic plots (spatial, PI) with region overlays.
# 2. Creates individual RGS1/RGS2 raw source lightcurves.
# 3. Creates a final, combined/corrected source lightcurve using 'rgslccorr'.
# 4. Creates background lightcurves (CCD9, background region) and plots for flare inspection.
# 5. (On second run, IF filtering is requested) Applies GTI filtering by re-running
#    'rgsproc entrystage=3:filter' with the new GTI files.
#
# ASSUMES:
# - $PROJECT_ROOT, $OBSID environment variables are set.
# - Script 01_setup_and_reprocess.sh has been run successfully.
# - RGS *EVENLI*.FIT, *SRCLI*.FIT, and *MERGED*.FIT files exist.
#
################################################################################

# --- USER CONFIGURATION - EDIT THIS SECTION ---

# Set to "yes" to create the initial spatial/PI diagnostic plots
CREATE_DIAGNOSTIC_PLOTS="yes"

# --- RGS Source Lightcurve (rgslccorr) ---
LC_BIN_SIZE="100"
RGS_SOURCE_ID="1"

# --- RGS Flare Filtering ---
FILTER_RGS1="yes"
FILTER_RGS2="yes"
RGS_RATE_THRESHOLD="0.12"

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

# Define paths from root
export OBS_DIR_ODF="${PROJECT_ROOT}/data/${OBSID}"
export RGS_DIR="${PROJECT_ROOT}/products/${OBSID}/rgs"
export PLOT_DIR="${RGS_DIR}/plots"
export RGS_FILT="${RGS_DIR}/filt"
export PROC_DIR="${PROJECT_ROOT}" # Use this, not pwd

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

# Set strict error checking
set -e

echo "--- Starting RGS Post-Processing ---"
echo "Using ObsID: ${OBSID}"
echo "Looking for input/output files in: ${RGS_DIR}"

# --- FUNCTION DEFINITIONS ---
# (Redirect status 'echo' to stderr >&2)

create_rgs_diag_plots() {
    local rgs_num=$1
    local evt_file_base=$2 # Just the filename, not full path
    local src_file_base=$3 # Just the filename

    if [ -z "${evt_file_base}" ] || [ -z "${src_file_base}" ]; then
        echo "Skipping RGS${rgs_num} diagnostic plots (missing input files)." >&2
        return
    fi

    local spatial_img="rgs${rgs_num}_spatial.fit"
    local pi_img="rgs${rgs_num}_pi.fit"
    local plot_ps="plots/rgs${rgs_num}_diag_regions.ps" # Relative path within RGS_DIR
    local plot_png="plots/rgs${rgs_num}_diag_regions.png" # Relative path within RGS_DIR

    echo "Creating RGS${rgs_num} spatial image..." >&2
    evselect table="${evt_file_base}:EVENTS" \
        imageset="${spatial_img}" withimageset=yes \
        xcolumn='M_LAMBDA' ycolumn='XDSP_CORR' > /dev/null

    echo "Creating RGS${rgs_num} PI image..." >&2
    evselect table="${evt_file_base}:EVENTS" \
        imageset="${pi_img}" withimageset=yes \
        xcolumn='M_LAMBDA' ycolumn='PI' \
        yimagemin=0 yimagemax=3000 \
        expression="REGION(${src_file_base}:RGS${rgs_num}_SRC1_SPATIAL,M_LAMBDA,XDSP_CORR)" > /dev/null

    echo "Generating RGS${rgs_num} region overlay plot..." >&2
    rm -f "${plot_ps}" # Remove old plot if exists
    rgsimplot endispset="${pi_img}" spatialset="${spatial_img}" \
        srcidlist='1' srclistset="${src_file_base}" \
        plotfile="${plot_ps}" \
        device="/CPS" </dev/null

    convert -density 300 "${plot_ps}[0]" "${plot_png}"
    rm -f "${plot_ps}" # Cleanup
    
    echo " -> ${plot_png}" >&2
}

create_rgs_bkg_lc() {
    local rgs_num=$1
    local evt_file_base=$2 # Just the filename
    local src_file_base=$3 # Just the filename for the REGION expression
    local lc_fits="rgs${rgs_num}_bkg_lc.fits"
    local lc_ps="plots/rgs${rgs_num}_bkg_lc.ps"     # Relative path within RGS_DIR
    local lc_png="plots/rgs${rgs_num}_bkg_lc.png"    # Relative path within RGS_DIR

    if [ -z "${evt_file_base}" ] || [ -z "${src_file_base}" ]; then
        echo "Skipping RGS${rgs_num} background lightcurve (missing event or source file)." >&2
        return
    fi

    local bkg_expr="(CCDNR==9)&&(REGION(${src_file_base}:RGS${rgs_num}_BACKGROUND,M_LAMBDA,XDSP_CORR))"

    echo "Creating RGS${rgs_num} background lightcurve (${lc_fits})..." >&2
    evselect table="${evt_file_base}" \
        withrateset=yes rateset="${lc_fits}" \
        maketimecolumn=yes timebinsize=100 makeratecolumn=yes \
        expression="${bkg_expr}" > /dev/null

    echo "Generating RGS${rgs_num} background lightcurve plot..." >&2
    
    fplot "${lc_fits}[RATE]" xparm="TIME" yparm="RATE" \
        device="${lc_ps}/CPS" mode="h" </dev/null

    convert -density 300 "${lc_ps}[0]" "${lc_png}"
    
    
    echo " -> ${lc_png}" >&2
}

generate_gti() {
    local rgs_num=$1
    local lc_fits="rgs${rgs_num}_bkg_lc.fits"
    local gti_fits="gti_rgs${rgs_num}.fits" # Created within RGS_DIR

    if [ ! -f "${lc_fits}" ]; then
        echo "Skipping GTI generation for RGS${rgs_num} (missing lightcurve file)." >&2
        return "" # Return empty string
    fi

    echo "Generating GTI for RGS${rgs_num}: ${gti_fits}" >&2
    
    # Redirect stdout of tabgtigen to /dev/null so it doesn't get captured
    tabgtigen table="${lc_fits}" expression="RATE<=${RGS_RATE_THRESHOLD}" gtiset="${gti_fits}" > /dev/null

    echo "${gti_fits}" # This is the ONLY output to stdout
}


run_rgsproc_filter() {
    # These parameters are now JUST the basenames (e.g., "gti_rgs1.fits")
    local gti1_base=$1 
    local gti2_base=$2
    
    # This log file will be created inside the new 'filt' directory
    local log_file="rgsproc_filter.log" 
    
    # [FIX 1] Create the 'filt' dir and cd into it.
    # This function now assumes it's being run from RGS_DIR.
    mkdir -p "filt"
    cd "filt" || { echo "Failed to cd into filt"; return 1; }
    echo "Changed directory to $(pwd)" >&2

    # cp to new directory
    
    cp -f ../*SRCLI*.FIT .
    cp -f ../*merged*.FIT .
    
    if [ -n "${gti1_base}" ]; then
        echo "Copying ${gti1_base}..." >&2
        cp -f ../${gti1_base} .
    fi
    
    if [ -n "${gti2_base}" ]; then
        echo "Copying ${gti2_base}..." >&2
        cp -f ../${gti2_base} .
    fi
    
    
    # Build a comma-separated list of RELATIVE paths
    local gti_paths_relative=""
    if [ -n "${gti1_base}" ]; then
        gti_paths_relative="${gti1_base}"
    fi
    if [ -n "${gti2_base}" ]; then
        if [ -n "${gti_paths_relative}" ]; then
            gti_paths_relative="${gti_paths_relative} ${gti2_base}"
        else
            gti_paths_relative="${gti2_base}"
        fi
    fi

    if [ -z "${gti_paths_relative}" ]; then
         echo "WARNING: Filtering requested but no valid GTI files provided. Skipping rgsproc." >&2
         cd .. # Go back up
         return
    fi
    
    echo "Running rgsproc entrystage=3:filter with relative GTI list: ${gti_paths_relative}" >&2
    
    # [FIX 4] Call rgsproc with the quoted, relative path list.
    # It will run inside 'filt' and write all new products here.
    rgsproc entrystage=3:filter finalstage=5:fluxing orders='1 2'\
            auxgtitables="${gti_paths_relative}" > "${log_file}" 2>&1

    echo " -> Log file: ${log_file}" >&2
    
    # Go back up to RGS_DIR
    cd ..
    echo "Changed directory back to $(pwd)" >&2
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
RGS1_MERGED_FILE=$(find "${RGS_DIR}" -maxdepth 1 -name "*R1S*merged*.FIT" -type f | head -n 1)
RGS2_MERGED_FILE=$(find "${RGS_DIR}" -maxdepth 1 -name "*R2S*merged*.FIT" -type f | head -n 1)


# Check if essential files exist
if [ -z "${RGS1_EVT_FILE}${RGS2_EVT_FILE}" ]; then
    echo "ERROR: No RGS event lists (*EVENLI*.FIT) found in ${RGS_DIR}. Did script 01 run correctly for ObsID ${OBSID}?"
    exit 1
fi
if [ -z "${RGS1_SRC_FILE}${RGS2_SRC_FILE}" ]; then
    echo "ERROR: No RGS source lists (*SRCLI*.FIT) found in ${RGS_DIR}. Did script 01 run correctly for ObsID ${OBSID}?"
    exit 1
fi
# Check for merged files, which are CRITICAL for filtering
if [ -z "${RGS1_MERGED_FILE}${RGS2_MERGED_FILE}" ]; then
    echo "ERROR: No RGS merged lists (*MERGED*.FIT) found in ${RGS_DIR}. Did script 01 run correctly for ObsID ${OBSID}?"
    exit 1
fi


echo "Found Files:"
[ ! -z "${RGS1_EVT_FILE}" ] && echo " RGS1 Event: $(basename "${RGS1_EVT_FILE}")"
[ ! -z "${RGS2_EVT_FILE}" ] && echo " RGS2 Event: $(basename "${RGS2_EVT_FILE}")"
[ ! -z "${RGS1_SRC_FILE}" ] && echo " RGS1 Source: $(basename "${RGS1_SRC_FILE}")"
[ ! -z "${RGS2_SRC_FILE}" ] && echo " RGS2 Source: $(basename "${RGS2_SRC_FILE}")"
[ ! -z "${RGS1_MERGED_FILE}" ] && echo " RGS1 Merged: $(basename "${RGS1_MERGED_FILE}")"
[ ! -z "${RGS2_MERGED_FILE}" ] && echo " RGS2 Merged: $(basename "${RGS2_MERGED_FILE}")"


# --- 3. Create Diagnostic Plots (Optional) ---
if [ "${CREATE_DIAGNOSTIC_PLOTS}" == "yes" ]; then
    echo "--- Creating Diagnostic Plots ---"
    cd "${RGS_DIR}" || { echo "Failed to cd into ${RGS_DIR}"; exit 1; }
    
    create_rgs_diag_plots 1 "$(basename "${RGS1_EVT_FILE}")" "$(basename "${RGS1_SRC_FILE}")"
    create_rgs_diag_plots 2 "$(basename "${RGS2_EVT_FILE}")" "$(basename "${RGS2_SRC_FILE}")"
    
    cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}"; exit 1; }
    echo "Diagnostic plots created (if applicable) in ${PLOT_DIR}"
fi

# --- 4. Create Source Lightcurves (COMBINED AND INDIVIDUAL) ---
echo "--- Creating Source Lightcurves ---"
EV_LIST=""
SRC_LIST=""
[ -n "${RGS1_EVT_FILE}" ] && EV_LIST="${EV_LIST} ${RGS1_EVT_FILE}"
[ -n "${RGS2_EVT_FILE}" ] && EV_LIST="${EV_LIST} ${RGS2_EVT_FILE}"
[ -n "${RGS1_SRC_FILE}" ] && SRC_LIST="${SRC_LIST} ${RGS1_SRC_FILE}"
[ -n "${RGS2_SRC_FILE}" ] && SRC_LIST="${SRC_LIST} ${RGS2_SRC_FILE}"
EV_LIST=$(echo ${EV_LIST}) # Trim leading space
SRC_LIST=$(echo ${SRC_LIST}) # Trim leading space

# Define all filenames
LC_OUT_FILE="rgs_source_lc_corrected.fits"
LC_PLOT_PS="plots/rgs_source_lc_corrected.ps"
LC_PLOT_PNG="plots/rgs_source_lc_corrected.png"

LC1_RAW_FILE="rgs1_source_lc_raw.fits"
LC1_PLOT_PS="plots/rgs1_source_lc_raw.ps"
LC1_PLOT_PNG="plots/rgs1_source_lc_raw.png"
LC2_RAW_FILE="rgs2_source_lc_raw.fits"
LC2_PLOT_PS="plots/rgs2_source_lc_raw.ps"
LC2_PLOT_PNG="plots/rgs2_source_lc_raw.png"

cd "${RGS_DIR}" || { echo "Failed to cd into ${RGS_DIR}"; exit 1; }

# --- 4a. Individual RGS1 Raw Lightcurve ---
if [ -n "${RGS1_EVT_FILE}" ]; then
    echo "Creating RGS1 raw source lightcurve..." >&2
    RGS1_EVT_BASE=$(basename "${RGS1_EVT_FILE}")
    RGS1_SRC_BASE=$(basename "${RGS1_SRC_FILE}")
    SRC_EXPR_1="REGION(${RGS1_SRC_BASE}:RGS1_SRC1_SPATIAL,M_LAMBDA,XDSP_CORR)"
    
    evselect table="${RGS1_EVT_BASE}" \
        withrateset=yes rateset="${LC1_RAW_FILE}" \
        maketimecolumn=yes timebinsize=${LC_BIN_SIZE} makeratecolumn=yes \
        expression="${SRC_EXPR_1}" > /dev/null
        
    echo "Plotting RGS1 raw source lightcurve..." >&2
    fplot "${LC1_RAW_FILE}[RATE]" xparm="TIME" yparm="RATE" \
        device="${LC1_PLOT_PS}/CPS" mode="h" </dev/null
    convert -density 300 "${LC1_PLOT_PS}[0]" "${LC1_PLOT_PNG}"
    rm -f "${LC1_PLOT_PS}" # Cleanup
fi

# --- 4b. Individual RGS2 Raw Lightcurve ---
if [ -n "${RGS2_EVT_FILE}" ]; then
    echo "Creating RGS2 raw source lightcurve..." >&2
    RGS2_EVT_BASE=$(basename "${RGS2_EVT_FILE}")
    RGS2_SRC_BASE=$(basename "${RGS2_SRC_FILE}")
    SRC_EXPR_2="REGION(${RGS2_SRC_BASE}:RGS2_SRC1_SPATIAL,M_LAMBDA,XDSP_CORR)"
    
    evselect table="${RGS2_EVT_BASE}" \
        withrateset=yes rateset="${LC2_RAW_FILE}" \
        maketimecolumn=yes timebinsize=${LC_BIN_SIZE} makeratecolumn=yes \
        expression="${SRC_EXPR_2}" > /dev/null
        
    echo "Plotting RGS2 raw source lightcurve..." >&2
    fplot "${LC2_RAW_FILE}[RATE]" xparm="TIME" yparm="RATE" \
        device="${LC2_PLOT_PS}/CPS" mode="h" </dev/null
    convert -density 300 "${LC2_PLOT_PS}[0]" "${LC2_PLOT_PNG}"
    rm -f "${LC2_PLOT_PS}" # Cleanup
fi

# --- 4c. Combined Corrected Lightcurve (rgslccorr) ---
echo "Running rgslccorr for combined corrected lightcurve..." >&2
rgslccorr evlist="${EV_LIST}" \
    srclist="${SRC_LIST}" \
    timebinsize=${LC_BIN_SIZE} \
    orders='1 2' \
    sourceid=${RGS_SOURCE_ID} \
    outputsrcfilename="${LC_OUT_FILE}"

echo "Plotting combined corrected RGS lightcurve..." >&2
fplot "${LC_OUT_FILE}[RATE]" xparm="TIME" yparm="RATE" \
    device="${LC_PLOT_PS}/CPS" mode="h" </dev/null
convert -density 300 "${LC_PLOT_PS}[0]" "${LC_PLOT_PNG}"
rm -f "${LC_PLOT_PS}" # Cleanup


# --- End of lightcurve section ---
cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}"; exit 1; }
echo " -> All source lightcurves created in ${RGS_DIR} and ${PLOT_DIR}"


# --- 5. Create Background Lightcurves and Plots (for Filtering) ---
echo "--- Creating Background Lightcurves (CCD9 & Background Region) ---"
cd "${RGS_DIR}" || { echo "Failed to cd into ${RGS_DIR}"; exit 1; }

create_rgs_bkg_lc 1 "$(basename "${RGS1_EVT_FILE}")" "$(basename "${RGS1_SRC_FILE}")"
create_rgs_bkg_lc 2 "$(basename "${RGS2_EVT_FILE}")" "$(basename "${RGS2_SRC_FILE}")"

cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}"; exit 1; }

echo ""
echo "Background lightcurve plots created in ${PLOT_DIR}"
echo "--> Inspect plots, edit FILTER_RGS1/FILTER_RGS2 in this script, and re-run. <--"
echo ""
	
# --- 6. Apply Filter and Re-run rgsproc (Conditional) ---
if [ "${FILTER_RGS1}" == "yes" ] || [ "${FILTER_RGS2}" == "yes" ]; then
    echo "--- Applying Flare Filter & Re-running rgsproc ---"
    echo "Using count rate threshold: <= ${RGS_RATE_THRESHOLD}"

    # [FIX] Change to RGS_DIR first. All work will be relative to here.
    cd "${RGS_DIR}" || { echo "Failed to cd into ${RGS_DIR}"; exit 1; }
    echo "Changed directory to $(pwd)" >&2
    
    GTI1_FILE=""
    GTI2_FILE=""

    if [ "${FILTER_RGS1}" == "yes" ]; then
        # This function now runs in RGS_DIR and creates gti_rgs1.fits here
        GTI1_FILE=$(generate_gti 1) 
    fi
    
    if [ "${FILTER_RGS2}" == "yes" ]; then
        # This function now runs in RGS_DIR and creates gti_rgs2.fits here
        GTI2_FILE=$(generate_gti 2)
    fi
    
    # [FIX] Call the filter function, passing ONLY the filenames.
    # The function itself will handle creating /filt, symlinking, and cd'ing.
    run_rgsproc_filter "${GTI1_FILE}" "${GTI2_FILE}"

    # Return to the main project directory
    cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}"; exit 1; }
    echo "Changed directory back to $(pwd)" >&2

else
    echo "--- Skipping Flare Filter (FILTER_RGS1/2=no). No rgsproc re-run needed. ---"
fi


# --- 7. Completion ---
echo "--------------------------------------------------"
echo "RGS processing script finished for ObsID ${OBSID}."
echo ""
echo "Plots created in: ${PLOT_DIR}"
[ -f "${PLOT_DIR}/${LC1_PLOT_PNG}" ] && echo "  - ${LC1_PLOT_PNG}"
[ -f "${PLOT_DIR}/${LC2_PLOT_PNG}" ] && echo "  - ${LC2_PLOT_PNG}"
[ -f "${PLOT_DIR}/${LC_PLOT_PNG}" ] && echo "  - ${LC_PLOT_PNG}"
echo ""
if [ "${FILTER_RGS1}" == "yes" ] || [ "${FILTER_RGS2}" == "yes" ]; then
    echo "Check log files in ${RGS_DIR} for details of the rgsproc re-run."
    echo "Final filtered spectra and response files are located in ${RGS_DIR}"
else
    echo "No filtering applied. Products from initial rgsproc run in ${RGS_DIR} are final."
fi
echo "--------------------------------------------------"
