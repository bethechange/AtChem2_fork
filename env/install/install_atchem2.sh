#!/usr/bin/env bash
# env/install/install_atchem2.sh — installs third-party libs, builds & tests AtChem2 (repo-local, no sudo)
set -euo pipefail

# ── Locate repo ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

# ── Prefixes & env ────────────────────────────────────────────────────
ATCHEM_LIB="${ATCHEM_LIB:-${REPO_ROOT}/atchem-lib}"
ATCHEM_BIN="$REPO_ROOT/atchem2"
GEM_HOME="${GEM_HOME:-${REPO_ROOT}/.gem}"
SHIMS_DIR="${REPO_ROOT}/env/shims"

# Check for already-built binaries
if [[ -x "$ATCHEM_BIN" && -d "$ATCHEM_LIB" ]]; then
  echo "↳ AtChem2 already installed (binary + lib present) — skipping."
  exit 0
fi

export ATCHEM_LIB GEM_HOME
mkdir -p "${ATCHEM_LIB}" "${GEM_HOME}" "${SHIMS_DIR}"

# ── Python shim (so 'python' resolves if only python3 exists) ─────────
if ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  ln -sfn "$(command -v python3)" "${SHIMS_DIR}/python"
fi
export PATH="${SHIMS_DIR}:${GEM_HOME}/bin:${PATH}"

# ── Third-party installers ────────────────────────────────────────────
INST="${REPO_ROOT}/tools/install"

echo "🔧 Installing third-party dependencies into ${ATCHEM_LIB}"
bash "${INST}/install_cvode.sh"    "${ATCHEM_LIB}"
bash "${INST}/install_openlibm.sh" "${ATCHEM_LIB}"
bash "${INST}/install_numdiff.sh"  "${ATCHEM_LIB}"
bash "${INST}/install_fruit.sh"    "${ATCHEM_LIB}"

# Sanity checks
[[ -d "${ATCHEM_LIB}/cvode/lib" ]]        || { echo "❌ cvode not found"; exit 1; }
[[ -d "${ATCHEM_LIB}/openlibm" ]]         || { echo "❌ openlibm not found"; exit 1; }
[[ -x "${ATCHEM_LIB}/numdiff/bin/numdiff" ]] || { echo "❌ numdiff not found"; exit 1; }
[[ -d "${ATCHEM_LIB}/fruit_3.4.3" ]]      || { echo "❌ fruit not found"; exit 1; }

# ── Prepare Makefile ──────────────────────────────────────────────────
echo "🔧 Patching Makefile with local prefixes"
cp "${REPO_ROOT}/tools/install/Makefile.skel" "${REPO_ROOT}/Makefile"

MF="${REPO_ROOT}/Makefile"
if grep -qE '^ATCHEM_LIB[[:space:]]*=' "${MF}"; then
  sed -i -E "s|^ATCHEM_LIB *=.*|ATCHEM_LIB  = ${ATCHEM_LIB}|" "${MF}"
else
  sed -i "1i ATCHEM_LIB  = ${ATCHEM_LIB}" "${MF}"
fi
sed -i -E 's|^CVODELIBDIR *=.*|CVODELIBDIR = $(ATCHEM_LIB)/cvode/lib|'   "${MF}"
sed -i -E 's|^OPENLIBMDIR *=.*|OPENLIBMDIR = $(ATCHEM_LIB)/openlibm|'    "${MF}"
sed -i -E 's|^FRUITDIR *=.*|FRUITDIR    = $(ATCHEM_LIB)/fruit_3.4.3|'    "${MF}"

# ── Build & test ──────────────────────────────────────────────────────
echo "🏗️  Building AtChem2"
( cd "${REPO_ROOT}" && ./build/build_atchem2.sh ./model/mechanism.fac )

echo "🧪 Running test suite"
( cd "${REPO_ROOT}" && make alltests )

[[ -x "${REPO_ROOT}/atchem2" ]] || { echo "❌ atchem2 not built"; exit 1; }

echo "✅ install_atchem2.sh complete: ${REPO_ROOT}/atchem2"
