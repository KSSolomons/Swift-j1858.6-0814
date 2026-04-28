#!/bin/bash
#
# SCRIPT: 06_extract_flux_resolved_spectra.sh
#
# DESCRIPTION:
# Extracts flux-resolved spectra for a specific time interval (e.g., Dipping).
# Splits data into TWO flux bins based on a single threshold.
# 
# LOGIC FLOW:
# 1. Generate a TEMPORARY 1.0s raw lightcurve (instantaneous).
# 2. Use tabgtigen to find intervals where:
#    (Time inside Dipping Window) AND (Rate above/below Flux Threshold).
# 3. Extract spectra for those intervals.
# 4. Delete the temporary lightcurve.
#
################################################################################

# --- Source shared setup (env checks, SAS, paths, instrument config) ---
source "$(dirname "$0")/sas_common.sh"

# --- CONFIGURATION: EDIT THIS SECTION ---

# 1. Define the Time Interval for the "Dipping Region"
DIP_TIME_FILTER="(TIME IN [701596278.492053:701625198.492053])"

# 2. Define the Single Flux Threshold (Counts/Second)
# Everything below this is "Low Flux", everything above is "High Flux"
FLUX_THRESHOLD=4.3849687576293945

# 3. Bin Size for Rate Calculation
# We use 1.0s to capture rapid changes in flux.
LC_BIN_SIZE=1.0

# 4. Grouping specification (minimum counts per bin)
GROUPING_SPEC="10"

# --- END CONFIGURATION ---

set -e

export FLUX_RES_DIR="${SPEC_DIR}/flux_resolved"
mkdir -p "${FLUX_RES_DIR}"

if [ ! -f "${CLEAN_EVT_FILE}" ]; then echo "ERROR: clean event file not found."; exit 1; fi

echo "--- Starting Flux-Resolved Extraction (2 Bins) ---"

# ==============================================================================
# STEP 1: GENERATE CORRECTED RATE REFERENCE (LIGHTCURVE)
# ==============================================================================
# We create a 1.0s bin corrected lightcurve so tabgtigen has a accurate 'RATE' column to read.

REF_LIGHTCURVE="${FLUX_RES_DIR}/temp_calc_rate_corrected.fits"
TEMP_SRC_LC="${FLUX_RES_DIR}/temp_src_lc.fits"
TEMP_BKG_LC="${FLUX_RES_DIR}/temp_bkg_lc.fits"

echo "Calculating corrected count rates (running epiclccorr)..."

# Source uncorrected lightcurve
LC_EXPR_SRC="(FLAG==0) && (PATTERN<=4) && PI in [500:10000] && ${SRC_RAWX_FILTER_STD}"
evselect table="${CLEAN_EVT_FILE}" \
    withrateset=yes rateset="${TEMP_SRC_LC}" \
    timebinsize="${LC_BIN_SIZE}" maketimecolumn=yes \
    makeratecolumn=yes \
    expression="${LC_EXPR_SRC}" \
    energycolumn=PI

# Background uncorrected lightcurve
LC_EXPR_BKG="(FLAG==0) && (PATTERN<=4) && PI in [500:10000] && ${BKG_RAWX_FILTER}"
evselect table="${CLEAN_EVT_FILE}" \
    withrateset=yes rateset="${TEMP_BKG_LC}" \
    timebinsize="${LC_BIN_SIZE}" maketimecolumn=yes \
    makeratecolumn=yes \
    expression="${LC_EXPR_BKG}" \
    energycolumn=PI

# Correct the lightcurve
epiclccorr srctslist="${TEMP_SRC_LC}" eventlist="${CLEAN_EVT_FILE}" \
    outset="${REF_LIGHTCURVE}" bkgtslist="${TEMP_BKG_LC}" withbkgset=yes applyabsolutecorrections=yes

# ==============================================================================
# STEP 2: DEFINE FILTERS AND LOOP
# ==============================================================================

# Filter 1: Low Flux (Rate < Threshold)
EXPR_LOW="${DIP_TIME_FILTER} && (RATE < ${FLUX_THRESHOLD})"

# Filter 2: High Flux (Rate >= Threshold)
EXPR_HIGH="${DIP_TIME_FILTER} && (RATE >= ${FLUX_THRESHOLD})"

# Define Arrays for the Loop
FILTER_EXPRESSIONS=( "${EXPR_LOW}" "${EXPR_HIGH}" )
OUTPUT_SUFFIXES=( "Dipping_LowFlux" "Dipping_HighFlux" )

for (( i=0; i<${#FILTER_EXPRESSIONS[@]}; i++ )); do
    
    CURRENT_EXPR="${FILTER_EXPRESSIONS[$i]}"
    SUFFIX="${OUTPUT_SUFFIXES[$i]}"

    echo ""
    echo "Processing: ${SUFFIX}"
    
    # Define filenames
    SRC_SPEC="${FLUX_RES_DIR}/pn_${SUFFIX}.fits"
    BKG_SPEC="${FLUX_RES_DIR}/pn_bkg_${SUFFIX}.fits"
    RMF_FILE="${FLUX_RES_DIR}/pn_${SUFFIX}.rmf"
    ARF_FILE="${FLUX_RES_DIR}/pn_${SUFFIX}.arf"
    GRP_FILE="${FLUX_RES_DIR}/pn_${SUFFIX}_grp.fits"
    TEMP_GTI="${FLUX_RES_DIR}/gti_${SUFFIX}.fits"

    # --- A. Create GTI based on Time AND Rate ---
    # tabgtigen reads the 'RATE' from the temp lightcurve
    tabgtigen table="${REF_LIGHTCURVE}" expression="${CURRENT_EXPR}" gtiset="${TEMP_GTI}"

    # Check if we actually found any data in this flux range
    if [ ! -f "${TEMP_GTI}" ]; then
        echo "WARNING: No data found for ${SUFFIX}. Skipping."
        continue
    fi
    
    # --- B. Define Spectral Filters ---
    GTI_FILTER="gti(${TEMP_GTI}, TIME)"
    BASE_FILTER="(FLAG==0) && (PI in [500:15000]) && (PATTERN<=4)"

    SRC_FILTER=$(build_src_filter "${BASE_FILTER}" "${GTI_FILTER}")
    BKG_FILTER="${BASE_FILTER} && ${BKG_RAWX_FILTER} && ${GTI_FILTER}"

    # --- C. Extract Spectra ---
    extract_spectrum "${SRC_SPEC}" "${SRC_FILTER}"
    extract_spectrum "${BKG_SPEC}" "${BKG_FILTER}"

    # --- D. Response Gen & Backscale ---
    backscale spectrumset="${SRC_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"
    backscale spectrumset="${BKG_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"
    
    rmfgen spectrumset="${SRC_SPEC}" rmfset="${RMF_FILE}"

    # ARF Generation
    generate_arf "${SRC_SPEC}" "${ARF_FILE}" "${RMF_FILE}" "${BASE_FILTER}" "${GTI_FILTER}"

    # --- E. Grouping ---
    specgroup spectrumset="${SRC_SPEC}" groupedset="${GRP_FILE}" \
        backgndset="${BKG_SPEC}" rmfset="${RMF_FILE}" arfset="${ARF_FILE}" mincounts="${GROUPING_SPEC}"

    # Remove the GTI for this loop iteration
    rm "${TEMP_GTI}"

done

# --- 3. CLEAN UP ---
# Remove the temporary rate calculator files
rm "${REF_LIGHTCURVE}" "${TEMP_SRC_LC}" "${TEMP_BKG_LC}"

echo "=========================================================="
echo "Extraction Complete. Output in: ${FLUX_RES_DIR}"
echo "=========================================================="
