#!/bin/bash
#
# SCRIPT: 05_regroup_spectra.sh
#
# DESCRIPTION:
# Dedicated script to perform spectral grouping for both EPIC-pn and RGS
# using the HEASOFT 'ftgrouppha' tool. Overwrites existing grouped spectra.
# Accounts for both the full observation and time-resolved intervals.
# Strips header paths to prevent XSPEC auto-load crashes.
#
################################################################################

# --- CONFIGURATION ---

# EPIC-pn GROUPING SETTINGS
PN_GROUP_TYPE="min"
PN_MIN_COUNTS="50"

# RGS GROUPING SETTINGS
RGS_GROUP_TYPE="min"
RGS_MIN_COUNTS="20"

# --- END CONFIGURATION ---

if [ -z "${PROJECT_ROOT}" ] || [ -z "${OBSID}" ]; then
    echo "ERROR: Environment variables PROJECT_ROOT or OBSID are not set."
    exit 1
fi

PN_SPEC_DIRS=("${PROJECT_ROOT}/products/${OBSID}/pn/spec" "${PROJECT_ROOT}/products/${OBSID}/pn/spec/flux_resolved")
RGS_SPEC_DIRS=("${PROJECT_ROOT}/products/${OBSID}/rgs/time_intervals" "${PROJECT_ROOT}/products/${OBSID}/rgs/flux_resolved/LowFlux" "${PROJECT_ROOT}/products/${OBSID}/rgs/flux_resolved/HighFlux")

set -e

# ==============================================================================
# 1. EPIC-pn GROUPING
# ==============================================================================
echo "=========================================================="
echo "Regrouping EPIC-pn Spectra"
echo "=========================================================="

for DIR in "${PN_SPEC_DIRS[@]}"; do
    if [ -d "${DIR}" ]; then
        cd "${DIR}" || exit 1

        PN_SRC_FILES=$(find . -maxdepth 1 -name "pn_source_*.fits" ! -name "*_grp*" -o -name "pn_Dipping_*.fits" ! -name "*_grp*")

        if [ -z "${PN_SRC_FILES}" ]; then
            echo "WARNING: No un-grouped EPIC-pn source spectra found in ${DIR}."
        else
            echo "Processing directory: ${DIR}"
            echo "Grouping Type: ${PN_GROUP_TYPE}"

            for src in ${PN_SRC_FILES}; do
                src="${src#./}"

                # Extract suffix carefully based on naming convention
                if [[ "${src}" == pn_source_* ]]; then
                    suffix="${src#pn_source_}"
                    suffix="${suffix%.fits}"
                else
                    suffix="${src#pn_}"
                    suffix="${suffix%.fits}"
                fi

                if [ "${suffix}" == "spectrum" ]; then
                    bkg="pn_bkg_spectrum.fits"
                    rmf="pn_rmf.rmf"
                else
                    bkg="pn_bkg_${suffix}.fits"
                    rmf="pn_${suffix}.rmf"
                    # Allow old naming format: pn_rmf_${suffix}.rmf
                    [ ! -f "${rmf}" ] && rmf="pn_rmf_${suffix}.rmf"
                fi

                out="${src%.fits}_grp.pha"
                echo "Processing: ${src} -> ${out}"

                RMF_ARG=""
                BKG_ARG=""
                [ -f "${rmf}" ] && RMF_ARG="respfile=${rmf}"
                [ -f "${bkg}" ] && BKG_ARG="backfile=${bkg}"

                if [ "${PN_GROUP_TYPE}" == "opt" ]; then
                    ftgrouppha infile="${src}" outfile="${out}" grouptype="opt" \
                               ${RMF_ARG} ${BKG_ARG} clobber=yes > /dev/null
                elif [ "${PN_GROUP_TYPE}" == "optmin" ]; then
                    ftgrouppha infile="${src}" outfile="${out}" grouptype="optmin" \
                               groupscale="${PN_MIN_COUNTS}" ${RMF_ARG} ${BKG_ARG} clobber=yes > /dev/null
                else
                    ftgrouppha infile="${src}" outfile="${out}" grouptype="min" \
                               groupscale="${PN_MIN_COUNTS}" ${RMF_ARG} ${BKG_ARG} clobber=yes > /dev/null
                fi

                # FIX: Wipe the header keywords to prevent PyXspec auto-load crashes
                fparkey "none" "${out}[1]" BACKFILE > /dev/null
                fparkey "none" "${out}[1]" RESPFILE > /dev/null
                fparkey "none" "${out}[1]" ANCRFILE > /dev/null
            done
        fi
    else
        echo "WARNING: EPIC-pn spectral directory not found: ${DIR}"
    fi
done

# ==============================================================================
# 2. RGS GROUPING
# ==============================================================================
echo ""
echo "=========================================================="
echo "Regrouping RGS Spectra"
echo "=========================================================="

for DIR in "${RGS_SPEC_DIRS[@]}"; do
    if [ -d "${DIR}" ]; then
        cd "${DIR}" || exit 1

        # Only search within the current DIR to prevent duplicating subdirectories like flux_resolved/LowFlux
        SRC_FILES=$(find . -maxdepth 2 -type f -name "*_src_*.fits" ! -name "*_grp*")

        if [ -z "${SRC_FILES}" ]; then
            echo "WARNING: No un-grouped RGS source spectra found in ${DIR}."
        else
            echo "Processing directory: ${DIR}"
            echo "Grouping Type: ${RGS_GROUP_TYPE}"

            for src_path in ${SRC_FILES}; do
                dir_path=$(dirname "${src_path}")
                file_name=$(basename "${src_path}")

                cd "${DIR}/${dir_path#./}" || continue

                bkg="${file_name/src/bkg}"
                rmf="${file_name/_src/}"
                rmf="${rmf%.fits}.rmf"
                out="${file_name%.fits}_grp.pha"

                echo "Processing in ${DIR}/${dir_path#./}: ${file_name} -> ${out}"

                RMF_ARG=""
                BKG_ARG=""
                [ -f "${rmf}" ] && RMF_ARG="respfile=${rmf}"
                [ -f "${bkg}" ] && BKG_ARG="backfile=${bkg}"

                if [ "${RGS_GROUP_TYPE}" == "opt" ]; then
                    ftgrouppha infile="${file_name}" outfile="${out}" grouptype="opt" \
                               ${RMF_ARG} ${BKG_ARG} clobber=yes > /dev/null
                elif [ "${RGS_GROUP_TYPE}" == "optmin" ]; then
                    ftgrouppha infile="${file_name}" outfile="${out}" grouptype="optmin" \
                               groupscale="${RGS_MIN_COUNTS}" ${RMF_ARG} ${BKG_ARG} clobber=yes > /dev/null
                else
                    ftgrouppha infile="${file_name}" outfile="${out}" grouptype="min" \
                               groupscale="${RGS_MIN_COUNTS}" ${RMF_ARG} ${BKG_ARG} clobber=yes > /dev/null
                fi

                # FIX: Wipe the header keywords to prevent PyXspec auto-load crashes
                fparkey "none" "${out}[1]" BACKFILE > /dev/null
                fparkey "none" "${out}[1]" RESPFILE > /dev/null
                fparkey "none" "${out}[1]" ANCRFILE > /dev/null

                cd "${DIR}" || exit 1
            done
        fi
    else
        echo "WARNING: RGS spectral directory not found: ${DIR}"
    fi
done

echo "=========================================================="
echo "Regrouping complete."
echo "=========================================================="

