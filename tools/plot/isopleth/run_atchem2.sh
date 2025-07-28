#!/usr/bin/env bash
# ......................................................................
#  run_atchem2.sh – batch driver for AtChem2 + isopleth generation
#  Scott Bell | Inversion Point Technologies Ltd.
# ......................................................................
set -euo pipefail
shopt -s nullglob

# ----------------------------------------------------------------------
#  0.  Resolve repo layout and environment
# ----------------------------------------------------------------------
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
REPO_ROOT="$( cd -- "${SCRIPT_DIR}/../../.." && pwd )"
RUN_DIR="${REPO_ROOT}"

# honour direnv & load module stack
[[ -f "${REPO_ROOT}/.envrc" ]] && eval "$(direnv export bash)"

# ----------------------------------------------------------------------
#  1.  Import user experiment settings
# ----------------------------------------------------------------------
ISOPLETH_CONFIG="${SCRIPT_DIR}/isopleth_config.sh" 
source "${ISOPLETH_CONFIG}"             # All important paths are now set here!

# USE ONLY VARIABLES DEFINED IN CONFIG!
# For example:
#   OUTPUT_ROOT, OUTPUT_LOG, OUTPUT_CONF, MODEL_DIR, PROJECT_LABEL, etc.

# Make output folder & subfolders
mkdir -p "${OUTPUT_ROOT}"              
mkdir -p "${OUTPUT_LOG}"               # central place for run logs
mkdir -p "${OUTPUT_CONF}"              # central place for run config

# Files to modify / retrieve
IN_SPECIES_CONF="${MODEL_DIR}/configuration/initialConcentrations.config"
OUT_SPECIES_CONF="${MODEL_DIR}/configuration/outputSpecies.config"
OUT_SPECIES_FILE="${MODEL_DIR}/output/speciesConcentrations.output"

# ----------------------------------------------------------------------
#  2.  Helper functions
# ----------------------------------------------------------------------
# Write a fresh initialConcentrations.config from current loop values
# Flag so we only patch the arrays once
__ZERO_INJECTED="false"

write_input_species_conf() {
  # 0-injection: ensure both scans contain a baseline value “0”
  if [[ "${__ZERO_INJECTED}" == "false" ]]; then
    if [[ ! " ${SCAN_1[*]} " =~ " 0 " ]]; then
      SCAN_1=(0 "${SCAN_1[@]}")
    fi
    if [[ ! " ${SCAN_2[*]} " =~ " 0 " ]]; then
      SCAN_2=(0 "${SCAN_2[@]}")
    fi
    __ZERO_INJECTED="true"
  fi
  # Write initialConcentrations.config for this run
  {
    # 2a. baseline species
    for idx in "${!BASE_SPECIES[@]}"; do
      printf "%s\t%s\n" "${BASE_SPECIES[$idx]}" "${BASE_CONC[$idx]}"
    done

    # 2b. current loop values for the two scan dimensions
    printf "%s\t%s\n" "${SCAN_SPECIES_1}" "${val1}"
    printf "%s\t%s\n" "${SCAN_SPECIES_2}" "${val2}"
  } > "${IN_SPECIES_CONF}"
}

# Write a fresh outputSpecies.config from isopleth_config.sh values
write_output_species_conf() {
  : > "${OUT_SPECIES_CONF}"   # truncate
  for sp in "${OUTPUT_SPECIES[@]}"; do
    printf "%s\n" "${sp}" >> "${OUT_SPECIES_CONF}"
  done
}

# Run atchem2 and log outputs
run_atchem2() {
  local idx=$1
  (
    cd "${RUN_DIR}"
    ./atchem2 > "${OUTPUT_LOG}/atchem2_log_${idx}.txt"
    cd "${SCRIPT_DIR}"
  )
  # Copy only if atchem2 actually produced the file
  if [[ -f "${OUT_SPECIES_FILE}" ]]; then
    cp "${OUT_SPECIES_FILE}" "${OUTPUT_LOG}/atchem2_concs_${idx}.txt"
  else
    echo "WARN: ${OUT_SPECIES_FILE} not found for run ${idx}" | tee -a "${OUTPUT_LOG}/atchem2_log_${idx}.txt"
  fi
}

# ----------------------------------------------------------------------
#  3.  Main sweep over the 2‑D scan grid
# ----------------------------------------------------------------------
counter=0
write_output_species_conf
for val1 in "${SCAN_1[@]}"; do
  for val2 in "${SCAN_2[@]}"; do
    ((++counter))
    write_input_species_conf
    run_atchem2 "${counter}"
  done
done

echo "✓ Completed ${counter} AtChem2 runs – results in ${OUTPUT_ROOT}"

# ----------------------------------------------------------------------
#  4.  Archive provenance & launch the R post‑processor
# ----------------------------------------------------------------------
cp "${ISOPLETH_CONFIG}" "${OUTPUT_CONF}"                                # save config used
cp "${MODEL_DIR}/**/*config" "${OUTPUT_CONF}" 2>/dev/null || true       # save atchem2 configuration files
cp "${MODEL_DIR}/**/*parameters" "${OUTPUT_CONF}" 2>/dev/null || true   # save atchem2 parameter files
cp "${MECHANISM}" "${OUTPUT_CONF}" 2>/dev/null || true                  # save chemical mechanism used

R_EXIT_CODE=0

Rscript "${SCRIPT_DIR}/generate_isopleth.R" \
  --config="${ISOPLETH_CONFIG}" \
  --output-dir="${OUTPUT_ROOT}" \
  --conc-dir="${CONC_DIR}" \
    || R_EXIT_CODE=$?

if [[ $R_EXIT_CODE -ne 0 ]]; then
  echo ""
  echo "*************************************************************"
  echo "🚨 Error: generate_isopleth.R failed (exit code: $R_EXIT_CODE)"
  # Try to extract the failed function name from the Rscript output log (if available)
  # Let's look for an error message in the last 30 lines:
  LAST_ERR=$(tail -30 "${OUTPUT_LOG}/atchem2_log_1.txt" 2>/dev/null | grep 'Error in' | head -1)
  if [[ -z "$LAST_ERR" ]]; then
    # fallback: try to grep from most recent R error log, or suggest manually
    echo "• To debug, open 'generate_isopleth.R' and add browser() inside the failing function."
    echo "• Then run the following command in a terminal for an interactive debug session:"
  else
    # Extract function name if possible
    FN=$(echo "$LAST_ERR" | sed -n 's/.*Error in \([a-zA-Z0-9_]*\).*/\1/p')
    if [[ -n "$FN" ]]; then
      echo "• The error appears to be in function: $FN"
      echo "• To debug, add a line with browser() as the first statement inside function '$FN' in generate_isopleth.R."
      echo "• Then run the following R command for interactive debugging:"
    else
      echo "• To debug, add browser() to the likely failing function in generate_isopleth.R."
      echo "• Then run the following R command for interactive debugging:"
    fi
  fi
  echo ""
  echo "    Rscript -i \"${SCRIPT_DIR}/generate_isopleth.R\" --config=\"${ISOPLETH_CONFIG}\""
  echo ""
  echo "  (The -i flag keeps R in interactive mode so browser() works!)"
  echo "*************************************************************"
  exit $R_EXIT_CODE
fi

echo "✓ Isopleth generation launched."
