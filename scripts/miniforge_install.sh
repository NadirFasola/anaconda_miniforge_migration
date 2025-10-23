#!/usr/bin/env bash
# =============================================================================
# MINIFORGE INSTALLER
# =============================================================================
# Part of a guided bash script to help migrating from Anaconda to Miniforge.
# Read the script before running.
# It will ask for confirmation before destructive steps.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

EXPORT_DIR="${EXPORT_DIR:-$HOME/conda_migration_exports}"
MINIFORGE_PREFIX="${MINIFORGE_PREFIX:-$HOME/miniforge3}"

ASSUME_YES=false
DRY_RUN=false
SKIP_BASE=false

NO_INSTALL=false
NO_INIT=false
NO_IMPORT=false

INSTALL_ONLY=false
INIT_ONLY=false
IMPORT_ONLY=false

DO_TEST_INSTALL=false
DO_TEST_INIT=false

TMP_INSTALLER=""
cleanup() { [[ -n "$TMP_INSTALLER" && -f "$TMP_INSTALLER" ]] && rm -f -- "$TMP_INSTALLER"; }
trap cleanup EXIT INT TERM

if [[ -n "${SHELL:-}" ]]; then
  CURRENT_SHELL="$(basename "$SHELL")"
else
  CURRENT_SHELL="$(ps -o comm= -p $$ 2>/dev/null | xargs basename || echo bash)"
fi

# ------------------------------ Logging --------------------------------------
ts()   { date +%Y-%m-%dT%H:%M:%S%z; }
log()  { printf "[%s] %s\n" "$(ts)" "$*"; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*"; }
err()  { log "ERROR: $*"; exit 1; }

# ------------------------------ Small Helpers --------------------------------
confirm() {
  $ASSUME_YES && return 0
  local q="${1:-Proceed?} [y/N]: "
  read -r -p "$q" resp || true
  case "$resp" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

do_run() {
  # do_run "desc" -- cmd...
  local desc="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  if $DRY_RUN; then
    log "DRY-RUN: $desc"
    [[ $# -gt 0 ]] && log "DRY-RUN: would run: $*"
    return 0
  fi
  [[ -n "$desc" ]] && info "$desc"
  [[ $# -gt 0 ]] && "$@"
}

# ------------------------------ Argparse -------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Dirs:
  --miniforge-prefix DIR   Install prefix (default: $HOME/miniforge3)
  --export-dir PATH        Exported YAML directory (default: $HOME/conda_migration_exports)

Stages:
  --no-install             Skip Miniforge installation
  --no-init                Skip shell initialization
  --no-import              Skip environment import
  --install-only           Only install (no init, no import)
  --init-only              Only init (no install, no import)
  --import-only            Only import (no install, no init)

Import:
  --skip-base              Do not create/update the 'base' environment

Diagnostics:
  --test-install           Show presence/versions of binaries
  --test-init              Check RC files for init blocks

Common:
  --yes                    Assume yes for prompts
  --dry-run                Print actions without changing the system
  --help                   This help

Env vars:
  MINIFORGE_PREFIX, EXPORT_DIR mirror their flags when set.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --miniforge-prefix) MINIFORGE_PREFIX="$2"; shift 2 ;;
    --export-dir)       EXPORT_DIR="$2"; shift 2 ;;
    --no-install)       NO_INSTALL=true; shift ;;
    --no-init)          NO_INIT=true; shift ;;
    --no-import)        NO_IMPORT=true; shift ;;
    --install-only)     INSTALL_ONLY=true; shift ;;
    --init-only)        INIT_ONLY=true; shift ;;
    --import-only)      IMPORT_ONLY=true; shift ;;
    --skip-base)        SKIP_BASE=true; shift ;;
    --test-install)     DO_TEST_INSTALL=true; shift ;;
    --test-init)        DO_TEST_INIT=true; shift ;;
    --yes)              ASSUME_YES=true; shift ;;
    --dry-run)          DRY_RUN=true; shift ;;
    --help|-h)          usage; exit 0 ;;
    *) warn "Unknown option: $1"; usage; exit 1 ;;
  esac
done

$DRY_RUN && log "🔧 DRY-RUN MODE ENABLED"

# ------------------------------ Stage Plan -----------------------------------
DO_INSTALL=true; DO_INIT=true; DO_IMPORT=true

# Explicit NO_* toggles
$NO_INSTALL && DO_INSTALL=false
$NO_INIT    && DO_INIT=false
$NO_IMPORT  && DO_IMPORT=false

# Only-modes are mutually exclusive and override others
only_count=0
$INSTALL_ONLY && ((only_count++))
$INIT_ONLY    && ((only_count++))
$IMPORT_ONLY  && ((only_count++))
(( only_count > 1 )) && err "Pick at most one: --install-only / --init-only / --import-only."

if $INSTALL_ONLY; then DO_INSTALL=true; DO_INIT=false; DO_IMPORT=false; fi
if $INIT_ONLY;    then DO_INSTALL=false; DO_INIT=true;  DO_IMPORT=false; fi
if $IMPORT_ONLY;  then DO_INSTALL=false; DO_INIT=false; DO_IMPORT=true;  fi

plan=()
$DO_INSTALL && plan+=("install")
$DO_INIT    && plan+=("init")
$DO_IMPORT  && plan+=("import${SKIP_BASE:+ (skip base)}")
$DO_TEST_INSTALL && plan+=("test-install")
$DO_TEST_INIT    && plan+=("test-init")

info "Execution plan: ${plan[*]:-(no-ops)}"
info "Miniforge prefix: $MINIFORGE_PREFIX"
info "Export dir:       $EXPORT_DIR"

# ------------------------------ Paths / Binaries Helpers ---------------------
have() { command -v "$1" >/dev/null 2>&1; }

conda_bin() {
  local c="$MINIFORGE_PREFIX/bin/conda"
  [[ -x "$c" ]] && { echo "$c"; return; }
  have conda && { command -v conda; return; }
  echo ""
}
mamba_bin() {
  local m="$MINIFORGE_PREFIX/bin/mamba"
  [[ -x "$m" ]] && { echo "$m"; return; }
  have mamba && { command -v mamba; return; }
  echo ""
}

resolve_envmgr() {
  local m; m="$(mamba_bin)"
  if [[ -n "$m" ]]; then echo "$m"; else echo "$(conda_bin)"; fi
}

# ----------------------- YAML-Parsing Helpers --------------------------------
extract_env_name() {
  # Extracts first "name: ..." token (trim comments/quotes/space)
  local file="$1"
  awk '/^[[:space:]]*name[[:space:]]*:/{
    sub(/^[[:space:]]*name[[:space:]]*:[[:space:]]*/,"")
    sub(/[[:space:]]*#.*$/,"")
    sub(/^["'"'"']|["'"'"']$/,"")
    sub(/[[:space:]]*$/,"")
    print; exit
  }' "$file"
}

validate_yaml() {
  local file="$1"
  [[ -f "$file" && -s "$file" ]] || return 1
  grep -Eq '^[[:space:]]*name:' "$file" || return 1
  grep -Eq '^[[:space:]]*dependencies:' "$file" || return 1
  # check at least one dash following dependencies section
  awk '
    /^dependencies:/ {inDeps=1; next}
    /^[^[:space:]-]/ {inDeps=0}
    inDeps && $0 ~ /^[[:space:]]*-/ {found=1}
    END{exit(found?0:1)}
  ' "$file"
}

# ------------------------------ Install Helpers ------------------------------
asset_name() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in
    Linux)  os="Linux" ;;
    Darwin) os="MacOSX" ;;
    *)      err "Unsupported OS: $os" ;;
  esac
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) err "Unsupported arch: $arch" ;;
  esac
  printf "Miniforge3-%s-%s.sh" "$os" "$arch"
}

download_installer() {
  local asset url
  asset="$(asset_name)"
  url="https://github.com/conda-forge/miniforge/releases/latest/download/${asset}"
  TMP_INSTALLER="/tmp/miniforge_installer_$$.sh"
  if $DRY_RUN; then
    log "DRY-RUN: download $url"
    log "DRY-RUN: save to $TMP_INSTALLER"
    return 0
  fi
  info "Downloading Miniforge: $url"
  if have curl; then
    curl -fsSL "$url" -o "$TMP_INSTALLER" || err "curl download failed"
  elif have wget; then
    wget -q -O "$TMP_INSTALLER" "$url" || err "wget download failed"
  else
    err "Neither curl nor wget found."
  fi
  chmod +x "$TMP_INSTALLER"
}

run_installer() {
  if $DRY_RUN; then
    log "DRY-RUN: bash $TMP_INSTALLER -b -p $MINIFORGE_PREFIX"
  else
    info "Running Miniforge installer at prefix: $MINIFORGE_PREFIX"
    bash "$TMP_INSTALLER" -b -p "$MINIFORGE_PREFIX" || err "Installer failed"
  fi
}

# ------------------------------ Init Helpers ---------------------------------
conda_init_all() {
  local c; c="$(conda_bin)"
  [[ -n "$c" ]] || { warn "conda not found; cannot init."; return 1; }
  do_run "Initializing conda for all shells" -- "$c" init --all || warn "conda init returned non-zero"
  do_run "Disabling auto_activate_base" -- "$c" config --set auto_activate_base false || true
  do_run "Configuring conda-forge + strict channel priority" -- "$c" config --add channels conda-forge || true
  do_run "Configuring channel_priority strict" -- "$c" config --set channel_priority strict || true

  local m; m="$(mamba_bin)"
  if [[ -n "$m" ]]; then
    do_run "mamba shell init for ${CURRENT_SHELL}" -- "$m" init --shell "$CURRENT_SHELL" 2>/dev/null || true
  fi
}

# ------------------------------ Import Helpers -------------------------------
import_envs() {
  local envmgr file env_name exists
  [[ -d "$EXPORT_DIR" ]] || { warn "Export dir not found: $EXPORT_DIR"; return; }

  shopt -s nullglob
  mapfile -t files < <(printf "%s\n" "$EXPORT_DIR"/*.yml)
  ((${#files[@]}==0)) && { warn "No YAML files found in $EXPORT_DIR"; return; }

  # Validate first
  local -a valid=() invalid=()
  for file in "${files[@]}"; do
    if validate_yaml "$file"; then valid+=("$file"); else invalid+=("$file"); warn "Invalid YAML: $(basename "$file")"; fi
  done
  ((${#valid[@]}==0)) && { warn "No valid YAML files to import."; return; }

  envmgr="$(resolve_envmgr)"
  [[ -n "$envmgr" ]] || { warn "No conda/mamba found at prefix; cannot import."; return; }

  info "Importing ${#valid[@]} environment file(s) from $EXPORT_DIR"
  local -a succ=() fail=()
  for file in "${valid[@]}"; do
    env_name="$(extract_env_name "$file")"
    if [[ -z "$env_name" ]]; then warn "Skip (cannot read env name): $(basename "$file")"; fail+=("$(basename "$file")"); continue; fi
    if $SKIP_BASE && [[ "$env_name" == "base" ]]; then info "Skipping 'base' due to --skip-base"; continue; fi

    exists=false
    if "$envmgr" env list 2>/dev/null | grep -qE "^[[:space:]]*${env_name}[[:space:]]"; then exists=true; fi

    if $DRY_RUN; then
      if $exists; then log "DRY-RUN: would update env '$env_name' from $(basename "$file")"
      else log "DRY-RUN: would create env '$env_name' from $(basename "$file")"; fi
      continue
    fi

    if $exists; then
      info "Updating env: $env_name"
      if "$envmgr" env update -f "$file" 2>&1 | tee "/tmp/conda_update_$$_${env_name}.log"; then succ+=("$env_name"); else warn "Failed update: $env_name"; fail+=("$env_name"); fi
    else
      info "Creating env: $env_name"
      if "$envmgr" env create -f "$file" 2>&1 | tee "/tmp/conda_create_$$_${env_name}.log"; then succ+=("$env_name"); else warn "Failed create: $env_name"; fail+=("$env_name"); fi
    fi
  done

  if ! $DRY_RUN; then
    echo ""
    echo "============================================================"
    echo "Import Summary"
    echo "============================================================"
    echo "Successful: ${#succ[@]}"; for e in "${succ[@]}";   do echo "  - $e"; done
    if ((${#fail[@]})); then
      echo "Failed:     ${#fail[@]}"; for e in "${fail[@]}"; do echo "  - $e"; done
      warn "Some environments failed; see /tmp/conda_{create,update}_$$_* logs."
    fi
  else
    log "DRY-RUN: would process ${#valid[@]} env(s)."
  fi
}

# ------------------------------ Diagnostics ----------------------------------
test_install() {
  local ok=true
  for b in "$MINIFORGE_PREFIX/bin/conda" "$MINIFORGE_PREFIX/bin/mamba"; do
    if [[ -x "$b" ]]; then "$b" --version || true; else warn "Missing: $b"; ok=false; fi
  done
  $ok && info "Miniforge binaries present." || warn "Some binaries missing."
}

test_init() {
  local hit=false
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config/fish/config.fish"; do
    [[ -f "$rc" ]] || continue
    if grep -Eiq 'conda (initialize|init)' "$rc"; then info "Init block found in: $rc"; hit=true; fi
  done
  $hit || warn "Did not find conda init blocks in common RC files."
}

# ------------------------------ INSTALL --------------------------------------
if $DO_INSTALL; then
  if confirm "Install Miniforge to '$MINIFORGE_PREFIX' now?"; then
    download_installer
    run_installer
  else
    info "Skipped Miniforge installation."
  fi
fi

# ------------------------------ INIT -----------------------------------------
if $DO_INIT; then
  conda_init_all || true
fi

# ------------------------------ IMPORT ---------------------------------------
if $DO_IMPORT; then
  import_envs
fi

# ------------------------------ DIAGNOSTICS ----------------------------------
if ! $DRY_RUN; then
  if [[ -x "$MINIFORGE_PREFIX/bin/mamba" ]]; then
    "$MINIFORGE_PREFIX/bin/mamba" info || true
    "$MINIFORGE_PREFIX/bin/mamba" env list || true
  elif [[ -x "$MINIFORGE_PREFIX/bin/conda" ]]; then
    "$MINIFORGE_PREFIX/bin/conda" info || true
    "$MINIFORGE_PREFIX/bin/conda" env list || true
  fi
else
  log "DRY-RUN: would show conda/mamba info and env list"
fi

$DO_TEST_INSTALL && test_install
$DO_TEST_INIT && test_init

# ------------------------------ Epilogue -------------------------------------
echo ""
echo "✅ Miniforge installation procedure complete."
if $DRY_RUN; then
  echo "🔧 This was a dry run. No changes were made."
  echo "   Re-run without --dry-run to perform actions."
else
  echo "⚠️  Restart your shell before using Miniforge."
  echo ""
  echo "Next steps:"
  echo "  1) Close and reopen your terminal"
  echo "  2) Verify: mamba --version"
  echo "  3) Activate an env: mamba activate <env_name>"
  echo ""
  echo "Your exports live in: $EXPORT_DIR"
fi