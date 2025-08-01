#!/usr/bin/env bash
# env/setup_system.sh – one-time system-level helpers
set -euo pipefail

########################################################################
# 0. Helper: ensure a line exists in a shell start-up file
########################################################################
add_line_if_missing() {
  local line="$1" file="$2"

  # Create the file if it doesn't exist
  [[ -f "$file" ]] || touch "$file"

  if ! grep -Fxq "$line" "$file"; then
    printf '\n# Added by env/setup_system.sh\n%s\n' "$line" >> "$file"
    echo "  ↳ Added to $file:"
    echo "    $line"
  else
    echo "  ↳ Already present in $file"
  fi
}

########################################################################
# 0a. Repo paths + Config (env/config.txt) – influences Conda behavior
########################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.txt"

# Defaults if config is absent
PYTHON_MGR_SELECT="${PYTHON_MGR_SELECT:-0}"   # 0=venv, 1=conda
CONDA_DIR="${CONDA_DIR:-}"                    # "" => local envs under repo; non-empty => global/shared env prefix

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  echo "✅ Loaded env/config.txt (affects Conda behavior):"
  echo "   - PYTHON_MGR_SELECT=${PYTHON_MGR_SELECT:-unset}"
  echo "   - CONDA_DIR='${CONDA_DIR:-}'"
else
  echo "ℹ️  No env/config.txt found – using defaults (PYTHON_MGR_SELECT=${PYTHON_MGR_SELECT}, CONDA_DIR='${CONDA_DIR}')"
fi

########################################################################
# 1. rig (R version manager) installer  ────────────────────────────────
########################################################################
echo "── rig (R version manager) installer ───────────────────────────"

if command -v rig &>/dev/null; then
  echo "✅ rig already installed: $(rig --version)"
else
  OS=$(uname -s)
  ARCH=$(uname -m)

  install_from_tar() {
    local url="https://github.com/r-lib/rig/releases/download/latest/rig-linux-${ARCH}-latest.tar.gz"
    echo "🔧 Installing rig from tarball …"
    curl -Ls "$url" | sudo tar -xz -C /usr/local
  }

  case "$OS" in
    Linux)
      if command -v apt-get &>/dev/null; then
        echo "🔧 Installing rig via Debian repo …"
        sudo curl -L https://rig.r-pkg.org/deb/rig.gpg \
          -o /etc/apt/trusted.gpg.d/rig.gpg
        echo "deb http://rig.r-pkg.org/deb rig main" |
          sudo tee /etc/apt/sources.list.d/rig.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y r-rig || install_from_tar
      elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        echo "🔧 Installing rig via RPM …"
        sudo yum install -y \
          "https://github.com/r-lib/rig/releases/download/latest/r-rig-latest-1.${ARCH}.rpm" ||
          install_from_tar
      elif command -v zypper &>/dev/null; then
        echo "🔧 Installing rig via zypper …"
        sudo zypper install -y --allow-unsigned-rpm \
          "https://github.com/r-lib/rig/releases/download/latest/r-rig-latest-1.${ARCH}.rpm" ||
          install_from_tar
      else
        echo "⚠️  Unknown Linux distro – falling back to tarball."
        install_from_tar
      fi
      ;;
    Darwin)
      if command -v brew &>/dev/null; then
        echo "🔧 Installing rig via Homebrew …"
        brew tap r-lib/rig
        brew install --cask rig
      else
        echo "⚠️  Homebrew not found – please install rig manually."
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      echo "🔧 Detected Windows – manual installation required:"
      echo "    https://github.com/r-lib/rig/releases/latest"
      ;;
    *)
      echo "⚠️  Unsupported OS ($OS). Please install rig manually."
      ;;
  esac

  command -v rig &>/dev/null \
    && echo "✅ rig installed: $(rig --version)" \
    || echo "❌ rig installation failed (install manually)."
fi

########################################################################
# 2. Conda / Miniconda installer  (auto from config)  ─────────────────
########################################################################
echo -e "\n── Conda (Python) installer ─────────────────────────────────"

# Helper: download + run Miniconda installer to a given prefix (maybe using sudo)
install_miniconda() {
  local prefix="$1" use_sudo="${2:-0}"
  local OS ARCH ARCH_LABEL PLATFORM INSTALLER URL TMP
  OS=$(uname -s)
  ARCH=$(uname -m)

  case "$ARCH" in
    x86_64|amd64) ARCH_LABEL="x86_64";;
    aarch64|arm64) ARCH_LABEL="aarch64";;
    *) echo "⚠️  Unsupported CPU architecture ($ARCH). Install Miniconda manually."; return 1;;
  esac
  case "$OS" in
    Linux)  PLATFORM="Linux" ;;
    Darwin) PLATFORM="MacOSX" ;;
    *)      echo "⚠️  Unsupported OS ($OS). Please install Miniconda manually."; return 1;;
  esac

  INSTALLER="Miniconda3-latest-${PLATFORM}-${ARCH_LABEL}.sh"
  URL="https://repo.anaconda.com/miniconda/${INSTALLER}"
  TMP="/tmp/${INSTALLER}"

  echo "🔧 Downloading ${INSTALLER} …"
  curl -Ls "$URL" -o "$TMP"

  if [[ "$use_sudo" -eq 1 ]]; then
    sudo bash "$TMP" -b -p "$prefix"
  else
    bash "$TMP" -b -p "$prefix"
  fi
  rm -f "$TMP"
  echo "✅ Miniconda installed at $prefix"

  # Add PATH export to user startup files
  add_line_if_missing "export PATH=\"$prefix/bin:\$PATH\"" "$HOME/.bashrc"
  add_line_if_missing "export PATH=\"$prefix/bin:\$PATH\"" "$HOME/.bash_profile"

  # Make it available to the remainder of this script run
  export PATH="$prefix/bin:$PATH"
}

# Decide whether we even care about Conda based on config
if [[ "${PYTHON_MGR_SELECT:-0}" -ne 1 ]]; then
  echo "↳ PYTHON_MGR_SELECT=${PYTHON_MGR_SELECT} (not Conda). Skipping Conda installation."
else
  # Treat CONDA_DIR semantics like setup_env.sh:
  # - empty => local project envs → prefer local Miniconda if no manager is present
  # - non-empty => global/shared envs → prefer global Miniconda if no manager is present
  if command -v conda &>/dev/null; then
    echo "✅ conda already installed: $(conda --version)"
  elif command -v micromamba &>/dev/null; then
    echo "✅ micromamba already installed: $(micromamba --version)"
  else
    if [[ -z "${CONDA_DIR:-}" ]]; then
      # Local mode
      LOCAL_PREFIX="${HOME}/miniconda3"
      echo "ℹ️  No conda/micromamba found. Config requests Conda with local envs (CONDA_DIR='')."
      echo "    → Installing Miniconda locally at: ${LOCAL_PREFIX}"
      install_miniconda "${LOCAL_PREFIX}" 0 || {
        echo "❌ Local Miniconda installation failed. Please install manually, or adjust config."
        exit 1
      }
    else
      # Global mode
      GLOBAL_PREFIX="/opt/miniconda3"
      echo "ℹ️  No conda/micromamba found. Config requests Conda with a global env (CONDA_DIR='${CONDA_DIR}')."
      echo "    → Attempting global Miniconda installation at: ${GLOBAL_PREFIX}"
      if install_miniconda "${GLOBAL_PREFIX}" 1; then
        :
      else
        echo "⚠️  Global install failed (likely due to sudo restrictions)."
        LOCAL_FALLBACK="${HOME}/miniconda3"
        echo "    → Falling back to local install at: ${LOCAL_FALLBACK}"
        install_miniconda "${LOCAL_FALLBACK}" 0 || {
          echo "❌ Local fallback installation also failed. Please install Miniconda manually."
          exit 1
        }
      fi
    fi
  fi
fi

########################################################################
# 3. Ensure direnv + Lmod hooks in user start-up files
########################################################################
echo -e "\n── Updating shell start-up files ─────────────────────────────"

DIR_HOOK='eval "$(direnv hook bash)"'
LMOD_HOOK='. /etc/profile.d/lmod.sh'

add_line_if_missing "$DIR_HOOK"  "$HOME/.bashrc"
add_line_if_missing "$LMOD_HOOK" "$HOME/.bashrc"
add_line_if_missing "$DIR_HOOK"  "$HOME/.bash_profile"
add_line_if_missing "$LMOD_HOOK" "$HOME/.bash_profile"

########################################################################
# 4. Run repo-local installers under env/install/*.sh
########################################################################
# Local installers should include their own compilation paths. 
echo -e "\n── Running repo-local installers (env/install/*.sh) ───────────"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="${SCRIPT_DIR}/install"
STAMP_DIR="${SCRIPT_DIR}/.install_stamps"
mkdir -p "$STAMP_DIR"

FORCE=false
for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE=true
done

shopt -s nullglob
scripts=( "${INSTALL_DIR}/"*.sh )
shopt -u nullglob

if ((${#scripts[@]} == 0)); then
  echo "ℹ️  No install scripts found in ${INSTALL_DIR} (nothing to do)."
else
  for s in "${scripts[@]}"; do
    stamp="$STAMP_DIR/$(basename "$s").done"
    if [[ -f "$stamp" && "$FORCE" == false ]]; then
      echo "↳ Skipping $(basename "$s") (already completed — use --force to re-run)"
      continue
    fi
    echo "→ Running $(basename "$s")"
    if bash "$s"; then
      touch "$stamp"
      echo "✓ Finished $(basename "$s")"
    else
      echo "❌ Failed $(basename "$s") — not stamping"
      exit 1
    fi
  done
fi

echo "✅  Setup complete – open a new shell (login or SLURM batch) to pick up the changes."
