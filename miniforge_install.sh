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

# Cleanup handler for temporary files
TMP_INSTALLER=""
cleanup() { [[ -n "$TMP_INSTALLER" && -f "$TMP_INSTALLER" ]] && rm -f "$TMP_INSTALLER"; }
trap cleanup EXIT INT TERM

if [ -n "$SHELL" ]; then
    CURRENT_SHELL=$(basename "$SHELL")
elif [ -n "$0" ]; then
    CURRENT_SHELL=$(basename "$0")
else
    CURRENT_SHELL=$(ps -p $$ | awk 'NR==2 {print $NF}' 2>&1 | xargs basename)
fi

# Defaults
EXPORT_DIR="${EXPORT_DIR:-$HOME/conda_migration_exports}"
MINIFORGE_PREFIX="$HOME/miniforge3"
ASSUME_YES=false
DRY_RUN=false
NO_INIT=false
NO_INSTALL=false
NO_IMPORT=false
INIT_ONLY=false
IMPORT_ONLY=false
DO_TEST_INSTALL=false
DO_TEST_INIT=false

# Helpers
log() { printf "[%s] %s\n" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*"; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*"; }
err() { log "ERROR: $*"; exit 1; }
dry_run_msg() { $DRY_RUN && log "DRY-RUN: $*"; }

confirm() {
    if $ASSUME_YES; then return 0; fi
    read -r -p "$1 [y/N]: " resp
    case "$resp" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

usage() {
    cat <<EOF
Usage: $0 [options]
Dirs:
    --miniforge-prefix DIR  Installation prefix (default: ~/miniforge3)
    --export-dir PATH       Directory with exported YAMLs (default: ~/conda_migration_exports)

Install / Init / Import:
    --no-install            Skip Miniforge installation
    --init-only             Only (re)initialize shells/config for existing prefix
    --no-init               Skip shell initialization
    --import-only           Only import exported environments
    --no-import             Skip exported environments import

Test:
    --test-install          Verify presence of binaries and print versions
    --test-init             Inspect shell RC files for Miniforge conda init blocks

Common:
    --yes                   Assume yes for prompts
    --dry-run               Show actions without performing them
    --help                  Show this help

Environment variables:
  MINIFORGE_PREFIX          Root of Miniforge installation
  EXPORT_DIR                Directory for exported environments
EOF
}

extract_env_name() {
    local file="$1"
    awk '/^[[:space:]]*name[[:space:]]*:/ {
        gsub(/^[[:space:]]*name[[:space:]]*:[[:space:]]*/, "")
        gsub(/[[:space:]]*#.*$/, "")
        gsub(/^["'\'']|["'\'']$/, "")
        gsub(/[[:space:]]*$/, "")
        print
        exit
    }' "$file"
}

validate_yaml() {
    local file="$1"
    [[ -f "$file" && -s "$file" ]] || return 1
    grep -q "^name:" "$file" 2>/dev/null || return 1
    grep -q "^dependencies:" "$file" 2>/dev/null || return 1
    return 0
}

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) ASSUME_YES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --miniforge-prefix) MINIFORGE_PREFIX="$2"; shift 2 ;;
        --export-dir) EXPORT_DIR="$2"; shift 2 ;;

        --no-install) NO_INSTALL=true; shift ;;
        --no-init) NO_INIT=true; shift ;;
        --no-import) NO_IMPORT=true; shift ;;

        --init-only) INIT_ONLY=true; shift ;;
        --import-only) IMPORT_ONLY=true; shift ;;

        --test-install) DO_TEST_INSTALL=true; shift ;;
        --test-init) DO_TEST_INIT=true; shift ;;
        --help) usage; exit 0 ;;
        *) warn "Unknown option: $1"; usage; exit 1 ;;
    esac
done

$DRY_RUN && echo "🔍 DRY-RUN MODE: No changes will be made"
info "Miniforge prefix: $MINIFORGE_PREFIX"
info "Export dir:       $EXPORT_DIR"

# Resolve possible flag conflicts.
# Stages.
DO_INSTALL=true
DO_INIT=true
DO_IMPORT=true
# Respect explicit NO_*
$NO_INSTALL && DO_INSTALL=false
$NO_INIT && DO_INIT=false
$NO_IMPORT && DO_IMPORT=false
# Apply *ONLY* modifiers, which are mutually exclusive and override others.
if $INIT_ONLY && $IMPORT_ONLY; then
    err "Flags conflict: --init-only cannot be combined with --import-only."
fi

if $INIT_ONLY; then
    # Only run INIT (not install, not import)
    DO_INSTALL=false
    DO_IMPORT=false
    DO_INIT=true
    if $NO_INIT || $NO_INSTALL || $NO_IMPORT; then
        err "Flags conflict: --init-only cannot be combined with any --no-* flags."
    fi
fi

if $IMPORT_ONLY; then
    # Only run IMPORT (not install, not init)
    DO_INSTALL=false
    DO_INIT=false
    DO_IMPORT=true
    if $NO_IMPORT || $NO_INSTALL || $NO_INIT; then
        err "Flags conflict: --import-only cannot be combined with any --no-* flags."
    fi
fi

# Sanity checks:
# - INIT without binaries is pointless: warn if INIT is requested but conda missing at prefix.
# - IMPORT requires at least conda/mamba at prefix.
if $DO_INIT || $DO_IMPORT || $DO_TEST_INSTALL || $DO_TEST_INIT; then
    [[ -d "$MINIFORGE_PREFIX" ]] || {
        if $DO_INSTALL; then
            :
        else
            warn "Prefix '$MINIFORGE_PREFIX' does not exist yet."
            warn "Requested actions: init=$DO_INIT import=$DO_IMPORT; these require an installed Miniforge at the prefix."
        fi
    }
fi

# Print the final install plan
PLAN=()
$DO_INSTALL && PLAN+=("install")
$DO_INIT && PLAN+=("init")
$DO_IMPORT && PLAN+=("import")
${DO_TEST_INSTALL} && PLAN+=("test-install")
${DO_TEST_INIT} && PLAN+=("test-init")
info "Execution plan: ${PLAN[*]:-(no-ops)}"

# Read-only tests
test_install() {
    local ok=true
    for b in "$MINIFORGE_PREFIX/bin/conda" "$MINIFORGE_PREFIX/bin/mamba"; do
        if [[ -x "$b" ]]; then
            "$b" --version || true
        else
            warn "Missing: $b"; ok=false
        fi
    done
    if $ok; then info "✅ Miniforge binaries present."; else warn "Some binaries missing."; fi
}
test_init() {
    local hit=false
    local pfx_escaped
    pfx_escaped=$(printf '%s' "$MINIFORGE_PREFIX" | sed -e 's/[].[^$\\*/]/\\&/g')
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config/fish/config.fish"; do
        [[ -f "$rc" ]] || continue
        if grep -E "conda (initialize|init)" "$rc" | grep -q "$pfx_escaped"; then
            info "✅ Init block references Miniforge in: $rc"; hit=true
        fi
    done
    if ! $hit; then
        warn "Did not find Miniforge conda init blocks in common RC files."
        warn "Initialization may be incomplete for interactive shells."
    fi
}

# --init-only short-circuit
if $INIT_ONLY; then
    info "--init-only: initializing shells for existing prefix"
    if $DRY_RUN; then
        dry_run_msg "Would run: $MINIFORGE_PREFIX/bin/conda init --all"
        dry_run_msg "Would configure: auto_activate_base false; channel_priority strict; add conda-forge"
        dry_run_msg "Would run: $MINIFORGE_PREFIX/bin/mamba shell init --shell $CURRENT_SHELL (if present)"
    else
        [[ -x "$MINIFORGE_PREFIX/bin/conda" ]] || err "conda not found at prefix; install first."
        "$MINIFORGE_PREFIX/bin/conda" init --all || warn "conda init returned non-zero"
        "$MINIFORGE_PREFIX/bin/conda" config --set auto_activate_base false || true
        "$MINIFORGE_PREFIX/bin/conda" config --add channels conda-forge || true
        "$MINIFORGE_PREFIX/bin/conda" config --set channel_priority strict || true
        [[ -x "$MINIFORGE_PREFIX/bin/mamba" ]] && "$MINIFORGE_PREFIX/bin/mamba" init --shell "$CURRENT_SHELL" 2>/dev/null || true
    fi
    $DO_TEST_INIT && test_init
    exit 0
fi

# --import-only short-circuit
if $IMPORT_ONLY; then
    info "--import-only: importing exported environments"
    DO_INSTALL=false
    DO_INIT=false
fi

# Deactivate any existing env before installation
if command -v conda &>/dev/null; then
    $DRY_RUN && dry_run_msg "Would deactivate any active conda environment" || { info "Deactivating any active conda environment..."; conda deactivate 2>/dev/null || true; }
elif command -v mamba &>/dev/null; then
    $DRY_RUN && dry_run_msg "Would deactivate any active mamba environment" || { info "Deactivating any active mamba environment..."; mamba deactivate 2>/dev/null || true; }
fi

# Install Miniforge (optionally skip init)
if $DO_INSTALL; then
    if confirm "Install Miniforge to $MINIFORGE_PREFIX now?"; then
        DOWNLOAD_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-$(uname -m).sh"
        TMP_INSTALLER="/tmp/miniforge_installer_$$.sh"
        if $DRY_RUN; then
            dry_run_msg "Would download: $DOWNLOAD_URL"
            dry_run_msg "Would save to: $TMP_INSTALLER"
            dry_run_msg "Would run: bash $TMP_INSTALLER -b -p $MINIFORGE_PREFIX"
        else
            info "Downloading Miniforge installer: $DOWNLOAD_URL"
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL "$DOWNLOAD_URL" -o "$TMP_INSTALLER" || err "Failed to download Miniforge installer with curl."
            elif command -v wget >/dev/null 2>&1; then
                wget -q -O "$TMP_INSTALLER" "$DOWNLOAD_URL" || err "Failed to download Miniforge installer with wget."
            else
                err "Neither curl nor wget found. Install one and re-run."
            fi
            chmod +x "$TMP_INSTALLER"
            info "Running Miniforge installer (batch mode; prefix: $MINIFORGE_PREFIX)"
            bash "$TMP_INSTALLER" -b -p "$MINIFORGE_PREFIX" || err "Miniforge installer failed."
        fi
    else
        info "Skipped Miniforge installation."
    fi
fi

# Initialise shells
if $DO_INIT; then
    if $DRY_RUN; then
        dry_run_msg "Would initialize conda for all shells at $MINIFORGE_PREFIX"
        dry_run_msg "Would set: auto_activate_base=false; channel_priority=strict; add conda-forge"
        dry_run_msg "Would run: mamba shell init --shell $CURRENT_SHELL (if present)"
    else
        [[ -x "$MINIFORGE_PREFIX/bin/conda" ]] || err "conda not found at prefix ($MINIFORGE_PREFIX). Cannot initialize."
        info "Initialising conda for your shell(s)"
        "$MINIFORGE_PREFIX/bin/conda" init --all || warn "conda init returned non-zero; you may need to initialize manually."
        info "Disabling auto-activation of base environment"
        "$MINIFORGE_PREFIX/bin/conda" config --set auto_activate_base false || true
        info "Configure conda-forge and strict priority"
        "$MINIFORGE_PREFIX/bin/conda" config --add channels conda-forge || true
        "$MINIFORGE_PREFIX/bin/conda" config --set channel_priority strict || true
        info "Initialising mamba (if present)"
        [[ -x "$MINIFORGE_PREFIX/bin/mamba" ]] && "$MINIFORGE_PREFIX/bin/mamba" init --shell "$CURRENT_SHELL" 2>/dev/null || true
    fi
fi

# Import exported environments (only if installer ran or prefix exists)
if $DO_IMPORT; then
    if [[ -x "$MINIFORGE_PREFIX/bin/conda" || -x "$MINIFORGE_PREFIX/bin/mamba" ]]; then
        shopt -s nullglob
        YML_FILES=("$EXPORT_DIR"/*.yml)
        if (( ${#YML_FILES[@]} > 0 )); then
            info "Found ${#YML_FILES[@]} exported environment file(s) in $EXPORT_DIR"
            info "Pre-validating YAML files..."
            VALID_FILES=(); INVALID_FILES=()
            for file in "${YML_FILES[@]}"; do
                if validate_yaml "$file"; then VALID_FILES+=("$file"); else INVALID_FILES+=("$file"); warn "Invalid YAML: $(basename "$file")"; fi
            done
            (( ${#VALID_FILES[@]} > 0 )) || warn "No valid YAML files found to import."
            if (( ${#VALID_FILES[@]} > 0 )) && confirm "Create/update environments from exported YAML files?"; then
                FAILED_IMPORTS=(); SUCCESSFUL_IMPORTS=()
                for file in "${VALID_FILES[@]}"; do
                    env_name=$(extract_env_name "$file")
                    if [[ -z "$env_name" ]]; then warn "Could not determine env name for $file; skipping."; FAILED_IMPORTS+=("$(basename "$file")"); continue; fi
                    if $DRY_RUN; then
                        dry_run_msg "Would process $file (env: $env_name)"
                        if [[ -x "$MINIFORGE_PREFIX/bin/mamba" ]]; then dry_run_msg "Would create/update environment using mamba"; else dry_run_msg "Would create/update environment using conda"; fi
                    else
                        info "Processing $file (env: $env_name)"
                        if [[ -x "$MINIFORGE_PREFIX/bin/mamba" ]]; then ENV_MANAGER="$MINIFORGE_PREFIX/bin/mamba"; else ENV_MANAGER="$MINIFORGE_PREFIX/bin/conda"; fi
                        if "$ENV_MANAGER" env list | grep -qE "^\s*${env_name}\s+" 2>/dev/null; then
                            info "Updating existing environment $env_name"
                            if "$ENV_MANAGER" env update -f "$file" 2>&1 | tee /tmp/conda_update_$$.log; then SUCCESSFUL_IMPORTS+=("$env_name"); else warn "Failed to update $env_name (see /tmp/conda_update_$$.log)"; FAILED_IMPORTS+=("$env_name"); fi
                        else
                            info "Creating environment $env_name"
                            if "$ENV_MANAGER" env create -f "$file" 2>&1 | tee /tmp/conda_create_$$.log; then SUCCESSFUL_IMPORTS+=("$env_name"); else warn "Failed to create $env_name (see /tmp/conda_create_$$.log)"; FAILED_IMPORTS+=("$env_name"); fi
                        fi
                    fi
                done
                if ! $DRY_RUN; then
                    echo ""
                    echo "════════════════════════════════════════════════════════════"
                    echo "Import Summary"
                    echo "════════════════════════════════════════════════════════════"
                    echo "✅ Successful: ${#SUCCESSFUL_IMPORTS[@]}"; for env in "${SUCCESSFUL_IMPORTS[@]}"; do echo "   - $env"; done
                    if (( ${#FAILED_IMPORTS[@]} > 0 )); then
                        echo ""
                        echo "❌ Failed: ${#FAILED_IMPORTS[@]}"
                        for env in "${FAILED_IMPORTS[@]}"; do
                            echo "   - $env"
                        done
                        echo ""
                        warn "Some environments failed to import. Check the logs above."
                        warn "You can retry manually with: mamba env create -f $EXPORT_DIR/<env>.yml"
                    fi
                fi
            else
                info "Skipped environment import."
            fi
        else
            warn "No exported YAML files found in $EXPORT_DIR"
            info "If you have exports elsewhere, set EXPORT_DIR environment variable:"
            info "  export EXPORT_DIR=/path/to/your/exports"
            info "  $0"
        fi
    else
        warn "Miniforge not present at prefix yet; skipping import."
    fi
fi

if ! $DRY_RUN; then
    if [[ -x "$MINIFORGE_PREFIX/bin/mamba" ]]; then
        "$MINIFORGE_PREFIX/bin/mamba" info || true
        "$MINIFORGE_PREFIX/bin/mamba" env list || true
    else
        "$MINIFORGE_PREFIX/bin/conda" info || true
        "$MINIFORGE_PREFIX/bin/conda" env list || true
    fi
else
    dry_run_msg "Would show conda/mamba info and environment list"
fi

$DO_TEST_INSTALL && test_install
$DO_TEST_INIT && test_init

echo ""
echo "✅ Miniforge installation complete!"
if $DRY_RUN; then
    echo "🔍 This was a dry-run. No actual changes were made."
    echo "   Run without --dry-run to perform the actual installation."
else
    echo ""
    echo "Next steps:"
    echo "  1. Restart your terminal (or run: source ~/.bashrc)"
    echo "  2. Verify installation: mamba --version"
    echo "  3. Activate an environment: mamba activate <env_name>"
    echo ""
    echo "Your exports are preserved in: $EXPORT_DIR"
fi