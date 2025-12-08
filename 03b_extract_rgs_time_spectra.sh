#!/bin/bash
#
# SCRIPT: 03b_extract_rgs_time_spectra.sh
#
# DESCRIPTION:
# Extracts multiple TIME-FILTERED RGS spectra using the efficient
# 'entrystage=3:filter' method.
#
# WORKFLOW:
# 1. Finds existing flare-GTI files (e.g., gti_rgs1.fits) from script 02b.
# 2. Finds the main RGS files (*EVENLI*.FIT, *SRCLI*.FIT, *MERGED*.FIT)
#    created by script 01.
# 3. Loops through each user-defined time interval ("Persistent", "Dipping", etc.).
# 4. For each interval:
#    a. Creates the output directory (e.g., 'spec/Persistent') and CDs into it.
#    b. Copies the necessary *SRCLI*.FIT and *MERGED*.FIT files from the
#       main RGS_DIR into the current (e.g., 'Persistent') directory.
#    c. Creates a temporary *interval* GTI (e.g., temp_gti_persistent.fits)
#       using 'tabgtigen' on the main event list.
#    d. Builds a combined list of ALL GTIs (flare-GTIs + interval-GTIs).
#    e. Runs 'rgsproc entrystage=3:filter ...', which reads the files
#       in the current directory and applies all GTIs.
#    f. Cleans up temporary files and CDs back up.
#
################################################################################

# --- TIME FILTER CONFIGURATION - EDIT THIS SECTION ---

TIME_FILTERS=(
    "(TIME >= 701592768.492053) &&! (TIME IN [701596278.492053:701625198.492053]) &&! (TIME IN [701628548.492053:701632768.492053]) &&! (TIME IN [701625198.492053:701628548.492053]) &&! (TIME IN [701632768.492053:701642768.492053]) &&! (TIME IN [701658528.492053:701675918.492053])"
    "(TIME IN [701596278.492053:701625198.492053])"
    "(TIME >= 701592768.492053) &&! (TIME IN [701596278.492053:701625198.492053]) &&! (TIME IN [701628548.492053:701632768.492053]) &&! (TIME IN [701592818.492053:701596278.492053]) &&! (TIME IN [701642768.492053:701658528.492053])"
    
)

OUTPUT_SUFFIXES=(
    "Persistent"
    "Dipping"
    "Shallow"
)

# --- END TIME FILTER ---


# --- STANDARD RGS CONFIGURATION ---
RGS_ORDERS="1 2" # Which spectral orders to extract
# --- END STANDARD CONFIG ---


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
export RGS_DIR="${PROJECT_ROOT}/products/${OBSID}/rgs"
export SPEC_DIR="${PROJECT_ROOT}/products/${OBSID}/rgs/time_intervals"
export PROC_DIR="${PROJECT_ROOT}"

if [ ! -d "${OBS_DIR_ODF}" ]; then
    echo "ERROR: ODF directory not found: ${OBS_DIR_ODF}"
    exit 1
fi
echo "Using ODF from: ${OBS_DIR_ODF}"

# --- Re-establish SAS Setup Variables ---
ODF_DIR_CLEAN=$(echo "${OBS_DIR_ODF}" | sed 's:/*$::')
CCF_FILE="${ODF_DIR_CLEAN}/ccf.cif"
SUMMARY_FILE_NAME=$(find "${ODF_DIR_CLEAN}" -maxdepth 1 -name "*SUM.SAS" -printf "%f\n" | head -n 1)
if [ -z "${SUMMARY_FILE_NAME}" ]; then echo "ERROR: Cannot find *SUM.SAS file in ${ODF_DIR_CLEAN}"; exit 1; fi
SUMMARY_FILE="${ODF_DIR_CLEAN}/${SUMMARY_FILE_NAME}"
if [ ! -f "${CCF_FILE}" ]; then echo "ERROR: Cannot find CCF file: ${CCF_FILE}"; exit 1; fi
if [ ! -f "${SUMMARY_FILE}" ]; then echo "ERROR: Cannot find Summary file: ${SUMMARY_FILE}"; exit 1; fi
export SAS_CCF="${CCF_FILE}"
export SAS_ODF="${SUMMARY_FILE}"
echo "SAS_CCF re-established: $(basename "${SAS_CCF}")"
echo "SAS_ODF re-established: $(basename "${SAS_ODF}")"
# --- End Re-establish ---

set -e
echo "--- Starting RGS Multi-Interval Spectral Extraction (Filter Stage) ---"

# --- Define Directories ---
mkdir -p "${SPEC_DIR}"

# --- 2. Locate Flare GTI files (from script 02b) ---
FLARE_GTI1_PATH="${RGS_DIR}/gti_rgs1.fits"
FLARE_GTI2_PATH="${RGS_DIR}/gti_rgs2.fits"
FLARE_GTI_LIST=""

if [ -f "${FLARE_GTI1_PATH}" ]; then
    echo "Found RGS1 flare GTI: $(basename "${FLARE_GTI1_PATH}")"
    FLARE_GTI_LIST="${FLARE_GTI1_PATH}" # Full path
fi
if [ -f "${FLARE_GTI2_PATH}" ]; then
    echo "Found RGS2 flare GTI: $(basename "${FLARE_GTI2_PATH}")"
    FLARE_GTI_LIST="${FLARE_GTI_LIST} ${FLARE_GTI2_PATH}" # Full path
fi
if [ -n "${FLARE_GTI_LIST}" ]; then
    echo "Will apply the following flare GTIs to all intervals."
else
    echo "WARNING: No flare GTI files (gti_rgs*.fits) found. Proceeding without flare filtering."
fi
FLARE_GTI_LIST=$(echo ${FLARE_GTI_LIST}) # Trim spaces

# --- 3. Locate RGS Input Files (from script 01) ---
# We need these to copy into each sub-directory
RGS1_EVT_FILE=$(find "${RGS_DIR}" -maxdepth 1 -name "*R1S*EVENLI*.FIT" -type f | head -n 1)
RGS2_EVT_FILE=$(find "${RGS_DIR}" -maxdepth 1 -name "*R2S*EVENLI*.FIT" -type f | head -n 1)
RGS1_SRC_FILE=$(find "${RGS_DIR}" -maxdepth 1 -name "*R1S*SRCLI*.FIT" -type f | head -n 1)
RGS2_SRC_FILE=$(find "${RGS_DIR}" -maxdepth 1 -name "*R2S*SRCLI*.FIT" -type f | head -n 1)
RGS1_MERGED_FILE=$(find "${RGS_DIR}" -maxdepth 1 -name "*R1S*merged*.FIT" -type f | head -n 1)
RGS2_MERGED_FILE=$(find "${RGS_DIR}" -maxdepth 1 -name "*R2S*merged*.FIT" -type f | head -n 1)

if [ -z "${RGS1_EVT_FILE}${RGS2_EVT_FILE}" ]; then
    echo "ERROR: No RGS event lists (*EVENLI*.FIT) found in ${RGS_DIR}. Cannot run tabgtigen."
    exit 1
fi
if [ -z "${RGS1_SRC_FILE}${RGS2_SRC_FILE}" ]; then
    echo "ERROR: No RGS source lists (*SRCLI*.FIT) found in ${RGS_DIR}. Cannot run rgsproc."
    exit 1
fi
echo "Found all necessary RGS input files."
echo "---"


# --- 4. Validate Configuration ---
if [ ${#TIME_FILTERS[@]} -ne ${#OUTPUT_SUFFIXES[@]} ]; then
    echo "ERROR: The number of TIME_FILTERS (${#TIME_FILTERS[@]})"
    echo "does not match the number of OUTPUT_SUFFIXES (${#OUTPUT_SUFFIXES[@]})."
    exit 1
fi
if [ ${#TIME_FILTERS[@]} -eq 0 ]; then echo "WARNING: No time filters defined. Nothing to do."; exit 0; fi

# --- 5. MAIN LOOP ---
for (( i=0; i<${#TIME_FILTERS[@]}; i++ )); do

    TIME_FILTER_EXPR="${TIME_FILTERS[$i]}"
    OUTPUT_SUFFIX="${OUTPUT_SUFFIXES[$i]}"

    echo ""
    echo "=========================================================="
    echo "Processing Interval $((i+1))/${#TIME_FILTERS[@]}: ${OUTPUT_SUFFIX}"
    echo "=========================================================="

    # --- 5a. Create and move into the interval directory ---
    INTERVAL_DIR="${SPEC_DIR}/${OUTPUT_SUFFIX}"
    mkdir -p "${INTERVAL_DIR}"
    cd "${INTERVAL_DIR}" || { echo "Failed to cd into ${INTERVAL_DIR}"; exit 1; }
    echo "Changed directory to $(pwd)"

    # --- 5b. Copy necessary input files from RGS_DIR ---
    echo "Copying required input files (*SRCLI*)..."
    [ -n "${RGS1_SRC_FILE}" ] && cp -f "${RGS1_SRC_FILE}" .
    [ -n "${RGS2_SRC_FILE}" ] && cp -f "${RGS2_SRC_FILE}" .
    # 'merged' files are used in 'fluxing' stage
    [ -n "${RGS1_MERGED_FILE}" ] && cp -f "${RGS1_MERGED_FILE}" .
    [ -n "${RGS2_MERGED_FILE}" ] && cp -f "${RGS2_MERGED_FILE}" .
    
    
    INTERVAL_GTI_LIST=""
    TEMP_GTI_FILES_TO_DELETE=""

    # --- 5c. Create Interval-Specific GTI for RGS1 (if it exists) ---
    if [ -n "${RGS1_EVT_FILE}" ]; then
        # We create the temp GTI *locally* in the INTERVAL_DIR
        TEMP_GTI1="temp_gti_rgs1_${OUTPUT_SUFFIX}.fits"
        echo "Creating temporary RGS1 GTI: ${TEMP_GTI1}"
        
        tabgtigen table="${RGS1_EVT_FILE}" \
            expression="${TIME_FILTER_EXPR}" \
            gtiset="${TEMP_GTI1}"
            
        INTERVAL_GTI_LIST="${TEMP_GTI1}" # Local path
        TEMP_GTI_FILES_TO_DELETE="${TEMP_GTI1}"
    fi
    
    # --- 5d. Create Interval-Specific GTI for RGS2 (if it exists) ---
    if [ -n "${RGS2_EVT_FILE}" ]; then
        TEMP_GTI2="temp_gti_rgs2_${OUTPUT_SUFFIX}.fits"
        echo "Creating temporary RGS2 GTI: ${TEMP_GTI2}"
        
        tabgtigen table="${RGS2_EVT_FILE}" \
            expression="${TIME_FILTER_EXPR}" \
            gtiset="${TEMP_GTI2}"

        INTERVAL_GTI_LIST="${INTERVAL_GTI_LIST} ${TEMP_GTI2}" # Local path
        TEMP_GTI_FILES_TO_DELETE="${TEMP_GTI_FILES_TO_DELETE} ${TEMP_GTI2}"
    fi

    # --- 5e. Build Final Combined GTI List ---
    # We use FULL paths for flare GTIs, and LOCAL paths for interval GTIs
    FINAL_AUX_GTI_LIST="${FLARE_GTI_LIST} ${INTERVAL_GTI_LIST}"
    FINAL_AUX_GTI_LIST=$(echo ${FINAL_AUX_GTI_LIST}) # Trim spaces
    
    if [ -z "${FINAL_AUX_GTI_LIST}" ]; then
         echo "ERROR: No GTI files (flare or interval) could be generated."
         cd "${PROC_DIR}" || exit 1
         exit 1
    fi
    
    echo "Running rgsproc with combined GTI list:"
    echo "  ${FINAL_AUX_GTI_LIST}"

    # --- 5f. Run rgsproc (Filter Stage) ---
    # It runs in the current directory (INTERVAL_DIR) and finds the
    # *SRCLI* files we copied. It finds *EVENLI* files via SAS_ODF.
    # It writes all output to the current directory.
    rgsproc entrystage=3:filter finalstage=5:fluxing \
        orders="${RGS_ORDERS}" \
        bkgcorrect=yes \
        auxgtitables="${FINAL_AUX_GTI_LIST}"

    # --- 5g. Clean up temporary files ---
    echo "Cleaning up temporary interval GTIs..."
    rm -f ${TEMP_GTI_FILES_TO_DELETE}

    echo "--- Finished processing interval: ${OUTPUT_SUFFIX} ---"
    
    # --- 5h. Return to main processing directory ---
    cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}"; exit 1; }
    echo "Changed directory back to $(pwd)"

done

# --- 6. Completion ---
echo ""
echo "=========================================================="
echo "RGS Multi-Interval spectral extraction complete for ObsID ${OBSID}."
echo "All files are located in sub-directories within: ${SPEC_DIR}"
echo "=========================================================="
