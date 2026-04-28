#!/bin/bash
#
# sas_common.sh — Shared setup and utility functions for XMM-Newton SAS scripts.
#
# Usage: source "$(dirname "$0")/sas_common.sh"
#
# Provides:
#   - Environment variable validation (PROJECT_ROOT, OBSID)
#   - Standard directory paths (PN_DIR, SPEC_DIR, LC_DIR, etc.)
#   - SAS calibration setup (SAS_CCF, SAS_ODF)
#   - Instrument configuration (RAWX filters, pile-up settings)
#   - Utility functions: extract_spectrum(), generate_arf()
#
################################################################################

# --- 1. Validate Required Environment Variables ---
for _var in PROJECT_ROOT OBSID; do
    if [ -z "${!_var}" ]; then
        echo "ERROR: Environment variable ${_var} is not set."
        exit 1
    fi
done

# --- 2. Standard Paths ---
export OBS_DIR_ODF="${PROJECT_ROOT}/data/${OBSID}"
export PN_DIR="${PROJECT_ROOT}/products/${OBSID}/pn"
export SPEC_DIR="${PN_DIR}/spec"
export LC_DIR="${PN_DIR}/lc"
CLEAN_EVT_FILE="${PN_DIR}/pn_clean.evt"

# --- 3. SAS Calibration Setup ---
if [ ! -d "${OBS_DIR_ODF}" ]; then
    echo "ERROR: ODF directory not found: ${OBS_DIR_ODF}"
    exit 1
fi

export SAS_CCF="${OBS_DIR_ODF}/ccf.cif"
if [ ! -f "${SAS_CCF}" ]; then
    echo "ERROR: CCF file not found: ${SAS_CCF}"
    exit 1
fi

_SAS_ODF_FILE=$(find "${OBS_DIR_ODF}" -maxdepth 1 -name "*SUM.SAS" -print -quit)
if [ -z "${_SAS_ODF_FILE}" ]; then
    echo "ERROR: Cannot find *SUM.SAS file in ${OBS_DIR_ODF}"
    exit 1
fi
export SAS_ODF="${_SAS_ODF_FILE}"

echo "SAS_CCF: $(basename "${SAS_CCF}")"
echo "SAS_ODF: $(basename "${SAS_ODF}")"

# --- 4. Instrument Configuration ---
# NOTE: Pile-up destruction fraction diagnostic (2026-04-27) confirmed
# <1.5% destruction in the PSF core (RAWX 35-40). No excision needed.
IS_PILED_UP="no"
SRC_RAWX_FILTER_STD="RAWX in [27:47]"
BKG_RAWX_FILTER="RAWX in [1:3]"
SRC_EXCISION_FILTER="!(RAWX in [36:38])"

# --- 5. Utility Functions ---

# Build the final source RAWX filter, applying pile-up excision if needed.
# Usage: FILTER=$(build_src_filter "BASE_EXPR" ["EXTRA_FILTER"])
build_src_filter() {
    local base_filter=$1
    local extra=${2:-""}
    local result

    if [ "${IS_PILED_UP}" == "yes" ]; then
        result="${base_filter} && ${SRC_RAWX_FILTER_STD} && ${SRC_EXCISION_FILTER}"
    else
        result="${base_filter} && ${SRC_RAWX_FILTER_STD}"
    fi

    [ -n "${extra}" ] && result="${result} && ${extra}"
    echo "${result}"
}

# Extract a spectrum from the clean event file.
# Usage: extract_spectrum OUTPUT_FILE FILTER_EXPRESSION
extract_spectrum() {
    local output=$1
    local filter=$2
    evselect table="${CLEAN_EVT_FILE}" \
        withspectrumset=yes spectrumset="${output}" \
        energycolumn=PI spectralbinsize=5 \
        withspecranges=yes specchannelmin=0 specchannelmax=20479 \
        expression="${filter}" writedss=yes
}

# Generate ARF — handles pile-up subtraction method automatically.
# Usage: generate_arf SRC_SPEC ARF_FILE RMF_FILE BASE_FILTER [GTI_FILTER]
generate_arf() {
    local src_spec=$1
    local arf_file=$2
    local rmf_file=$3
    local base_filter=$4
    local gti_filter=${5:-""}

    if [ "${IS_PILED_UP}" == "yes" ]; then
        echo "  Generating ARF (pile-up subtraction method)..."
        local temp_dir
        temp_dir=$(dirname "${arf_file}")
        local spec_full="${temp_dir}/_temp_arf_full.fits"
        local spec_inn="${temp_dir}/_temp_arf_inner.fits"
        local arf_full="${temp_dir}/_temp_arf_full.arf"
        local arf_inn="${temp_dir}/_temp_arf_inner.arf"

        local inner_core_rawx
        inner_core_rawx=$(echo "${SRC_EXCISION_FILTER}" | sed -e 's/!//' -e 's/(//' -e 's/)//')

        local full_filt="${base_filter} && ${SRC_RAWX_FILTER_STD}"
        local inn_filt="${base_filter} && ${inner_core_rawx}"

        if [ -n "${gti_filter}" ]; then
            full_filt="${full_filt} && ${gti_filter}"
            inn_filt="${inn_filt} && ${gti_filter}"
        fi

        extract_spectrum "${spec_full}" "${full_filt}"
        extract_spectrum "${spec_inn}" "${inn_filt}"

        arfgen spectrumset="${spec_full}" arfset="${arf_full}" \
            withrmfset=yes rmfset="${rmf_file}" \
            badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf

        arfgen spectrumset="${spec_inn}" arfset="${arf_inn}" \
            withrmfset=yes rmfset="${rmf_file}" \
            badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf

        addarf "${arf_full} ${arf_inn}" "1.0 -1.0" "${arf_file}" clobber=yes
        rm -f "${spec_full}" "${spec_inn}" "${arf_full}" "${arf_inn}"
    else
        echo "  Generating ARF (standard method)..."
        arfgen spectrumset="${src_spec}" arfset="${arf_file}" \
            withrmfset=yes rmfset="${rmf_file}" \
            badpixlocation="${CLEAN_EVT_FILE}" detmaptype=psf
    fi
}
