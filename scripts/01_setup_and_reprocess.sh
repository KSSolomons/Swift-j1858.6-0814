#!/bin/bash
#
# SCRIPT: 01_setup_and_reprocess.sh
#
# DESCRIPTION:
# This script performs the initial setup (cifbuild, odfingest) and
# reprocessing (epproc, rgsproc) for an XMM-Newton observation.
# Setup files (ccf.cif, *SUM.SAS) are created inside the data directory.
# Reprocessing outputs go to products/[ObsID]/...
#
# It is assumed that HEASOFT and SAS has been initialized
#
# USAGE:
# 1. Set the $PROJECT_ROOT, $OBSID, and $SAS_CCFPATH environment variables.
#    (PROJECT_ROOT should be the absolute path to your repo root)
#    (OBSID should be the 10-digit observation ID)
# 2. Run this script from root (or anywhere, it's now portable)
#
################################################################################

echo "Starting XMM-Newton Reprocessing..."

# --- 1. CHECK FOR ENVIRONMENT VARIABLES & SET PATHS ---
if [ -z "${PROJECT_ROOT}" ]; then
    echo "ERROR: Environment variable PROJECT_ROOT is not set."
    echo "Please set this to the full path of your project directory."
    echo "Example: export PROJECT_ROOT=/path/to/my_analysis"
    exit 1
fi

if [ -z "${OBSID}" ]; then
    echo "ERROR: Environment variable OBSID is not set."
    echo "Example: export OBSID=0123456789"
    exit 1
fi

if [ -z "${SAS_CCFPATH}" ]; then
    echo "ERROR: Environment variable SAS_CCFPATH is not set."
    echo "Please set this to the full path of your CCF repository."
    echo "Example: export SAS_CCFPATH=/path/to/your/CCF"
    exit 1
fi

# --- Construct paths from environment variables ---
# This is now the single source of truth for paths
export OBS_DIR_ODF="${PROJECT_ROOT}/data/${OBSID}"
export PROD_OBS_DIR="${PROJECT_ROOT}/products/${OBSID}"
export PN_DIR="${PROD_OBS_DIR}/pn"
export RGS_DIR="${PROD_OBS_DIR}/rgs"

echo "Using Project Root: ${PROJECT_ROOT}"
echo "Using ObsID: ${OBSID}"
echo "Using ODF from: ${OBS_DIR_ODF}"
echo "Using CCF from: ${SAS_CCFPATH}"
echo "Output products will go to: ${PROD_OBS_DIR}/"

# --- 2. SAS INITIALIZATION ---
# (Assumes SAS is already initialized in your shell)


# --- 3. SETUP (cifbuild & odfingest) ---
echo "--- Running Setup Tasks IN Data Directory ---"
# Set SAS_ODF to the ODF *directory* for the setup tasks
export SAS_ODF="${OBS_DIR_ODF}"

# Check if ODF directory exists
if [ ! -d "${OBS_DIR_ODF}" ]; then
    echo "ERROR: ODF directory not found: ${OBS_DIR_ODF}"
    exit 1
fi

# Change to the ODF directory to run setup tasks
cd "${OBS_DIR_ODF}" || { echo "Failed to cd to ODF directory: ${OBS_DIR_ODF}. Exiting."; exit 1; }
echo "Changed directory to: $(pwd)"

echo "Running cifbuild..."
# Create ccf.cif *inside* the current (ODF) directory
cifbuild 

if [ ! -f "ccf.cif" ]; then
    echo "cifbuild failed. ccf.cif not found in $(pwd)"
    cd "${PROJECT_ROOT}" || echo "Warning: Failed to cd back to ${PROJECT_ROOT}"
    exit 1
fi

# Set SAS_CCF to the FULL path of the ccf.cif file we just created
echo "Setting SAS_CCF..."
export SAS_CCF="${OBS_DIR_ODF}/ccf.cif"
echo "SAS_CCF set to: ${SAS_CCF}"

# *** DEBUG LINE ***
echo "DEBUG: About to run odfingest. SAS_ODF is currently set to: ${SAS_ODF}"
# *** END DEBUG LINE ***

echo "Running odfingest (using default output name)..."
# Let odfingest create the *SUM.SAS file with its default name
odfingest 

# Find just the name of the summary file created in the current directory
SUMMARY_FILE_NAME=$(find . -maxdepth 1 -name "*SUM.SAS" -printf "%f\n" | head -n 1)

if [ -z "${SUMMARY_FILE_NAME}" ]; then
    echo "odfingest failed. Summary file (*SUM.SAS) not found in $(pwd)."
    echo "Check the log file: $(pwd)/odfingest.log"
    cd "${PROJECT_ROOT}" || echo "Warning: Failed to cd back to ${PROJECT_ROOT}"
    exit 1
fi

# We now export SAS_ODF with the FULL absolute path to the found file
export SAS_ODF="${OBS_DIR_ODF}/${SUMMARY_FILE_NAME}"
echo "Setting SAS_ODF to summary file: ${SAS_ODF}"


# Return to the processing directory (the repository root)
echo "Returning to root directory..."
cd "${PROJECT_ROOT}" || { echo "Failed to cd back to processing directory: ${PROJECT_ROOT}. Exiting."; exit 1; }
echo "Now in: $(pwd)"
echo "Setup complete. SAS_ODF and SAS_CCF point to files inside ${OBS_DIR_ODF}"


# --- 4. REPROCESSING (epproc & rgsproc) ---
# --- EPIC-pn ---
echo "--- Running epproc (EPIC-pn) ---"
mkdir -p "${PN_DIR}"
cd "${PN_DIR}" || { echo "Failed to cd into ${PN_DIR}. Exiting."; exit 1; }
echo "Now in $(pwd). Running epproc..."

epproc > epproc.log 2>&1
echo "epproc complete. Products are in $(pwd)"
cd "${PROJECT_ROOT}" || { echo "Failed to cd back to ${PROJECT_ROOT}. Exiting."; exit 1; }


# --- RGS ---
echo "--- Running rgsproc (RGS) ---"
mkdir -p "${RGS_DIR}"
cd "${RGS_DIR}" || { echo "Failed to cd into ${RGS_DIR}. Exiting."; exit 1; }
echo "Now in $(pwd). Running rgsproc..."
rgsproc > rgsproc.log 2>&1
echo "rgsproc complete. Products are in $(pwd)"
cd "${PROJECT_ROOT}" || { echo "Failed to cd back to ${PROJECT_RGS}. Exiting."; exit 1; }

# --- 5. COMPLETION ---
echo "--------------------------------------------------"
echo "Reprocessing finished for ObsID ${OBSID}."
echo "Setup files (ccf.cif, ${SUMMARY_FILE_NAME}) are in ${OBS_DIR_ODF}"
echo "Log files are in ${PN_DIR}/epproc.log and ${RGS_DIR}/rgsproc.log"
echo "Check log files for any errors or warnings."
echo "You can now proceed with data reduction."
echo "--------------------------------------------------"
