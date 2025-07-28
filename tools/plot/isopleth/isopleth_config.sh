#!/usr/bin/env bash
# ......................................................................
#  isopleth_config.sh – user-editable experiment settings
# ......................................................................

# Absolute path to this config file's directory
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"

# A short tag used to name the run directory under tools/plot/isoplethr/output/
PROJECT_LABEL="demo_20250728"

# ----------------------------------------------------------------------
# Where to write results (absolute OR relative-to-repo-root)
#   ‣ leave empty to accept the driver’s default
# ----------------------------------------------------------------------
# Directory tree
OUTPUT_ROOT="${SCRIPT_DIR}/output/${PROJECT_LABEL}"
OUTPUT_LOG="${OUTPUT_ROOT}/log"
OUTPUT_CONF="${OUTPUT_ROOT}/conf"
MODEL_DIR="${SCRIPT_DIR}/../../../model"   # adjust if needed
# Provide explicit data file directory for R to pick up:
CONC_DIR="${OUTPUT_LOG}"
MECHANISM="${MODEL_DIR}/mechanism.fac"

# ----------------------------------------------------------------------
# Baseline atmospheric composition (species → molecules cm-3)
# ----------------------------------------------------------------------
# ‣ Keep the two arrays in the same order.
BASE_SPECIES=(CH4   CO      O3      NO2     OH    HO2)
BASE_CONC=(  1e12   2e11    6e11    5e10    1e6   2e6)

# ----------------------------------------------------------------------
# 2-D scan definition
# ----------------------------------------------------------------------
# Dimension 1  (e.g. hydrogen-peroxide sweep)
SCAN_SPECIES_1="H2O2"
SCAN_1=(0 1e7 1e8 1e9 1e10)

# Dimension 2  (e.g. NO sweep)
SCAN_SPECIES_2="NO"
SCAN_2=(0 1e8 1e9 1e10 1e11)

# ----------------------------------------------------------------------
# Species whose time-series AtChem2 should save to speciesConcentrations.output
# ----------------------------------------------------------------------
OUTPUT_SPECIES=(CH4 CO O3 H2O2 NO NO2 OH HO2 CH3OH HCHO)
ISOPLETH_REMOVED_SPECIES=(CH4 O3)
