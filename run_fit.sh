#!/bin/bash

# Configuration for SPEX workflow
# Edit these values as needed, then run with: ./run_fit.sh [OPTIONS]

OBSID="0865600201"
INST="rgs"
INTERVAL="Full"
EMIN="5.0"
EMAX="25.0"
ITER="100"
MIN_COUNTS="1"
RGS_REGIONS="1" # Which RGS regions to fit: "1" (RGS1 1st order), "1:2" (RGS1), "1:4" (All)
MULTI_SECTOR="False"  # Set to "true" to treat RGS1/RGS2 as separate sectors (cross-calibration)
THREADS="4"          # Number of threads (use 1 for RGS to avoid segfaults)

# --- BLIND SEARCH OPTIONS ---
BLIND_SEARCH="False"  # Set to "true" to enable
DLAM="0.01"           # Step size (A)
MAX_POINTS="500"      # Max points in search
# -----------------------------

# --- PARAM FILE OPTIONS ---
UseBestFitParams="false"  # Set to "true" to use best-fit parameters
PARAMS="./scripts/spex_cli/best_fit_params.json" # Path to best-fit parameters file


# Construct the command
# Use min_counts binning to avoid optimal binning segfaults
CMD="python scripts/spex_cli/run_workflow.py \
    --obsid $OBSID \
    --instrument $INST \
    --interval $INTERVAL \
    --energy-min $EMIN \
    --energy-max $EMAX \
    --rgs-regions $RGS_REGIONS \
    --fit-iter-cap $ITER \
    --no-xabs \
    --binning optimal \
    --min-counts $MIN_COUNTS \
    --spex-threads $THREADS \
    --run"

# Add blind search flags if enabled
if [ "${BLIND_SEARCH,,}" = "true" ]; then
    echo "Enabling blind line search..."
    CMD="$CMD --blind-search-run --blind-search-dlam $DLAM --blind-search-max-points $MAX_POINTS"
fi

# Add best-fit params if provided
if [ "${UseBestFitParams,,}" = "true" ]; then
    echo "Using best-fit parameters from $PARAMS"
    CMD="$CMD --best-fit-params $PARAMS"
fi

# Add multi-sector flag if enabled
if [ "${MULTI_SECTOR,,}" = "true" ]; then
    echo "Enabling multi-sector cross-calibration..."
    CMD="$CMD --multi-sector"
fi

# Execute
eval $CMD