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

# --- CONFIGURATION: EDIT THIS SECTION ---

# 1. Define the Time Interval for the "Dipping Region"

DIP_TIME_FILTER="(TIME IN [701596278.492053:701625198.492053])"

# 2. Define the Single Flux Threshold (Counts/Second)
# Everything below this is "Low Flux", everything above is "High Flux"
FLUX_THRESHOLD=4.06378238341969

# 3. Bin Size for Rate Calculation
# We use 1.0s to capture rapid changes in flux.
LC_BIN_SIZE=1.0

# --- END CONFIGURATION ---

# --- STANDARD CONFIGURATION ---
IS_PILED_UP="yes"
SRC_RAWX_FILTER_STD="RAWX in [27:47]"
BKG_RAWX_FILTER="RAWX in [3:5]"
SRC_EXCISION_FILTER="!(RAWX in [36:38])"
GROUPING_SPEC="10"

# --- CHECK ENV VARS ---
if [ -z "${PROJECT_ROOT}" ] || [ -z "${OBSID}" ]; then
    echo "ERROR: Environment variables PROJECT_ROOT or OBSID are not set."
    exit 1
fi

# Define paths
export PN_DIR="${PROJECT_ROOT}/products/${OBSID}/pn"
export SPEC_DIR="${PROJECT_ROOT}/products/${OBSID}/pn/spec"
export FLUX_RES_DIR="${SPEC_DIR}/flux_resolved" # Dedicated folder

mkdir -p "${FLUX_RES_DIR}"

CLEAN_EVT_FILE="${PN_DIR}/pn_clean.evt"
if [ ! -f "${CLEAN_EVT_FILE}" ]; then echo "ERROR: clean event file not found."; exit 1; fi

# Re-establish SAS 
ODF_DIR_CLEAN="${PROJECT_ROOT}/data/${OBSID}"
export SAS_CCF="${ODF_DIR_CLEAN}/ccf.cif"
export SAS_ODF=$(find "${ODF_DIR_CLEAN}" -maxdepth 1 -name "*SUM.SAS" | head -n 1)

set -e

echo "--- Starting Flux-Resolved Extraction (2 Bins) ---"

# ==============================================================================
# STEP 1: GENERATE TEMPORARY RATE REFERENCE (RAW LIGHTCURVE)
# ==============================================================================
# We create a 1.0s bin lightcurve so tabgtigen has a 'RATE' column to read.

REF_LIGHTCURVE="${FLUX_RES_DIR}/temp_calc_rate.fits"

echo "Calculating count rates (creating temp 1s lightcurve)..."

# NOTE: We use the FULL source region (ignoring pile-up excision) for the RATE.
# This ensures we trigger based on the 'Observed Rate'.
LC_EXPR="(FLAG==0) && (PATTERN<=4) && PI in [500:10000] && ${SRC_RAWX_FILTER_STD}"

evselect table="${CLEAN_EVT_FILE}" \
    withrateset=yes rateset="${REF_LIGHTCURVE}" \
    timebinsize="${LC_BIN_SIZE}" maketimecolumn=yes \
    makeratecolumn=yes \
    expression="${LC_EXPR}" \
    energycolumn=PI

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
    # Now we apply that GTI to the Event File
    GTI_FILTER="gti(${TEMP_GTI}, TIME)"
    BASE_FILTER="(FLAG==0) && (PI in [500:15000]) && (PATTERN<=4)"
    BKG_FILTER="${BASE_FILTER} && ${BKG_RAWX_FILTER} && ${GTI_FILTER}"

    # Apply pile-up excision for the SPECTRUM (but not the rate calculation)
    if [ "${IS_PILED_UP}" == "yes" ]; then
        SRC_FILTER="${BASE_FILTER} && ${SRC_RAWX_FILTER_STD} && ${SRC_EXCISION_FILTER} && ${GTI_FILTER}"
    else
        SRC_FILTER="${BASE_FILTER} && ${SRC_RAWX_FILTER_STD} && ${GTI_FILTER}"
    fi

    # --- C. Extract Spectra ---
    evselect table="${CLEAN_EVT_FILE}" withspectrumset=yes spectrumset="${SRC_SPEC}" \
        energycolumn=PI spectralbinsize=5 withspecranges=yes specchannelmin=0 specchannelmax=20479 \
        expression="${SRC_FILTER}" writedss=yes

    evselect table="${CLEAN_EVT_FILE}" withspectrumset=yes spectrumset="${BKG_SPEC}" \
        energycolumn=PI spectralbinsize=5 withspecranges=yes specchannelmin=0 specchannelmax=20479 \
        expression="${BKG_FILTER}" writedss=yes

    # --- D. Response Gen & Backscale ---
    backscale spectrumset="${SRC_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"
    backscale spectrumset="${BKG_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"
    
    rmfgen spectrumset="${SRC_SPEC}" rmfset="${RMF_FILE}"

    # ARF Generation (Pile-up logic)
    if [ "${IS_PILED_UP}" == "yes" ]; then
        # Temp filenames
        SPEC_FULL="${FLUX_RES_DIR}/temp_full.fits"
        SPEC_INN="${FLUX_RES_DIR}/temp_inn.fits"
        ARF_FULL="${FLUX_RES_DIR}/temp_full.arf"
        ARF_INN="${FLUX_RES_DIR}/temp_inn.arf"
        
        # Temp Filters (Must include GTI)
        INNER_CORE_RAWX=$(echo "${SRC_EXCISION_FILTER}" | sed -e 's/!//' -e 's/(//' -e 's/)//')
        FILT_FULL="${BASE_FILTER} && ${SRC_RAWX_FILTER_STD} && ${GTI_FILTER}"
        FILT_INN="${BASE_FILTER} && ${INNER_CORE_RAWX} && ${GTI_FILTER}"

        # Extract Temp Spectra
        evselect table="${CLEAN_EVT_FILE}" withspectrumset=yes spectrumset="${SPEC_FULL}" expression="${FILT_FULL}" energycolumn=PI spectralbinsize=5 withspecranges=yes specchannelmin=0 specchannelmax=20479
        evselect table="${CLEAN_EVT_FILE}" withspectrumset=yes spectrumset="${SPEC_INN}" expression="${FILT_INN}" energycolumn=PI spectralbinsize=5 withspecranges=yes specchannelmin=0 specchannelmax=20479
        
        # Gen Temp ARFs
        arfgen spectrumset="${SPEC_FULL}" arfset="${ARF_FULL}" withrmfset=yes rmfset="${RMF_FILE}" badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf
        arfgen spectrumset="${SPEC_INN}" arfset="${ARF_INN}" withrmfset=yes rmfset="${RMF_FILE}" badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf

        # Subtract and Clean
        addarf "${ARF_FULL} ${ARF_INN}" "1.0 -1.0" "${ARF_FILE}" clobber=yes
        rm "${SPEC_FULL}" "${SPEC_INN}" "${ARF_FULL}" "${ARF_INN}"
    else
        arfgen spectrumset="${SRC_SPEC}" arfset="${ARF_FILE}" withrmfset=yes rmfset="${RMF_FILE}" badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf
    fi

    # --- E. Grouping ---
    specgroup spectrumset="${SRC_SPEC}" groupedset="${GRP_FILE}" \
        backgndset="${BKG_SPEC}" rmfset="${RMF_FILE}" arfset="${ARF_FILE}" mincounts="${GROUPING_SPEC}"

    # Remove the GTI for this loop iteration
    rm "${TEMP_GTI}"

done

# --- 3. CLEAN UP ---
# Remove the temporary rate calculator file
rm "${REF_LIGHTCURVE}"

echo "=========================================================="
echo "Extraction Complete. Output in: ${FLUX_RES_DIR}"
echo "=========================================================="
