#!/bin/bash
#
# SCRIPT: 04b_extract_rgs_flux_resolved_robust.sh
#
# DESCRIPTION:
# Extracts flux-resolved RGS spectra (High vs Low).
# ADAPTED from your "02b_rgs_reduction.sh" structure.
#
# LOGIC:
# 1. Generate Reference Lightcurve (using PN for high statistics).
# 2. Use 'tabgtigen' to create GTIs for High/Low states.
# 3. Use 'rgsproc' (with copied intermediate files) to extract spectra.
#
################################################################################

# --- USER CONFIGURATION ---

# 1. Dipping Time Interval
DIP_TIME_FILTER="(TIME >= 701592768.492053) &&! (TIME IN [701596278.492053:701625198.492053]) &&! (TIME IN [701628548.492053:701632768.492053]) &&! (TIME IN [701592818.492053:701596278.492053]) &&! (TIME IN [701642768.492053:701658528.492053])"

# 2. Flux Threshold (PN Counts/Sec)
FLUX_THRESHOLD=4.06378238341969
LC_BIN_SIZE=1.0


# --- END CONFIGURATION ---

# --- CHECK ENV VARS ---
if [ -z "${PROJECT_ROOT}" ] || [ -z "${OBSID}" ]; then
    echo "ERROR: Environment variables PROJECT_ROOT or OBSID are not set."
    exit 1
fi

export PN_DIR="${PROJECT_ROOT}/products/${OBSID}/pn"
export RGS_DIR="${PROJECT_ROOT}/products/${OBSID}/rgs"
export FLUX_DIR="${RGS_DIR}/flux_resolved"
export DATA_DIR="${PROJECT_ROOT}/data/${OBSID}"

mkdir -p "${FLUX_DIR}"

# --- SETUP SAS ---
export SAS_CCF="${DATA_DIR}/ccf.cif"
export SAS_ODF=$(find "${DATA_DIR}" -maxdepth 1 -name "*SUM.SAS" | head -n 1)

# Set strict error checking
set -e

echo "--- Starting RGS Flux-Resolved Extraction (Robust Mode) ---"

# --- FUNCTION DEFINITIONS ---

create_reference_lc() {
    # Creates a 1s bin lightcurve from PN data to act as the "Trigger"
    local pn_evt="$1"
    local out_lc="$2"
    
    echo "Creating Reference PN Lightcurve..." >&2
    
    # Standard PN Source Region for Rate
    local expr="(FLAG==0) && (PATTERN<=4) && PI in [500:10000] && RAWX in [27:47]"
    
    evselect table="${pn_evt}" \
        withrateset=yes rateset="${out_lc}" \
        timebinsize="${LC_BIN_SIZE}" maketimecolumn=yes \
        makeratecolumn=yes \
        expression="${expr}" \
        energycolumn=PI > /dev/null
        
    echo " -> ${out_lc}" >&2
}

generate_flux_gtis() {
    local ref_lc="$1"
    
    echo "Generating GTIs using tabgtigen..." >&2

    # Define Logic
    local expr_low="${DIP_TIME_FILTER} && (RATE < ${FLUX_THRESHOLD})"
    local expr_high="${DIP_TIME_FILTER} && (RATE >= ${FLUX_THRESHOLD})"

    # Output filenames
    local gti_low="${FLUX_DIR}/gti_low.fits"
    local gti_high="${FLUX_DIR}/gti_high.fits"

    # Run tabgtigen (Directly like in your old script)
    tabgtigen table="${ref_lc}" expression="${expr_low}" gtiset="${gti_low}" > /dev/null
    tabgtigen table="${ref_lc}" expression="${expr_high}" gtiset="${gti_high}" > /dev/null

    echo " -> ${gti_low}" >&2
    echo " -> ${gti_high}" >&2
}

run_rgsproc_flux() {
    local state_name="$1"
    local gti_file="$2"
    
    local work_dir="${FLUX_DIR}/${state_name}"
    local log_file="rgsproc_${state_name}.log"

    if [ ! -f "${gti_file}" ]; then
        echo "WARNING: GTI for ${state_name} not found. Skipping." >&2
        return
    fi

    echo "--- Processing State: ${state_name} ---"
    mkdir -p "${work_dir}"
    cd "${work_dir}" || return

    # Copy intermediate files so rgsproc has a head start
    echo "Copying intermediate files..." >&2
    cp -f ${RGS_DIR}/*SRCLI*.FIT .
    cp -f ${RGS_DIR}/*merged*.FIT .
    cp -f ${RGS_DIR}/*EVENLI*.FIT .
    
    echo "Running rgsproc..." >&2
    
    rgsproc orders='1 2' \
            bkgcorrect=yes \
            auxgtitables="${gti_file}" \
            entrystage=3:filter \
            finalstage=5:fluxing > "${log_file}" 2>&1

    echo " -> Finished. Log: ${work_dir}/${log_file}" >&2
    
    # Rename for convenience
    rename_products "${state_name}"

    # --- CLEANUP ---
    echo "Cleaning up large copied files..." >&2
    rm -f *EVENLI*.FIT *SRCLI*.FIT *merged*.FIT
}
rename_products() {
    local suffix="$1"
    # Helper to rename complex SAS files to simple names
    find . -name "*R1*SRSPEC1*.FIT" -exec mv {} "rgs1_src_o1_${suffix}.fits" \; 2>/dev/null
    find . -name "*R1*BGSPEC1*.FIT" -exec mv {} "rgs1_bkg_o1_${suffix}.fits" \; 2>/dev/null
    find . -name "*R1*RSPMAT1*.FIT" -exec mv {} "rgs1_o1_${suffix}.rmf" \; 2>/dev/null
    
    find . -name "*R1*SRSPEC2*.FIT" -exec mv {} "rgs1_src_o2_${suffix}.fits" \; 2>/dev/null
    find . -name "*R1*BGSPEC2*.FIT" -exec mv {} "rgs1_bkg_o2_${suffix}.fits" \; 2>/dev/null
    find . -name "*R1*RSPMAT2*.FIT" -exec mv {} "rgs1_o2_${suffix}.rmf" \; 2>/dev/null

    find . -name "*R2*SRSPEC1*.FIT" -exec mv {} "rgs2_src_o1_${suffix}.fits" \; 2>/dev/null
    find . -name "*R2*BGSPEC1*.FIT" -exec mv {} "rgs2_bkg_o1_${suffix}.fits" \; 2>/dev/null
    find . -name "*R2*RSPMAT1*.FIT" -exec mv {} "rgs2_o1_${suffix}.rmf" \; 2>/dev/null
    
    find . -name "*R2*SRSPEC2*.FIT" -exec mv {} "rgs2_src_o2_${suffix}.fits" \; 2>/dev/null
    find . -name "*R2*BGSPEC2*.FIT" -exec mv {} "rgs2_bkg_o2_${suffix}.fits" \; 2>/dev/null
    find . -name "*R2*RSPMAT2*.FIT" -exec mv {} "rgs2_o2_${suffix}.rmf" \; 2>/dev/null
}

# --- MAIN EXECUTION ---

# 1. Check for PN Event File (Reference)
PN_EVT="${PN_DIR}/pn_clean.evt"
if [ ! -f "${PN_EVT}" ]; then echo "ERROR: PN Clean Event file not found."; exit 1; fi

# 2. Generate Reference Lightcurve
REF_LC="${FLUX_DIR}/temp_pn_ref_rate.fits"
create_reference_lc "${PN_EVT}" "${REF_LC}"

# 3. Generate GTIs
generate_flux_gtis "${REF_LC}"

# 4. Run RGSPROC for High and Low
# We pass the Absolute Path to the GTIs
run_rgsproc_flux "LowFlux" "${FLUX_DIR}/gti_low.fits"
run_rgsproc_flux "HighFlux" "${FLUX_DIR}/gti_high.fits"

# 5. Cleanup
rm "${REF_LC}"

echo "--------------------------------------------------"
echo "RGS Flux-Resolved Extraction Complete."
echo "Results in: ${FLUX_DIR}"
echo "--------------------------------------------------"
