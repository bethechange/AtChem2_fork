#!/usr/bin/env bash
# env/install/install_atchem2.sh — installs third-party libs, builds & tests AtChem2 (repo-local, no sudo)
set -euo pipefail

# ── Args / usage ──────────────────────────────────────────────────────────────
usage() {
  cat <<'USAGE'
Usage: install_atchem2.sh [--prefix <install-root>] [--version <X.Y>] [--module-dir <dir>] [--force]

  --prefix <install-root>   Optional base prefix for runtime deps; if set, libs go under:
                            <prefix>/cvode, <prefix>/openlibm, <prefix>/numdiff, <prefix>/fruit_3.4.3
                            (If unset, defaults to <repo>/atchem-lib)

  --version <X.Y>           Version label to embed in modulefile name (default: 1.0).
                            Module will be written to <module-dir>/<version>.lua

  --module-dir <dir>        Where to write the modulefile (default: <repo>/env/modules/atchem2)

  --force                   Rebuild/reinstall even if outputs appear present. Also overwrites modulefile.

Examples:
  ./env/install/install_atchem2.sh
  ./env/install/install_atchem2.sh --prefix /opt/atchem2/1.0 --version 1.0
  ./env/install/install_atchem2.sh --module-dir /usr/share/modulefiles/atchem2 --prefix /opt/atchem2/1.0
USAGE
}

PREFIX=""
VERSION="${ATCHEM_VERSION:-1.0}"
FORCE=0
MODULE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --prefix) PREFIX="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --module-dir) MODULE_DIR="$2"; shift 2;;
    --force) FORCE=1; shift;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

# ── Locate repo ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

# ── Prefixes & env (installer is the source of truth) ─────────────────────────
# Runtime dependency root ("prefix") — local by default, or a provided --prefix
if [[ -z "${PREFIX}" ]]; then
  PREFIX="${REPO_ROOT}/atchem-lib"
fi

ATCHEM_LIB="${PREFIX}"                           # keep name for compatibility with tools scripts
ATCHEM_BIN="${REPO_ROOT}/atchem2"
GEM_HOME="${GEM_HOME:-${REPO_ROOT}/.gem}"        # Ruby gems (kept repo-local by default)
SHIMS_DIR="${REPO_ROOT}/env/shims"               # small helper shims (e.g., python -> python3)

# Module destination (repo-local by default; can be a site dir via --module-dir)
if [[ -z "${MODULE_DIR}" ]]; then
  MODULE_DIR="${REPO_ROOT}/env/modules/atchem2"
fi
MODULE_PATH="${MODULE_DIR}/${VERSION}.lua"

echo "-----------------------------------------------------------------"
echo "AtChem2 installer"
printf "  ▸ repo       : %s\n" "$REPO_ROOT"
printf "  ▸ prefix     : %s\n" "$PREFIX"
printf "  ▸ module dir : %s\n" "$MODULE_DIR"
printf "  ▸ module ver : %s\n" "$VERSION"
printf "  ▸ gem home   : %s\n" "$GEM_HOME"
printf "  ▸ shims dir  : %s\n" "$SHIMS_DIR"
echo "-----------------------------------------------------------------"

# ── Idempotent output checks (build may be skipped; module is still (re)written) ─
BIN_OK=0; LIB_OK=0
[[ -x "$ATCHEM_BIN" ]] && BIN_OK=1
[[ -d "$ATCHEM_LIB" ]] && LIB_OK=1

# ── Prepare directories ───────────────────────────────────────────────────────
export ATCHEM_LIB GEM_HOME
mkdir -p "${ATCHEM_LIB}" "${GEM_HOME}" "${SHIMS_DIR}" "${MODULE_DIR}"

# ── Python shim (so 'python' resolves if only python3 exists) ────────────────
if ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  ln -sfn "$(command -v python3)" "${SHIMS_DIR}/python"
fi
export PATH="${SHIMS_DIR}:${GEM_HOME}/bin:${PATH}"

# ── Third-party installers ───────────────────────────────────────────────────
INST="${REPO_ROOT}/tools/install"

if [[ $FORCE -eq 1 || $LIB_OK -eq 0 ]]; then
  echo "🔧 Installing third-party dependencies into ${ATCHEM_LIB}"
  bash "${INST}/install_cvode.sh"    "${ATCHEM_LIB}"
  bash "${INST}/install_openlibm.sh" "${ATCHEM_LIB}"
  bash "${INST}/install_numdiff.sh"  "${ATCHEM_LIB}"
  bash "${INST}/install_fruit.sh"    "${ATCHEM_LIB}"
else
  echo "↳ Libraries already present at ${ATCHEM_LIB} (use --force to reinstall)"
fi

# Sanity checks (lib side)
[[ -d "${ATCHEM_LIB}/cvode/lib" ]]             || { echo "❌ cvode not found"; exit 1; }
[[ -d "${ATCHEM_LIB}/openlibm" ]]              || { echo "❌ openlibm not found"; exit 1; }
[[ -x "${ATCHEM_LIB}/numdiff/bin/numdiff" ]]   || { echo "❌ numdiff not found"; exit 1; }
[[ -d "${ATCHEM_LIB}/fruit_3.4.3" ]]           || { echo "❌ fruit not found"; exit 1; }

# ── Prepare Makefile (local build config) ─────────────────────────────────────
if [[ $FORCE -eq 1 || $BIN_OK -eq 0 ]]; then
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

  # ── Build & test ─────────────────────────────────────────────────
  echo "🏗️  Building AtChem2"
  ( cd "${REPO_ROOT}" && ./build/build_atchem2.sh ./model/mechanism.fac )

  echo "🧪 Running test suite"
  ( cd "${REPO_ROOT}" && make alltests )

  [[ -x "${REPO_ROOT}/atchem2" ]] || { echo "❌ atchem2 not built"; exit 1; }
else
  echo "↳ Binary already present at ${ATCHEM_BIN} (use --force to rebuild)"
fi

# ── Generate the Lmod modulefile (installer = source of truth) ───────────────
# The module contains *only runtime stack paths*. User/project data paths should be set
# via per-user config, overlays, or project .envrc (not baked into this module).
echo "🧾 Writing modulefile → ${MODULE_PATH}"

cat > "${MODULE_PATH}" <<EOF
-- -*- lua -*-
whatis("Name: atchem2")
whatis("Version: ${VERSION}")
whatis("Description: AtChem2 runtime stack (installed via env/install/install_atchem2.sh)")

help([[
AtChem2 runtime.
Installed prefix: ${ATCHEM_LIB}

This module does NOT set per-user input/output roots.
Set ATCHEM_INPUT_ROOT / ATCHEM_OUTPUT_ROOT yourself
(e.g., in ~/.config/atchem2/config, a project .envrc, or a small overlay module).
]])

family("atchem2")  -- avoid mixing multiple atchem2 stacks

local prefix   = "${ATCHEM_LIB}"
local gem_home = "${GEM_HOME}"
local shims    = "${SHIMS_DIR}"

setenv("ATCHEM_LIB",   prefix)
setenv("CVODELIBDIR",  pathJoin(prefix, "cvode/lib"))
setenv("OPENLIBMDIR",  pathJoin(prefix, "openlibm"))
setenv("FRUITDIR",     pathJoin(prefix, "fruit_3.4.3"))

prepend_path("PATH", pathJoin(prefix,   "numdiff/bin"))
prepend_path("PATH", pathJoin(gem_home, "bin"))
prepend_path("PATH", shims)

-- gentle warnings if something is missing (non-fatal)
local function exists_dir(p)
  local rc = os.execute('[ -d "'..p..'" ] > /dev/null 2>&1')
  if type(rc) == "number" then return rc == 0 else return rc == true end
end

if (mode() == "load") then
  if not exists_dir(pathJoin(prefix, "cvode", "lib")) then
    LmodMessage("[atchem2/${VERSION}] Warning: CVODE not found under "..pathJoin(prefix, "cvode", "lib"))
  end
  if not exists_dir(pathJoin(prefix, "openlibm")) then
    LmodMessage("[atchem2/${VERSION}] Warning: OpenLibm not found under "..pathJoin(prefix, "openlibm"))
  end
  if not exists_dir(pathJoin(prefix, "fruit_3.4.3")) then
    LmodMessage("[atchem2/${VERSION}] Warning: FRUIT not found under "..pathJoin(prefix, "fruit_3.4.3"))
  end
end
EOF

echo "✓ Modulefile written."

# (Optional) write a repo-local .modulerc to make this version default
MODULERC="${MODULE_DIR}/.modulerc"
if [[ ! -f "${MODULERC}" ]]; then
  echo "module-version atchem2/${VERSION} default" > "${MODULERC}"
  echo "✓ Default set in ${MODULERC} (atchem2/${VERSION})"
fi

echo
echo "✅ install_atchem2.sh complete:"
echo "    • Binary      : ${ATCHEM_BIN} $( [[ -x "$ATCHEM_BIN" ]] && echo '(present)' || echo '(missing)')"
echo "    • Runtime lib : ${ATCHEM_LIB}"
echo "    • Modulefile  : ${MODULE_PATH}"
echo
echo "Next steps:"
echo "  1) Ensure your module path includes: $(dirname "${MODULE_DIR}")"
echo "     (repo-local env/setup_env.sh already does: module use \$ENV_PATH/modules)"
echo "  2) Then: module load atchem2/${VERSION}"
