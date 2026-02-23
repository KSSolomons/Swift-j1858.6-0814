#!/bin/bash
#
# SCRIPT: 03b_extract_rgs_time_spectra.sh
#
# DESCRIPTION:
# Extracts multiple TIME-FILTERED RGS spectra using the robust 
# 'entrystage=3:filter' method.
#
# Automatically groups the spectra after extraction using 'ftgrouppha'.
#
################################################################################

# --- CONFIGURATION ---

# 1. TIME INTERVALS (Format: "Name|Expression")
CONFIGS=(
    "Persistent|(TIME IN [701642768.492053:701658528.492053])"
    "Dipping|(TIME IN [701596278.492053:701625198.492053])"
    "Shallow|(TIME IN [701592818.492053:701596278.492053]) || (TIME IN [701625198.492053:701628548.492053]) || (TIME IN [701632768.492053:701642768.492053]) || (TIME IN [701658528.492053:701675918.492053])"
    )

# 2. GROUPING SETTINGS
# Options: "opt" (Kaastra optimal binning) OR "min" (Minimum counts)
GROUP_TYPE="opt"
MIN_COUNTS=20     # Only used if GROUP_TYPE="min"

# --- END CONFIGURATION ---

if [ -z "${PROJECT_ROOT}" ] || [ -z "${OBSID}" ]; then
    echo "ERROR: Environment variables PROJECT_ROOT or OBSID are not set."
    exit 1
fi

export DATA_DIR="${PROJECT_ROOT}/data/${OBSID}"
export RGS_DIR="${PROJECT_ROOT}/products/${OBSID}/rgs"
export SPEC_DIR="${RGS_DIR}/time_intervals"

mkdir -p "${SPEC_DIR}"

# --- SETUP SAS ---
export SAS_CCF="${DATA_DIR}/ccf.cif"
export SAS_ODF=$(find "${DATA_DIR}" -maxdepth 1 -name "*SUM.SAS" | head -n 1)

set -e

# --- FUNCTION: Rename Products ---
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

# --- FUNCTION: Perform Grouping  ---
perform_grouping() {
    local suffix="$1"
    echo "--- Grouping Spectra (Type: ${GROUP_TYPE}) ---"

    # Iterate over standard RGS output keys
    for inst in rgs1 rgs2; do
        for order in o1 o2; do
            # Construct standard filenames based on rename_products
            local src="${inst}_src_${order}_${suffix}.fits"
            local bkg="${inst}_bkg_${order}_${suffix}.fits"
            local rmf="${inst}_${order}_${suffix}.rmf"
            local out="${inst}_src_${order}_${suffix}_grp.pha"

            if [ -f "$src" ]; then
                echo "  Grouping: $src -> $(basename $out)"
                
                # Check for RMF/BKG existence to avoid ftool errors
                local rmf_arg=""
                local bkg_arg=""
                
                if [ -f "$rmf" ]; then rmf_arg="respfile=$rmf"; fi
                if [ -f "$bkg" ]; then bkg_arg="backfile=$bkg"; fi

                if [ "$GROUP_TYPE" == "opt" ]; then
                    # Kaastra Optimal Binning
                    ftgrouppha infile="$src" \
                               outfile="$out" \
                               grouptype="opt" \
                               $rmf_arg \
                               $bkg_arg \
                               clobber=yes
                elif [ "$GROUP_TYPE" == "optmin" ]; then
                    # Kaastra Optimal Binning with Minimum Counts
                    ftgrouppha infile="$src" \
                               outfile="$out" \
                               grouptype="optmin" \
                               groupscale="$MIN_COUNTS" \
                               $rmf_arg \
                               $bkg_arg \
                               clobber=yes
                else
                    # Minimum Counts Grouping
                    ftgrouppha infile="$src" \
                               outfile="$out" \
                               grouptype="min" \
                               groupscale="$MIN_COUNTS" \
                               $rmf_arg \
                               $bkg_arg \
                               clobber=yes
                fi
            fi
        done
    done
}

# --- FUNCTION: Extract Interval ---
extract_interval() {
    local name="$1"
    local time_expr="$2"
    local flare_gti_list="$3"
    
    local work_dir="${SPEC_DIR}/${name}"
    
    echo ""
    echo "=========================================================="
    echo "Processing: ${name}"
    echo "=========================================================="
    
    mkdir -p "${work_dir}"
    cd "${work_dir}" || return
    
    # 1. COPY INPUTS
    echo "Copying inputs locally..."
    cp -f ${RGS_DIR}/*EVENLI*.FIT .
    cp -f ${RGS_DIR}/*SRCLI*.FIT .
    cp -f ${RGS_DIR}/*merged*.FIT .

    # 2. GENERATE LOCAL GTI (Time Filter)
    local interval_gtis=""
    
    local r1_evt=$(find . -name "*R1*EVENLI*.FIT" | head -n 1)
    if [ -f "${r1_evt}" ]; then
        tabgtigen table="${r1_evt}" expression="${time_expr}" gtiset="gti_time_r1.fits"
        interval_gtis="gti_time_r1.fits"
    fi

    local r2_evt=$(find . -name "*R2*EVENLI*.FIT" | head -n 1)
    if [ -f "${r2_evt}" ]; then
        tabgtigen table="${r2_evt}" expression="${time_expr}" gtiset="gti_time_r2.fits"
        interval_gtis="${interval_gtis} gti_time_r2.fits"
    fi

    # 3. COMBINE GTIs
    local all_gtis="${flare_gti_list} ${interval_gtis}"
    
    # 4. RUN RGSPROC
    rgsproc orders='1 2' \
            bkgcorrect=yes \
            auxgtitables="${all_gtis}" \
            entrystage=3:filter \
            finalstage=5:fluxing > "rgsproc_${name}.log" 2>&1
            
    echo "RGSPROC complete. Log: rgsproc_${name}.log"
    
    # 5. RENAME OUTPUTS
    rename_products "${name}"

    # 6. GROUP SPECTRA (Added Step)
    perform_grouping "${name}"
    
    # 7. CLEANUP
    rm -f *EVENLI*.FIT *SRCLI*.FIT *merged*.FIT
    
    cd "${PROC_DIR}" || return
}

# --- MAIN EXECUTION ---

# 1. Locate Flare GTIs (Global)
FLARE_GTIS=""
[ -f "${RGS_DIR}/gti_rgs1.fits" ] && FLARE_GTIS="${FLARE_GTIS} ${RGS_DIR}/gti_rgs1.fits"
[ -f "${RGS_DIR}/gti_rgs2.fits" ] && FLARE_GTIS="${FLARE_GTIS} ${RGS_DIR}/gti_rgs2.fits"

echo "Flare GTIs found: ${FLARE_GTIS}"

# 2. Loop through Configs
for config in "${CONFIGS[@]}"; do
    NAME="${config%%|*}"
    EXPR="${config#*|}"
    extract_interval "${NAME}" "${EXPR}" "${FLARE_GTIS}"
done

echo "=========================================================="
echo "Extraction and Grouping Complete. Results in: ${SPEC_DIR}"
echo "=========================================================="