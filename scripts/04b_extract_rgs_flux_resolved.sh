#!/bin/bash
#
# SCRIPT: 04b_extract_rgs_flux_resolved_robust.sh
#
# DESCRIPTION:
# Extracts flux-resolved RGS spectra (High vs Low).

#
# LOGIC:
# 1. Generate Reference Lightcurve (using PN for high statistics).
# 2. Use 'tabgtigen' to create GTIs for High/Low states.
# 3. Use 'rgsproc' (with copied intermediate files) to extract spectra.
#
################################################################################

# --- USER CONFIGURATION ---

# 1. Dipping Time Interval
DIP_TIME_FILTER="(TIME IN [701596278.492053:701625198.492053])"

# 2. Flux Threshold (PN Counts/Sec)
FLUX_THRESHOLD=4.3849687576293945
LC_BIN_SIZE=10.0

# 3. GTI cleanup (post-tabgtigen) to avoid highly fragmented RGS filtering
GTI_MIN_INTERVAL_S=5.0
GTI_MERGE_GAP_S=2.0


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
    
    local temp_src="${FLUX_DIR}/temp_pn_src_lc.fits"
    local temp_bkg="${FLUX_DIR}/temp_pn_bkg_lc.fits"

    echo "Creating Corrected Reference PN Lightcurve..." >&2

    # Standard PN Source Region for Rate
    local expr_src="(FLAG==0) && (PATTERN<=4) && PI in [500:10000] && RAWX in [27:47]"
    # Standard PN Background Region
    local expr_bkg="(FLAG==0) && (PATTERN<=4) && PI in [500:10000] && RAWX in [3:5]"

    # Extract uncorrected source lightcurve
    evselect table="${pn_evt}" \
        withrateset=yes rateset="${temp_src}" \
        timebinsize="${LC_BIN_SIZE}" maketimecolumn=yes \
        makeratecolumn=yes \
        expression="${expr_src}" \
        energycolumn=PI > /dev/null

    # Extract uncorrected background lightcurve
    evselect table="${pn_evt}" \
        withrateset=yes rateset="${temp_bkg}" \
        timebinsize="${LC_BIN_SIZE}" maketimecolumn=yes \
        makeratecolumn=yes \
        expression="${expr_bkg}" \
        energycolumn=PI > /dev/null
        
    # Run epiclccorr for the final corrected lightcurve
    epiclccorr srctslist="${temp_src}" eventlist="${pn_evt}" \
        outset="${out_lc}" bkgtslist="${temp_bkg}" withbkgset=yes applyabsolutecorrections=yes > /dev/null

    # Clean up intermediate lightcurves
    rm -f "${temp_src}" "${temp_bkg}"

    echo " -> ${out_lc}" >&2
}

cleanup_gti_file() {
    # Remove very short GTIs and merge tiny gaps to avoid excessive exposure loss.
    local in_gti="$1"
    local out_gti="$2"
    local label="$3"

    if [ ! -f "${in_gti}" ]; then
        echo "WARNING: Missing GTI input for cleanup: ${in_gti}" >&2
        return 1
    fi

    if python3 - "${in_gti}" "${out_gti}" "${GTI_MIN_INTERVAL_S}" "${GTI_MERGE_GAP_S}" "${label}" <<'PY'
import sys
import numpy as np

in_gti, out_gti, min_len_s, merge_gap_s, label = sys.argv[1:6]
min_len_s = float(min_len_s)
merge_gap_s = float(merge_gap_s)

try:
    from astropy.io import fits
except Exception as exc:
    print(f"GTI cleanup ({label}): astropy unavailable: {exc}", file=sys.stderr)
    sys.exit(2)

with fits.open(in_gti) as hdul:
    if "STDGTI" not in hdul:
        print(f"GTI cleanup ({label}): STDGTI extension missing", file=sys.stderr)
        sys.exit(3)

    idx = hdul.index_of("STDGTI")
    gti_hdu = hdul[idx]
    data = gti_hdu.data

    if data is None or len(data) == 0:
        hdul.writeto(out_gti, overwrite=True)
        print(f"GTI cleanup ({label}): empty GTI copied")
        sys.exit(0)

    starts = np.asarray(data["START"], dtype=float)
    stops = np.asarray(data["STOP"], dtype=float)
    intervals = sorted((s, e) for s, e in zip(starts, stops) if e > s)

    if not intervals:
        new_hdu = fits.BinTableHDU.from_columns(gti_hdu.columns, nrows=0, header=gti_hdu.header, name=gti_hdu.name)
        hdul[idx] = new_hdu
        hdul.writeto(out_gti, overwrite=True)
        print(f"GTI cleanup ({label}): no valid intervals after sanity filter")
        sys.exit(0)

    filtered = [(s, e) for s, e in intervals if (e - s) >= min_len_s]

    merged = []
    for s, e in filtered:
        if not merged:
            merged.append([s, e])
            continue
        if s - merged[-1][1] <= merge_gap_s:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])

    new_hdu = fits.BinTableHDU.from_columns(gti_hdu.columns, nrows=len(merged), header=gti_hdu.header, name=gti_hdu.name)
    if merged:
        new_hdu.data["START"] = np.array([x[0] for x in merged], dtype=float)
        new_hdu.data["STOP"] = np.array([x[1] for x in merged], dtype=float)

    hdul[idx] = new_hdu
    hdul.writeto(out_gti, overwrite=True)

    raw_dur = float(np.sum(stops - starts))
    new_dur = float(np.sum(new_hdu.data["STOP"] - new_hdu.data["START"])) if len(merged) > 0 else 0.0
    print(
        f"GTI cleanup ({label}): rows {len(intervals)} -> {len(merged)}, "
        f"duration {raw_dur:.1f}s -> {new_dur:.1f}s"
    )
PY
    then
        return 0
    fi

    echo "WARNING: GTI cleanup failed for ${label}; using raw GTI." >&2
    cp -f "${in_gti}" "${out_gti}"
}

generate_flux_gtis() {
    local ref_lc="$1"
    
    echo "Generating GTIs using tabgtigen..." >&2

    # Define Logic
    local expr_low="${DIP_TIME_FILTER} && (RATE < ${FLUX_THRESHOLD})"
    local expr_high="${DIP_TIME_FILTER} && (RATE >= ${FLUX_THRESHOLD})"

    # Output filenames
    local gti_low_raw="${FLUX_DIR}/gti_low_raw.fits"
    local gti_high_raw="${FLUX_DIR}/gti_high_raw.fits"
    local gti_low="${FLUX_DIR}/gti_low.fits"
    local gti_high="${FLUX_DIR}/gti_high.fits"

    # Run tabgtigen (Directly like in your old script)
    tabgtigen table="${ref_lc}" expression="${expr_low}" gtiset="${gti_low_raw}" > /dev/null
    tabgtigen table="${ref_lc}" expression="${expr_high}" gtiset="${gti_high_raw}" > /dev/null

    cleanup_gti_file "${gti_low_raw}" "${gti_low}" "LowFlux"
    cleanup_gti_file "${gti_high_raw}" "${gti_high}" "HighFlux"

    rm -f "${gti_low_raw}" "${gti_high_raw}"

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

    # Apply GTIs at the filter stage per-instrument/per-exposure.
    # This is required for actual time selection in the extracted spectra.
    for inst in 1 2; do
        local evenli_file
        local srcli_file
        local merged_file
        local evenli_base
        local inst_exp_id
        local inst_tmp="rgs${inst}_tmp"
        local inst_gtis=""

        evenli_file=$(find "${RGS_DIR}" -maxdepth 1 -name "*R${inst}*EVENLI*.FIT" | head -n 1)
        srcli_file=$(find "${RGS_DIR}" -maxdepth 1 -name "*R${inst}*SRCLI*.FIT" | head -n 1)
        merged_file=$(find "${RGS_DIR}" -maxdepth 1 -name "*R${inst}*merged*.FIT" | head -n 1)

        if [ -z "${evenli_file}" ] || [ -z "${srcli_file}" ] || [ -z "${merged_file}" ]; then
            echo "Skipping RGS${inst} for ${state_name} (missing input files)." >&2
            continue
        fi

        evenli_base=$(basename "${evenli_file}")
        inst_exp_id=$(echo "${evenli_base}" | grep -o "R[12][SU][0-9]\{3\}")

        mkdir -p "${inst_tmp}"
        cd "${inst_tmp}" || continue

        cp -f "${evenli_file}" .
        cp -f "${srcli_file}" .
        cp -f "${merged_file}" .

        if [ -f "${RGS_DIR}/gti_rgs${inst}.fits" ]; then
            cp -f "${RGS_DIR}/gti_rgs${inst}.fits" .
            inst_gtis="gti_rgs${inst}.fits"
        fi

        cp -f "${gti_file}" "gti_flux_rgs${inst}.fits"
        if [ -n "${inst_gtis}" ]; then
            inst_gtis="${inst_gtis} gti_flux_rgs${inst}.fits"
        else
            inst_gtis="gti_flux_rgs${inst}.fits"
        fi

        echo "Running rgsproc for RGS${inst} (${inst_exp_id}) with GTIs: ${inst_gtis}" >&2
        rgsproc orders='1 2' \
                bkgcorrect=yes \
                xpsfexcl=99 \
                auxgtitables="${inst_gtis}" \
                withinstexpids=yes \
                instexpids="${inst_exp_id}" \
                entrystage=3:filter \
                finalstage=5:fluxing > "rgsproc_${state_name}_rgs${inst}.log" 2>&1

        mv -f *FIT ../ 2>/dev/null || true
        mv -f *.log ../ 2>/dev/null || true

        cd ..
        rm -rf "${inst_tmp}"
    done

    echo " -> Finished. Logs in ${work_dir}" >&2

    # Rename for convenience
    rename_products "${state_name}"

    # --- CLEANUP ---
    rm -f *EVENLI*.FIT *SRCLI*.FIT *merged*.FIT

    cd "${FLUX_DIR}" || return
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
