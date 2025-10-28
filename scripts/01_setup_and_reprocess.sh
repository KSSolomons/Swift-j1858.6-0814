#!/bin/bash
#
# SCRIPT: run_reprocessing.sh
#
# DESCRIPTION:
# This script performs the initial setup (cifbuild, odfingest) and
# reprocessing (epproc, rgsproc) for an XMM-Newton observation.
#
#It is assumed that HEASOFT and SAS has been initialized
#
#
# USAGE:
# 1. Set the $OBS_DIR_ODF and $SAS_CCFPATH environment variables.
# 2. Run this script from root
#
################################################################################

echo "Starting XMM-Newton Reprocessing..."

# --- 1. CHECK FOR ENVIRONMENT VARIABLES ---
# This script requires the user to set the paths to their ODF and CCF
# data *before* running.

if [ -z "${OBS_DIR_ODF}" ]; then
    echo "ERROR: Environment variable OBS_DIR_ODF is not set."
    echo "Please set this to the full path of your ODF directory."
    echo "Example: export OBS_DIR_ODF=/path/to/your/ODF"
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


# --- 2. SAS INITIALIZATION ---
# (Assumes SAS is already initialized in your shell)
# ...

# --- 3. SETUP (cifbuild & odfingest) ---
echo "Setting initial environment variables for SAS..."
export SAS_ODF="${OBS_DIR_ODF}"

# Change to the ODF directory to run setup tasks
cd "${OBS_DIR_ODF}" || { echo "Failed to cd to ODF directory. Exiting."; exit 1; }

echo "Running cifbuild..."
cifbuild

if [ ! -f "ccf.cif" ]; then
    echo "cifbuild failed. ccf.cif not found. Exiting."
    exit 1
fi

echo "Setting SAS_CCF..."
export SAS_CCF="${OBS_DIR_ODF}ccf.cif"



echo "Running odfingest and creating *SUM.SAS..."

odfingest

# Find just the name of the summary file
SUMMARY_FILE_NAME=$(find . -name "*SUM.SAS" -printf "%f\n" | head -n 1)

if [ -z "${SUMMARY_FILE_NAME}" ]; then
    echo "odfingest failed. Summary file (*SUM.SAS) not found. Exiting."
    exit 1
fi

# We now export SAS_ODF with the FULL absolute path, just like we did for SAS_CCF

export SAS_ODF="${OBS_DIR_ODF}/${SUMMARY_FILE_NAME}"

echo "Setting SAS_ODF to summary file: ${SAS_ODF}"


# Return to the processing directory (the repository root)
cd - || { echo "Failed to cd back to processing directory. Exiting."; exit 1; }
export PROC_DIR=$(pwd) # Save our main processing directory path
echo "Setup complete. Now in processing directory: ${PROC_DIR}"

# --- 4. REPROCESSING (epproc & rgsproc) ---

# --- EPIC-pn ---
echo "--- Running epproc (EPIC-pn) ---"
# Create the directory inside 'products'
mkdir -p products/pn
# Change into that new directory
cd products/pn || { echo "Failed to cd into ./products/pn. Exiting."; exit 1; }

echo "Now in $(pwd). Running epproc..."
epproc >& epproc.log
echo "epproc complete. Products are in $(pwd)"
# Return to the root directory
cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}. Exiting."; exit 1; }


# --- RGS ---
echo "--- Running rgsproc (RGS) ---"
# Create the directory inside 'products'
mkdir -p products/rgs
# Change into that new directory
cd products/rgs || { echo "Failed to cd into ./products/rgs. Exiting."; exit 1; }

echo "Now in $(pwd). Running rgsproc..."
rgsproc >& rgsproc.log
echo "rgsproc complete. Products are in $(pwd)"
# Return to the root directory
cd "${PROC_DIR}" || { echo "Failed to cd back to ${PROC_DIR}. Exiting."; exit 1; }

# --- 5. COMPLETION ---
echo "--------------------------------------------------"
echo "Reprocessing finished."
echo "Log files: epproc.log, rgsproc.log"
echo "Check log files for any errors or warnings."
echo "You can now proceed with data reduction."
echo "--------------------------------------------------"
