#!/bin/bash
#
# SCRIPT: 05_extract_time_spectra.sh
#
# DESCRIPTION:
# Extracts multiple TIME-FILTERED spectra using the 'tabgtigen' method.
#
# It loops over user-defined time expressions, creates a GTI file for
# each, and then extracts the spectrum and responses for that interval.
#
# USAGE:
# 1. Ensure you have run scripts 01, 02, and 03.
# 2. Use a lightcurve to find your desired time intervals.
# 3. Update the 'TIME_FILTERS' and 'OUTPUT_SUFFIXES' arrays below.
# 4. Run the script once.
#
################################################################################

# --- TIME FILTER CONFIGURATION - EDIT THIS SECTION ---

# Define the time filters (in MET seconds) to apply.
# Use standard BASH array syntax (spaces between quoted strings).
TIME_FILTERS=(
    "(TIME IN [701592874.218876:701596384.218876]) && (TIME IN [701625304.218876:701628654.218876]) && (TIME IN [701632874.218876:701676024.218876])"
    "(TIME IN [701596384.218876:701625304.218876])"
    "(TIME IN [701628654.218876:701632874.218876])"
)

# Define a unique name for EACH filter above. MUST be in the same order.
OUTPUT_SUFFIXES=(
    "Persistent"
    "Dipping"
    "Eclipse"
)

# --- END TIME FILTER ---


# --- STANDARD CONFIGURATION (Copy from script 04) ---
IS_PILED_UP="yes"
SRC_RAWX_FILTER_STD="RAWX in [27:47]"
BKG_RAWX_FILTER="RAWX in [3:5]"
SRC_EXCISION_FILTER="!(RAWX in [36:38])"
GROUPING_SPEC="25"
# --- END STANDARD CONFIG ---


# --- Re-establish SAS Setup Variables ---
# Assumes OBS_DIR_ODF points to data/[OBSID]
ODF_DIR_CLEAN=$(echo "${OBS_DIR_ODF}" | sed 's:/*$::') # Clean path to data dir
CCF_FILE="${ODF_DIR_CLEAN}/ccf.cif"
SUMMARY_FILE_NAME=$(find "${ODF_DIR_CLEAN}" -maxdepth 1 -name "*SUM.SAS" -printf "%f\n" | head -n 1)
if [ -z "${SUMMARY_FILE_NAME}" ]; then
    echo "ERROR: Cannot find *SUM.SAS file in ${ODF_DIR_CLEAN}"
    echo "Please ensure script 01 ran successfully."
    exit 1
fi
SUMMARY_FILE="${ODF_DIR_CLEAN}/${SUMMARY_FILE_NAME}"
if [ ! -f "${CCF_FILE}" ]; then echo "ERROR: Cannot find CCF file: ${CCF_FILE}"; exit 1; fi
if [ ! -f "${SUMMARY_FILE}" ]; then echo "ERROR: Cannot find Summary file: ${SUMMARY_FILE}"; exit 1; fi
export SAS_CCF="${CCF_FILE}"
export SAS_ODF="${SUMMARY_FILE}"
echo "SAS_CCF re-established: $(basename "${SAS_CCF}")"
echo "SAS_ODF re-established: $(basename "${SAS_ODF}")"
# --- End Re-establish ---

# Set strict error checking
set -e

echo "--- Starting Multi-Interval Spectral Extraction (tabgtigen method) ---"

export PROC_DIR=$(pwd)

# --- Get ObsID ---
if [ -z "${OBS_DIR_ODF}" ]; then
    echo "ERROR: Environment variable OBS_DIR_ODF is not set."
    exit 1
fi
OBSID=$(basename "${OBS_DIR_ODF}")
if ! [[ "${OBSID}" =~ ^[0-9]{10}$ ]]; then OBSID="unknown_obsid"; fi
echo "Using ObsID: ${OBSID}"

# --- Define Directories ---
export PN_DIR="products/${OBSID}/pn"
export SPEC_DIR="products/${OBSID}/pn/spec" # Output directory for final spectra
mkdir -p "${SPEC_DIR}"
CLEAN_EVT_FILE="${PN_DIR}/pn_clean.evt"

# --- Validate Configuration ---
if [ ${#TIME_FILTERS[@]} -ne ${#OUTPUT_SUFFIXES[@]} ]; then
    echo "ERROR: The number of TIME_FILTERS (${#TIME_FILTERS[@]})"
    echo "does not match the number of OUTPUT_SUFFIXES (${#OUTPUT_SUFFIXES[@]})."
    exit 1
fi
if [ ${#TIME_FILTERS[@]} -eq 0 ]; then
    echo "WARNING: No time filters defined. Nothing to do."
    exit 0
fi

if [ ! -f "${CLEAN_EVT_FILE}" ]; then
    echo "ERROR: Could not find clean event file: ${CLEAN_EVT_FILE}"
    echo "Please run script 02 first (with writedss=yes fix)."
    exit 1
fi

# --- MAIN LOOP ---
# Loop from 0 to (number of filters - 1)
for (( i=0; i<${#TIME_FILTERS[@]}; i++ )); do

    # Get the current filter and suffix from the arrays
    TIME_FILTER_EXPR="${TIME_FILTERS[$i]}"
    OUTPUT_SUFFIX="${OUTPUT_SUFFIXES[$i]}"

    echo ""
    echo "=========================================================="
    echo "Processing Interval ${i+1}/${#TIME_FILTERS[@]}: ${OUTPUT_SUFFIX}"
    echo "Using time expression: ${TIME_FILTER_EXPR}"
    echo "=========================================================="

    # --- 2. Define filenames (Using OUTPUT_SUFFIX) ---
    SRC_SPEC="${SPEC_DIR}/pn_source_${OUTPUT_SUFFIX}.fits"
    RMF_FILE="${SPEC_DIR}/pn_rmf_${OUTPUT_SUFFIX}.rmf"
    ARF_FILE="${SPEC_DIR}/pn_arf_${OUTPUT_SUFFIX}.arf"
    GRP_SPEC_FILE="${SPEC_DIR}/pn_source_${OUTPUT_SUFFIX}_grp.fits"
    BKG_SPEC="${SPEC_DIR}/pn_bkg_${OUTPUT_SUFFIX}.fits"
    
    # Temporary GTI file (will be created in SPEC_DIR)
    TEMP_GTI_FILE="${SPEC_DIR}/temp_${OUTPUT_SUFFIX}_gti.fits"

    # Temporary files for pile-up
    SRC_SPEC_FULL_TEMP="${PN_DIR}/pn_source_spectrum_full_temp.fits"
    SRC_SPEC_INNER_TEMP="${PN_DIR}/pn_source_spectrum_inner_temp.fits"
    ARF_FILE_FULL_TEMP="${PN_DIR}/pn_arf_full_temp.arf"
    ARF_FILE_INNER_TEMP="${PN_DIR}/pn_arf_inner_temp.arf"

    # --- 3. Create Temporary GTI File ---
    echo "Creating temporary GTI file: $(basename ${TEMP_GTI_FILE})"
    # Use the *clean event file* to generate the GTI
    tabgtigen table="${CLEAN_EVT_FILE}" \
        expression="${TIME_FILTER_EXPR}" \
        gtiset="${TEMP_GTI_FILE}"
    
    # Standard spatial filter expression
    BASE_FILTER_EXPR="(FLAG==0)&&(PI in [500:15000])&&(PATTERN<=4)"
    
    # --- 4. Determine Final Source & Bkg Filters (Now with GTI) ---
    GTI_FILTER_EXPR="gti(${TEMP_GTI_FILE}, TIME)"
    
    if [ "${IS_PILED_UP}" == "yes" ]; then
        FINAL_SRC_FILTER_EXPR="${BASE_FILTER_EXPR} && ${SRC_RAWX_FILTER_STD} && ${SRC_EXCISION_FILTER} && ${GTI_FILTER_EXPR}"
    else
        FINAL_SRC_FILTER_EXPR="${BASE_FILTER_EXPR} && ${SRC_RAWX_FILTER_STD} && ${GTI_FILTER_EXPR}"
    fi
    FINAL_BKG_FILTER_EXPR="${BASE_FILTER_EXPR} && ${BKG_RAWX_FILTER} && ${GTI_FILTER_EXPR}"

    echo "Using Source Filter: ${FINAL_SRC_FILTER_EXPR}"
    echo "Using Background Filter: ${FINAL_BKG_FILTER_EXPR}"

    # --- 5. Extract Source Spectrum ---
    echo "Extracting source spectrum: $(basename ${SRC_SPEC})"
    evselect table="${CLEAN_EVT_FILE}" \
        withspectrumset=yes spectrumset="${SRC_SPEC}" \
        energycolumn=PI spectralbinsize=5 \
        withspecranges=yes specchannelmin=0 specchannelmax=20479 \
        expression="${FINAL_SRC_FILTER_EXPR}" \
        writedss=yes

    # --- 6. Extract Background Spectrum ---
    echo "Extracting background spectrum: $(basename ${BKG_SPEC})"
    evselect table="${CLEAN_EVT_FILE}" \
        withspectrumset=yes spectrumset="${BKG_SPEC}" \
        energycolumn=PI spectralbinsize=5 \
        withspecranges=yes specchannelmin=0 specchannelmax=20479 \
        expression="${FINAL_BKG_FILTER_EXPR}" \
        writedss=yes

    # --- 7. Calculate BACKSCAL Keywords ---
    echo "Calculating BACKSCAL..."
    # Using pn_clean.evt for badpixlocation as requested
    backscale spectrumset="${SRC_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"
    backscale spectrumset="${BKG_SPEC}" badpixlocation="${CLEAN_EVT_FILE}"

    # --- 8. Generate RMF ---
    echo "Generating RMF: $(basename ${RMF_FILE})"
    rmfgen spectrumset="${SRC_SPEC}" rmfset="${RMF_FILE}"

    # --- 9. Generate ARF (Conditional Method) ---
    if [ "${IS_PILED_UP}" == "yes" ]; then
        echo "--- Generating ARF via subtraction method (for pile-up) ---"
        INNER_CORE_RAWX=$(echo "${SRC_EXCISION_FILTER}" | sed -e 's/!//' -e 's/(//' -e 's/)//')
        # Must ALSO apply the GTI filter to these temporary spectra
        INNER_CORE_FILTER_EXPR="${BASE_FILTER_EXPR} && ${INNER_CORE_RAWX} && ${GTI_FILTER_EXPR}"
        FULL_SRC_FILTER_EXPR_TEMP="${BASE_FILTER_EXPR} && ${SRC_RAWX_FILTER_STD} && ${GTI_FILTER_EXPR}"

        echo "  Extracting FULL source spectrum (temp)..."
        evselect table="${CLEAN_EVT_FILE}" \
            withspectrumset=yes spectrumset="${SRC_SPEC_FULL_TEMP}" \
            expression="${FULL_SRC_FILTER_EXPR_TEMP}" \
            energycolumn=PI spectralbinsize=5 \
            withspecranges=yes specchannelmin=0 specchannelmax=20479 \
            writedss=yes
            
        echo "  Extracting INNER CORE spectrum (temp)..."
        evselect table="${CLEAN_EVT_FILE}" \
            withspectrumset=yes spectrumset="${SRC_SPEC_INNER_TEMP}" \
            expression="${INNER_CORE_FILTER_EXPR}" \
            energycolumn=PI spectralbinsize=5 \
            withspecranges=yes specchannelmin=0 specchannelmax=20479 \
            writedss=yes

        echo "  Generating ARF for FULL spectrum (temp)..."
        # Using pn_clean.evt for badpixlocation as requested
        arfgen spectrumset="${SRC_SPEC_FULL_TEMP}" arfset="${ARF_FILE_FULL_TEMP}" \
            withrmfset=yes rmfset="${RMF_FILE}" \
            badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf

        echo "  Generating ARF for INNER CORE spectrum (temp)..."
        # Using pn_clean.evt for badpixlocation as requested
        arfgen spectrumset="${SRC_SPEC_INNER_TEMP}" arfset="${ARF_FILE_INNER_TEMP}" \
            withrmfset=yes rmfset="${RMF_FILE}" \
            badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf

        echo "  Subtracting ARFs to create final ARF: $(basename ${ARF_FILE})"
        addarf "${ARF_FILE_FULL_TEMP} ${ARF_FILE_INNER_TEMP}" "1.0 -1.0" "${ARF_FILE}" clobber=yes
        echo "--- ARF subtraction complete ---"
    else
        echo "--- Generating ARF via standard method (no pile-up) ---"
        # Using pn_clean.evt for badpixlocation as requested
        arfgen spectrumset="${SRC_SPEC}" arfset="${ARF_FILE}" \
            withrmfset=yes rmfset="${RMF_FILE}" \
            badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf
        echo "--- Standard ARF generation complete ---"
    fi

    # --- 10. Group the Source Spectrum ---
    echo "Grouping the final spectrum: $(basename ${GRP_SPEC_FILE})"
    specgroup spectrumset="${SRC_SPEC}" \
        groupedset="${GRP_SPEC_FILE}" \
        backgndset="${BKG_SPEC}" \
        rmfset="${RMF_FILE}" \
        arfset="${ARF_FILE}" \
        mincounts="${GROUPING_SPEC}"

    # --- 11. Clean up temporary files ---
    echo "Cleaning up temporary files..."
    rm -f "${TEMP_GTI_FILE}" # Delete the GTI file for this interval
    if [ "${IS_PILED_UP}" == "yes" ]; then
        rm -f "${SRC_SPEC_FULL_TEMP}" "${SRC_SPEC_INNER_TEMP}" \
              "${ARF_FILE_FULL_TEMP}" "${ARF_FILE_INNER_TEMP}"
    fi

    echo "--- Finished processing interval: ${OUTPUT_SUFFIX} ---"

done

# --- 12. Completion ---
echo ""
echo "=========================================================="
echo "Multi-Interval spectral extraction complete for ObsID ${OBSID}."
echo "All files are located in: ${SPEC_DIR}"
echo "=========================================================="



