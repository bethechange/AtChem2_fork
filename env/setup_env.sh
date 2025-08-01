#!/usr/bin/env bash
# env/setup_env.sh – cross-platform, idempotent environment bootstrap
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
VENV_DIR="$SCRIPT_DIR/.venv"
CONDA_DIR="$SCRIPT_DIR/.conda"            # new: local or global conda/mamba environment path
MODULES_DIR="$SCRIPT_DIR/modules"
ENVRC_PATH="$REPO_ROOT/.envrc"
RPROFILE_FILE="$SCRIPT_DIR/.Rprofile"

# ── Detect package manager ───────────────────────────────────────
source /etc/os-release
OS_PRETTY="${PRETTY_NAME:-$ID $VERSION_ID}"

if   command -v dnf      &>/dev/null; then PKG_MGR=dnf   ; INSTALL_CMD="dnf  -y install"
elif command -v yum      &>/dev/null; then PKG_MGR=yum   ; INSTALL_CMD="yum  -y install"
elif command -v apt-get  &>/dev/null; then PKG_MGR=apt   ; INSTALL_CMD="apt-get install -y --no-install-recommends"
elif command -v pacman   &>/dev/null; then PKG_MGR=pacman; INSTALL_CMD="pacman -S --noconfirm"
else
  echo "❌  No supported package manager (dnf|yum|apt|pacman) found." >&2
  exit 1
fi

# ── Base system packages ─────────────────────────────────────────
DNF_PACKAGES=(direnv python3 python3-venv lmod R R-devel)
YUM_PACKAGES=("${DNF_PACKAGES[@]}")
APT_PACKAGES=(direnv python3 python3-venv lmod r-base r-base-dev)
PACMAN_PACKAGES=(untested) # default for unsupported/untested environments. Use at your own risk.

PYTHON_PACKAGES=(numpy)
R_PACKAGES=(renv)              # renv always included in project env
OPENHPC_MODULES=()

# ── Optional interpreter pins (env/config.txt can override) ──────
PYTHON_VERSION="${PYTHON_VERSION:-}"
R_VERSION="${R_VERSION:-}"

# ── Manager selectors (overridable in env/config.txt) ────────────
# 0 = VENV, 1 = CONDA
PYTHON_MGR_SELECT="${PYTHON_MGR_SELECT:-0}"

# ── External overrides (env/config.txt) ──────────────────────────
CONFIG_FILE="$SCRIPT_DIR/config.txt"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  echo "✅  Using external package config from $CONFIG_FILE"
fi

# ── Select system-package list ───────────────────────────────────
case "$PKG_MGR" in
  dnf)    SYS_PACKAGES=("${DNF_PACKAGES[@]}")   ;;
  yum)    SYS_PACKAGES=("${YUM_PACKAGES[@]}")   ;;
  apt)    SYS_PACKAGES=("${APT_PACKAGES[@]}")   ;;
  pacman) SYS_PACKAGES=("${PACMAN_PACKAGES[@]}");;
esac

# ── Discover repo-local modulefiles ──────────────────────────────
LOCAL_MODULES=()
if [[ -d "$MODULES_DIR" ]]; then
  while IFS= read -r -d '' mf; do
    rel="$(realpath --relative-to="$MODULES_DIR" "$mf")"
    base="$(basename "$rel")"
    # Skip tree initializers and modulerc
    [[ "$base" == "init.lua" || "$base" == ".modulerc.lua" || "$base" == ".modulerc" ]] && continue

    name="$(cut -d/ -f1 <<<"$rel")"
    ver="$(cut -d/ -f2 <<<"$rel")"

    # handle Lua version files like atchem2/1.0.lua
    ver="${ver%.lua}"

    # handle Tcl 'modulefile' (use its parent as version)
    if [[ "$ver" == "modulefile" ]]; then
      ver="$(basename "$(dirname "$rel")")"
    fi

    [[ -n "$name" && -n "$ver" ]] && LOCAL_MODULES+=("${name}/${ver}")
  done < <(
      find "$MODULES_DIR" -type f \
        \( -name '*.lua' -o -regex '.*/[0-9][^/]*' -o -name 'modulefile' \) -print0
    )

  # de-duplicate
  IFS=$'\n' read -r -d '' -a LOCAL_MODULES < <(printf '%s\n' "${LOCAL_MODULES[@]}" | sort -u && printf '\0')
fi

# ── Conda path resolution (supports CONDA_DIR="" → local) ─────────
if [[ -z "${CONDA_DIR:-}" ]]; then
  CONDA_ENV_PATH="$SCRIPT_DIR/.conda"
else
  CONDA_ENV_PATH="$CONDA_DIR"
fi

# ── Summary ──────────────────────────────────────────────────────
join(){ local IFS=" "; echo "$*"; }
py_mgr_name() { case "${PYTHON_MGR_SELECT:-0}" in 0) echo "VENV";; 1) echo "CONDA";; *) echo "UNKNOWN";; esac; }
conda_scope() {
  if [[ "${CONDA_ENV_PATH:-}" == "$SCRIPT_DIR/.conda" ]]; then echo "local"; else echo "global"; fi
}

echo "-----------------------------------------------------------------"
echo "env/setup_env.sh will install with $PKG_MGR on $OS_PRETTY"
printf "  ▸ env folder : %s\n"   "$SCRIPT_DIR"
printf "  ▸ repo root  : %s\n"   "$REPO_ROOT"
printf "  ▸ rprofile   : %s\n"   "$RPROFILE_FILE"
printf "  ▸ system     : %s\n"   "$(join "${SYS_PACKAGES[@]}")"
printf "  ▸ python mgr : %s\n"   "$(py_mgr_name)"
if [[ "${PYTHON_MGR_SELECT:-0}" -eq 1 ]]; then
  printf "  ▸ conda path : %s (%s)\n" "$CONDA_ENV_PATH" "$(conda_scope)"
else
  printf "  ▸ venv path  : %s\n" "$VENV_DIR"
fi
printf "  ▸ pip        : %s\n"   "$(join "${PYTHON_PACKAGES[@]}")"
printf "  ▸ r pkgs     : %s\n"   "$(join "${R_PACKAGES[@]}")"
printf "  ▸ openhpc    : %s\n"   "$(join "${OPENHPC_MODULES[@]:-(none)}")"
printf "  ▸ localmod   : %s\n"   "$(join "${LOCAL_MODULES[@]:-(none)}")"
echo "-----------------------------------------------------------------"
read -rp "Proceed? [Y/n] " ans; ans=${ans:-y}; [[ $ans =~ ^[Yy]$ ]] || exit 0
echo

# Clear existing .Rprofile
rm -f "$RPROFILE_FILE"

# ── 0. Ensure .gitignore entries ───────────────────────────────
GITIGNORE_FILE="$REPO_ROOT/.gitignore"
DEFAULT_IGNORES=(
  "env/.venv"
  "env/.conda"
  "env/renv"
  "env/.Rprofile"
  "env/renv.lock"
  "env/config_template.txt"
  ".envrc"
)

# Combine defaults with optional extras from config.txt
ALL_IGNORES=("${DEFAULT_IGNORES[@]}")
if [[ -n "${GITIGNORE_ADD[*]:-}" ]]; then
  ALL_IGNORES+=("${GITIGNORE_ADD[@]}")
fi

touch "$GITIGNORE_FILE"

for entry in "${ALL_IGNORES[@]}"; do
  if ! grep -Fxq "$entry" "$GITIGNORE_FILE"; then
    echo "$entry" >> "$GITIGNORE_FILE"
    echo "➕ Added '$entry' to .gitignore"
  fi
done

# ── 1. Install system packages (sudo only here) ──────────────────
echo "🔧  Installing system packages using $PKG_MGR…"

case "$PKG_MGR" in
  apt)
    sudo apt-get update -qq
    sudo $INSTALL_CMD "${SYS_PACKAGES[@]}"
    ;;
  dnf)
    sudo dnf -y install epel-release || true  # epel may already be present
    sudo $INSTALL_CMD "${SYS_PACKAGES[@]}"
    ;;
  yum)
    sudo yum -y install epel-release || true
    sudo $INSTALL_CMD "${SYS_PACKAGES[@]}"
    ;;
  pacman)
    sudo pacman -Sy --noconfirm
    if [[ "${PACMAN_PACKAGES[*]}" == "untested" ]]; then
      echo "⚠️  pacman is marked untested; skipping system package installation."
    else
      sudo $INSTALL_CMD "${PACMAN_PACKAGES[@]}"
    fi
    ;;
  *)
    echo "❌ Unsupported package manager: $PKG_MGR" >&2
    exit 1
    ;;
esac


# ── 2. Python environment (VENV or CONDA) ────────────────────────

if [[ "${PYTHON_MGR_SELECT:-0}" -eq 0 ]]; then
  # ----- VENV path (default) -------------------------------------
  PY_CMD=${PYTHON_VERSION:+python${PYTHON_VERSION}}
  PY_CMD=${PY_CMD:-python3}

  if [[ ! -d "$VENV_DIR" ]]; then
    if "$PY_CMD" -m venv "$VENV_DIR" 2>/dev/null; then :; else
      if command -v virtualenv &>/dev/null; then
        "$PY_CMD" -m virtualenv "$VENV_DIR"
      else
        sudo $INSTALL_CMD python3-virtualenv python3-pip || true
        "$PY_CMD" -m virtualenv "$VENV_DIR"
      fi
    fi
  fi

  # shellcheck source=/dev/null
  source "$VENV_DIR/bin/activate"
  if ! command -v pip &>/dev/null; then
    "$VENV_DIR/bin/python" -m ensurepip --upgrade 2>/dev/null || true
  fi
  pip install --upgrade pip "${PYTHON_PACKAGES[@]}"

else
# ----- CONDA/MAMBA path ----------------------------------------
  # PYTHON_VERSION is ignored under Conda (Conda picks Python)
  if [[ -n "${PYTHON_VERSION:-}" ]]; then
    echo "ℹ️  PYTHON_VERSION is ignored when PYTHON_MGR_SELECT=1 (Conda)."
  fi

  # Create only if the target is the local default (env/.conda)
  is_local_conda=0
  [[ "$CONDA_ENV_PATH" == "$SCRIPT_DIR/.conda" ]] && is_local_conda=1

  if command -v conda &>/dev/null; then
    shell_name="$(basename "${SHELL:-bash}")"
    case "$shell_name" in
      zsh)  eval "$(conda shell.zsh hook 2>/dev/null)";;
      fish) eval "$(conda shell.fish hook 2>/dev/null)";;
      *)    eval "$(conda shell.bash hook 2>/dev/null)";;
    esac

    if [[ $is_local_conda -eq 1 && ! -d "$CONDA_ENV_PATH" ]]; then
      conda create -y -p "$CONDA_ENV_PATH" python
    fi

    if [[ -d "$CONDA_ENV_PATH" ]]; then
      conda activate "$CONDA_ENV_PATH"
    else
      echo "❌  CONDA_DIR points to a non-existent path: $CONDA_ENV_PATH"
      echo "    Create it (e.g. 'conda create -p $CONDA_ENV_PATH python') or leave CONDA_DIR blank for local."
      exit 1
    fi

  elif command -v micromamba &>/dev/null; then
    # micromamba is shell-agnostic: use POSIX hook
    eval "$(micromamba shell hook -s posix 2>/dev/null)"

    if [[ $is_local_conda -eq 1 && ! -d "$CONDA_ENV_PATH" ]]; then
      micromamba create -y -p "$CONDA_ENV_PATH" python
    fi

    if [[ -d "$CONDA_ENV_PATH" ]]; then
      micromamba activate -p "$CONDA_ENV_PATH"
    else
      echo "❌  CONDA_DIR points to a non-existent path: $CONDA_ENV_PATH"
      echo "    Create it (e.g. 'micromamba create -p $CONDA_ENV_PATH python') or leave CONDA_DIR blank for local."
      exit 1
    fi

  else
    echo "❌  CONDA selected but neither 'conda' nor 'micromamba' found in PATH." >&2
    echo "    Install Miniconda/Mambaforge or micromamba, or set PYTHON_MGR_SELECT=0." >&2
    exit 1
  fi

  # Use pip from the activated env to install extras
  if ! command -v pip &>/dev/null; then
    python -m ensurepip --upgrade 2>/dev/null || true
  fi
  pip install --upgrade pip "${PYTHON_PACKAGES[@]}"
fi

# ── 3. Optional R interpreter via rig ────────────────────────────
if [[ -n "$R_VERSION" && -x "$(command -v rig)" ]]; then
  rig add "$R_VERSION" || true
  rig use "$R_VERSION"
fi

# ── 3b. Guarantee a writable R library (or offer sudo) ───────────
if command -v Rscript &>/dev/null; then
  # Use the same default R would pick if R_LIBS_USER is unset
  if [[ -z ${R_LIBS_USER:-} ]]; then
    R_VER=$(Rscript -e 'cat(paste0(R.version$major,".",strsplit(R.version$minor,"[.]")[[1]][1]))')
    export R_LIBS_USER="$HOME/R/$R_VER"
  fi

  mkdir -p "$R_LIBS_USER" 2>/dev/null || true

  if [[ ! -w "$R_LIBS_USER" ]]; then
    echo -e "⚠️  $R_LIBS_USER is not writable by $(whoami)."
    read -rp "    – Install the *renv* package system-wide with sudo instead? [y/N] " ans
    if [[ ${ans,,} =~ ^y$ ]]; then
      sudo Rscript -e 'if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv", repos = "https://cloud.r-project.org")'
      echo "🔑  *renv* installed system-wide."
    else
      echo "❌  Cannot proceed without a writable library – aborting."
      exit 1
    fi
  fi
fi


# ── 4. Ensure (or update) the renv project ───────────────────────
if command -v Rscript &>/dev/null; then
  SETUP_ENV_PROJ="$SCRIPT_DIR" Rscript - "${R_PACKAGES[@]}" <<'RS'
    proj  <- Sys.getenv("SETUP_ENV_PROJ")      # absolute path: …/env
    repos <- "https://cloud.r-project.org"

    # helper -------------------------------------------------------
    msg <- function(...) cat(..., "\n", sep = "")

    # 1. Make sure renv itself is available
    if (!requireNamespace("renv", quietly = TRUE))
      install.packages("renv", repos = repos)

    # 2. Brand-new project?  Initialise bare scaffold
    if (!file.exists(file.path(proj, "renv.lock"))) {
      message("🆕  Initialising new renv project")
      renv::init(project = proj, bare = TRUE)        # creates structure and .Rprofile
      renv::snapshot(project = proj, prompt = FALSE)  # write empty lockfile
    }

    # 3. Guarantee .Rprofile exists (older repos sometimes miss it)
    rprof <- file.path(proj, ".Rprofile")
    if (!file.exists(rprof)) {
      writeLines('if (requireNamespace("renv", quietly = TRUE)) renv::load()',
                 rprof)
    }

    # 4. restore only if lockfile exists and lib out-of-sync
    lock <- file.path(proj, "renv.lock")
    if (file.exists(lock)) {
      synced <- tryCatch(renv::status(project = proj, quiet = TRUE)$synchronized,
                         error = function(e) FALSE)
      if (!synced) {
        msg("🔄  Restoring packages from renv.lock …")
        renv::restore(project = proj, prompt = FALSE)
      } else {
        msg("✅  renv library already in sync.")
      }
    } else {
      msg("ℹ️  No renv.lock yet – skipping restore.")
    }

    # 5. Install R packages requested -----------------------------------------
    extras_raw <- commandArgs(trailingOnly = TRUE)
    msg("From command line args, R sees R_PACKAGES =", if (length(extras_raw)) paste(extras_raw, collapse = " ") else "<empty>")

    if (length(extras_raw)) {
      msg("➕  Installing extras:", paste(extras_raw, collapse = ", "))
      renv::install(extras_raw, project = proj, quiet = TRUE)
      msg("📌  Snapshotting lockfile …")
      renv::snapshot(project = proj, prompt = FALSE)
    } else {
      msg("ℹ️  No extras requested.")
    }
RS
fi


# ── 5. Lmod / OpenHPC modules ------------------------------------
# ---- Hard-reset Lmod state in this shell ----
rm -rf "$HOME/.lmod.d/.cache"

# initialize Lmod if needed (same behavior as in .envrc)
if ! command -v module &>/dev/null; then
  sh=$(basename "$SHELL")
  init="/usr/share/lmod/lmod/init/${sh}"
  [[ -r "$init" ]] && . "$init"
fi

if command -v module &>/dev/null; then
  [[ -d "$MODULES_DIR" ]] && module use "$MODULES_DIR"

  for m in "${OPENHPC_MODULES[@]}"; do
    module load "$m" 2>/dev/null || echo "⚠️  Could not load $m (continuing)."
  done
  for lm in "${LOCAL_MODULES[@]}"; do
    module try-load "$lm" 2>/dev/null || module load "$lm" 2>/dev/null || true
  done
fi


# ── 6. direnv hook + .envrc --------------------------------------
if command -v direnv &>/dev/null; then
  shell_name="$(basename "$SHELL")"
  case "$shell_name" in
    bash) cfg="$HOME/.bashrc"  ; line='eval "$(direnv hook bash)"' ;;
    zsh)  cfg="$HOME/.zshrc"   ; line='eval "$(direnv hook zsh)"'  ;;
    fish) cfg="$HOME/.config/fish/config.fish"; line='direnv hook fish | source' ;;
    *)    cfg=""; echo "⚠️  Unknown shell ($shell_name): add direnv hook manually." ;;
  esac
  if [[ -n $cfg && -n $line && ! $(grep -Fx "$line" "$cfg" 2>/dev/null) ]]; then
    echo -e "\n# direnv hook added by setup_env.sh\n$line" >> "$cfg"
    echo "✅  Added direnv hook to $cfg"
  fi
fi


# ── 7. Write .envrc -----------------------------------------------
# Append the static file install location in Bash ------------------
printf '%s\n' "ROOT_PATH=$REPO_ROOT"   > "$ENVRC_PATH"
printf '%s\n' "ENV_PATH=$SCRIPT_DIR"   >> "$ENVRC_PATH"
printf '%s\n' "CONDA_PATH=$CONDA_ENV_PATH" >> "$ENVRC_PATH"

cat >>"$ENVRC_PATH" <<'EOF'

LMOD_IGNORE_CACHE=1

# ─── Python env activation (venv or conda/mamba) ──────────────────
if [ -f "$ENV_PATH/.venv/bin/activate" ]; then
  . "$ENV_PATH/.venv/bin/activate"
elif command -v conda >/dev/null 2>&1 && [ -d "$CONDA_PATH" ]; then
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh)  eval "$(conda shell.zsh hook 2>/dev/null)";;
    fish) eval "$(conda shell.fish hook 2>/dev/null)";;
    *)    eval "$(conda shell.bash hook 2>/dev/null)";;
  esac
  conda activate "$CONDA_PATH" || true
elif command -v micromamba >/dev/null 2>&1 && [ -d "$CONDA_PATH" ]; then
  eval "$(micromamba shell hook -s posix 2>/dev/null)"
  micromamba activate -p "$CONDA_PATH" || true
fi

# ---- Hard-reset Lmod state in this shell ----
rm -rf "$HOME/.lmod.d/.cache"

# Ensure Lmod is initialized, then force a fresh view
if ! command -v module >/dev/null; then
  shell=$(basename "$SHELL")
  init="/usr/share/lmod/lmod/init/${shell}"
  [ -f "$init" ] && . "$init"
fi

# ─── Auto-load repo-local modules ─────────────────────────────────
if command -v module >/dev/null; then
  [ -d "$ENV_PATH/modules" ] && module use "$ENV_PATH/modules"
EOF

# Append the module-load lines generated in Bash -------------------
for lm in "${LOCAL_MODULES[@]}"; do
  printf '  module try-load %s 2>/dev/null || module load %s 2>/dev/null || true\n' "$lm" "$lm" >> "$ENVRC_PATH"
done

# OpenHPC modules from config.txt
for om in "${OPENHPC_MODULES[@]}"; do
  printf '  module try-load %s 2>/dev/null || module load %s 2>/dev/null || true\n' "$om" "$om" >> "$ENVRC_PATH"
done

# Footer: renv + our new activate snippet
cat >> "$ENVRC_PATH" <<'EOF'
fi

# ─── renv auto-activation for all R sessions ─────────────────────
# load renv from the env folder no matter where we are in the tree
export RENV_PROJECT="$ENV_PATH"
export R_PROFILE_USER="$ENV_PATH/.Rprofile"
# controls debugging output from env/.Rprofile - set to FALSE for silent operation
export RENV_RPROFILE_VERBOSE=FALSE


# ─── renv restore on first run ────────────────────────────────────
if command -v Rscript >/dev/null && [ -f "$ENV_PATH/renv.lock" ]; then
  echo "🔧  Ensuring renv library…"
  Rscript -e 'renv::restore(project = Sys.getenv("RENV_PROJECT"), prompt = FALSE)'
fi
EOF

echo "✅  .envrc written"
command -v direnv &>/dev/null && direnv allow "$REPO_ROOT" || true


# ── 8. (new) Write / replace env/.Rprofile  ─────────────────────
cat >"$RPROFILE_FILE" <<'RPROFILE_EOF'
## env/.Rprofile — robust, with fallback to renv/activate.R
local({
  fallback <- function() {
    message("[env/.Rprofile] Fallback: sourcing renv/activate.R")
    activate <- file.path("renv", "activate.R")
    if (file.exists(activate)) {
      source(activate)
    } else {
      message("[env/.Rprofile] Could not find renv/activate.R — renv will not be loaded")
    }
    invisible(NULL)
  }

  tryCatch({
    ## ----------------------------------------------------
    ##  CONFIG
    ## ----------------------------------------------------
    verbose <- as.logical(Sys.getenv("RENV_RPROFILE_VERBOSE", "TRUE"))
    say     <- function(...) if (verbose) message("[env/.Rprofile] ", ...)

    ## ----------------------------------------------------
    ##  Locate this file + project root
    ## ----------------------------------------------------
    this_file <- Sys.getenv("R_PROFILE_USER", unset = "")
    if (!nzchar(this_file)) {
      this_file <- tryCatch(sys.frame(1)$ofile,       error = function(e) "")
      if (!nzchar(this_file))
        this_file <- tryCatch(parent.frame(2)$ofile,  error = function(e) "")
    }

    if (!nzchar(this_file)) {
      say("ERROR – cannot determine path of .Rprofile → abort")
      return(invisible(NULL))
    }

    profile_dir <- dirname(normalizePath(this_file, winslash = "/"))
    project_root <- Sys.getenv("RENV_PROJECT", unset = profile_dir)  # fall back

    say("profile_dir  = ", profile_dir)
    say("project_root = ", project_root)

    ## ----------------------------------------------------
    ##  Show library paths BEFORE
    ## ----------------------------------------------------
    if (verbose) {
      say(".libPaths() BEFORE:")
      for (p in .libPaths()) say("  - ", p)
    }

    ## ----------------------------------------------------
    ##  Activate renv
    ## ----------------------------------------------------
    if (requireNamespace("renv", quietly = TRUE)) {
      say("renv found → renv::load()")
      tryCatch(
        renv::load(project_root, quiet = !verbose),
        error = function(e) say("renv::load() ERROR: ", conditionMessage(e))
      )
    } else {
      say("renv NOT found in default libraries!")
    }

    ## ----------------------------------------------------
    ##  Show library paths AFTER
    ## ----------------------------------------------------
    message("R .libPaths() available:")
    for (p in .libPaths()) message("  - ", p)
    invisible(NULL)

  }, error = function(e) {
    message("[env/.Rprofile] ERROR: ", conditionMessage(e))
    fallback()
    invisible(NULL)
  })
})

RPROFILE_EOF
echo "✅  Wrote $RPROFILE_FILE"


# ── 9. Final report ──────────────────────────────────────────────
echo -e "\n✅  Environment ready:"
cd "$SCRIPT_DIR"
if command -v direnv &>/dev/null; then
  eval "$(direnv export bash)"
fi
command -v Rscript &>/dev/null && echo "    • R      : $(Rscript -e 'cat(R.version$version.string)')"
if [[ "${PYTHON_MGR_SELECT:-0}" -eq 0 ]]; then
  echo "    • Python     : $(which python)  (venv)"
else
  echo "    • Python     : $(which python)  (conda @ $CONDA_ENV_PATH)"
fi
echo "    • Modulepath : $MODULEPATH"
echo "    • Modules available:"
command -v module &>/dev/null && module avail 2>&1 | sed 's/^/      - /'
echo
echo "Note that R packages installed with bioconductor may not be installed in the renv library. Check for these and manually move them into renv's library folder if so."
echo "Note also that dependency folders may grow very large. We recommend excluding .venv/.conda and renv subfolders separately from git repositories using .gitignore (env/.venv/*, env/renv/*). Module folders may be excluded as well depending."
