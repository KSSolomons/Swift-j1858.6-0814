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
# 1. Set the $OBS_DIR_ODF and $SAS_CCFPATH environment variables.
#    (OBS_DIR_ODF should point to data/[OBSID])
# 2. Run this script from root
#
################################################################################

echo "Starting XMM-Newton Reprocessing..."

# --- 1. CHECK FOR ENVIRONMENT VARIABLES & GET OBSID ---
if [ -z "${OBS_DIR_ODF}" ]; then
    echo "ERROR: Environment variable OBS_DIR_ODF is not set."
    echo "Please set this to the full path of your ODF directory."
    echo "Example: export OBS_DIR_ODF=/path/to/data/0123456789"
    exit 1
fi

if [ -z "${SAS_CCFPATH}" ]; then
    echo "ERROR: Environment variable SAS_CCFPATH is not set."
    echo "Please set this to the full path of your CCF repository."
    echo "Example: export SAS_CCFPATH=/path/to/your/CCF"
    exit 1
fi

echo "Using ODF from: ${OBS_DIR_ODF}"
echo "Using CCF from: ${SAS_CCFPATH}"

# Assumes OBS_DIR_ODF is /path/to/data/OBSID
OBSID=$(basename "${OBS_DIR_ODF}")

# Corrected Logic: Check IF ObsID is 10 digits
if [[ "${OBSID}" =~ ^[0-9]{10}$ ]]; then
    # If it IS 10 digits, just print it and continue
    echo "Determined ObsID: ${OBSID}"
else
    # If it is NOT 10 digits, print the warning and use the fallback
    echo "WARNING: Could not reliably determine 10-digit ObsID from OBS_DIR_ODF path ('${OBS_DIR_ODF}'). Got '${OBSID}'."
    echo "Using default directory name 'unknown_obsid'."
    OBSID="unknown_obsid" # Fallback directory name
fi

# Define base product directory including ObsID
export PROD_OBS_DIR="products/${OBSID}"

# Define instrument-specific directories
export PN_DIR="${PROD_OBS_DIR}/pn"
export RGS_DIR="${PROD_OBS_DIR}/rgs"

echo "Output products will go to: ${PROD_OBS_DIR}/"
export PROC_DIR=$(pwd) # Save root directory


# --- 2. SAS INITIALIZATION ---
# (Assumes SAS is already initialized in your shell)



# --- 3. SETUP (cifbuild & odfingest) ---
echo "--- Running Setup Tasks IN Data Directory ---"
# Set SAS_ODF to the ODF *directory* for the setup tasks
export SAS_ODF="${OBS_DIR_ODF}"

# Change to the ODF directory to run setup tasks
cd "${OBS_DIR_ODF}" || { echo "Failed to cd to ODF directory: ${OBS_DIR_ODF}. Exiting."; exit 1; }
echo "Changed directory to: $(pwd)"

echo "Running cifbuild..."
# Create ccf.cif *inside* the current (ODF) directory
cifbuild 

if [ ! -f "ccf.cif" ]; then
    echo "cifbuild failed. ccf.cif not found in $(pwd)"
    cd "${PROC_DIR}" || echo "Warning: Failed to cd back to ${PROC_DIR}"
    exit 1
fi

# Set SAS_CCF to the FULL path of the ccf.cif file we just created
# *** Corrected: Added missing '/' ***
echo "Setting SAS_CCF..."
export SAS_CCF="${OBS_DIR_ODF}ccf.cif"
echo "SAS_CCF set to: ${SAS_CCF}"

# *** ADD THIS DEBUG LINE ***
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
    cd "${PROC_DIR}" || echo "Warning: Failed to cd back to ${PROC_DIR}"
    exit 1
fi

# We now export SAS_ODF with the FULL absolute path to the found file
export SAS_ODF="${OBS_DIR_ODF}/${SUMMARY_FILE_NAME}"
echo "Setting SAS_ODF to summary file: ${SAS_ODF}"


# Return to the processing directory (the repository root)
echo "Returning to root directory..."
cd "${PROC_DIR}" || { echo "Failed to cd back to processing directory: ${PROC_DIR}. Exiting."; exit 1; }
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
cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}. Exiting."; exit 1; }


# --- RGS ---
echo "--- Running rgsproc (RGS) ---"
mkdir -p "${RGS_DIR}"
cd "${RGS_DIR}" || { echo "Failed to cd into ${RGS_DIR}. Exiting."; exit 1; }
echo "Now in $(pwd). Running rgsproc..."
rgsproc > rgsproc.log 2>&1
echo "rgsproc complete. Products are in $(pwd)"
cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}. Exiting."; exit 1; }

# --- 5. COMPLETION ---
echo "--------------------------------------------------"
echo "Reprocessing finished for ObsID ${OBSID}."
echo "Setup files (ccf.cif, ${SUMMARY_FILE_NAME}) are in ${OBS_DIR_ODF}"
echo "Log files are in ${PN_DIR}/epproc.log and ${RGS_DIR}/rgsproc.log"
echo "Check log files for any errors or warnings."
echo "You can now proceed with data reduction."
echo "--------------------------------------------------"
