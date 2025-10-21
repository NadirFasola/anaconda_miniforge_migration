#!/usr/bin/env bash
# =============================================================================
# ANACONDA UNINSTALLER
# =============================================================================
# Part of a guided bash script to help migrating from Anaconda to Miniforge.
# Read the script before running.
# It will ask for confirmation before destructive steps.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# Track if export is in progress
EXPORT_IN_PROGRESS=false
CURRENT_EXPORT_FILE=""

cleanup() {
    # If we were interrupted during an export, warn about potential partial file
    if $EXPORT_IN_PROGRESS && [[ -n "$CURRENT_EXPORT_FILE" ]] && [[ -f "$CURRENT_EXPORT_FILE" ]]; then
        warn "Export was interrupted. File may be incomplete: $CURRENT_EXPORT_FILE"
        warn "Consider deleting it and re-running the export."
    fi
}
trap cleanup EXIT INT TERM

if [ -n "${SHELL:-}" ]; then
    CURRENT_SHELL=$(basename "$SHELL")
elif [ -n "${0:-}" ]; then
    CURRENT_SHELL=$(basename "$0")
else
    CURRENT_SHELL=$(ps -p $$ | awk 'NR==2 {print $NF}' 2>&1 | xargs basename)
fi

# Defaults
EXPORT_DIR="${EXPORT_DIR:-$HOME/conda_migration_exports}"
ANACONDA_PATH="${ANACONDA_PATH:-$HOME/anaconda3}"
ASSUME_YES=false
DRY_RUN=false
EXPORT_ALL=false
FROM_HISTORY=false
EXPORT_ONLY=false
DEINIT_ONLY=false
UNINSTALL_ONLY=false
NO_ANACONDA_CLEAN=false

# Track uninstaller success
UNINSTALLER_RAN=false

# Helpers
log() { printf "[%s] %s\n" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*"; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*"; }
err() { log "ERROR: $*"; exit 1; }
dry_run_msg() { 
    if $DRY_RUN; then
        log "DRY-RUN: $*"
    fi
}

confirm() {
    if $ASSUME_YES; then
        return 0
    fi
    read -r -p "$1 [y/N]: " resp
    case "$resp" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
  cat <<EOF
Usage: $0 [options]
Export:
  --export-all              Export all conda environments (default: interactive selection)
  --from-history            Export using --from-history (only explicitly-installed packages)
  --export-dir PATH         Directory for exported envs (default: ~/conda_migration_exports)
  --export-only             Only export & validate, then exit

Deinit / Uninstall / Clean:
  --deinit-only             Only reverse Anaconda init for all shells, then exit
  --uninstall-only          Only run Anaconda uninstaller + cleanup, then exit
  --anaconda-path DIR       Anaconda/Miniconda root (default: ~/anaconda3)
  --no-anaconda-clean       Do NOT offer 'anaconda-clean' pre-uninstall

Common:
  --yes                     Assume yes for prompts
  --dry-run                 Show actions without performing them
  --help                    Show this help

Environment variables:
  EXPORT_DIR                Directory for exported environments
  ANACONDA_PATH             Root of Anaconda/Miniconda installation
EOF
}

validate_export() {
    local file="$1"
    local env_name="$2"
    [[ -f "$file" ]] || { warn "Export file not found: $file"; return 1; }
    [[ -s "$file" ]] || { warn "Export file is empty: $file"; return 1; }
    # check for env name and deps
    grep -q "^name:" "$file" 2>/dev/null || { warn "Export $file missing 'name:'"; return 1; }
    grep -q "^dependencies:" "$file" 2>/dev/null || { warn "Export $file missing 'dependencies:'"; return 1; }
    local dep_count
    dep_count=$(awk '/^dependencies:/,/^[a-z]/ {if ($0 ~ /^[[:space:]]*-/) count++} END {print count+0}' "$file")
    (( dep_count > 0 )) || { warn "Export $file has no packages listed"; return 1; }
    info "✓ Validated $file ($dep_count packages)"
    return 0
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --export-all) EXPORT_ALL=true; shift ;;
    --from-history) FROM_HISTORY=true; shift ;;
    --export-dir) EXPORT_DIR="$2"; shift 2 ;;
    --anaconda-path) ANACONDA_PATH="$2"; shift 2 ;;

    --export-only) EXPORT_ONLY=true; shift ;;
    --deinit-only) DEINIT_ONLY=true; shift ;;
    --uninstall-only) UNINSTALL_ONLY=true; shift ;;
    --no-anaconda-clean) NO_ANACONDA_CLEAN=true; shift ;;

    --yes) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help) usage; exit 0 ;;
    *) warn "Unknown option: $1"; usage; exit 1 ;;
  esac
done

$DRY_RUN && echo "🔧 DRY-RUN MODE: No changes will be made"

# Resolve possible flag conflicts.
# Stages.
DO_EXPORT=true
DO_VALIDATE=true
DO_DEINIT=true
DO_UNINSTALL=true
DO_CLEAN=true

# ONLY flags are mutually exclusive
ONLY_COUNT=0
$EXPORT_ONLY && ((ONLY_COUNT++))
$DEINIT_ONLY && ((ONLY_COUNT++))
$UNINSTALL_ONLY && ((ONLY_COUNT++))
if (( ONLY_COUNT > 1 )); then
  err "Conflicting flags: only one of --export-only, --deinit-only, --uninstall-only may be used."
fi
# Apply *ONLY* modifiers, which are mutually exclusive and override others.
if $EXPORT_ONLY; then
  DO_DEINIT=false; DO_UNINSTALL=false; DO_CLEAN=false
fi
if $DEINIT_ONLY; then
  DO_EXPORT=false; DO_VALIDATE=false; DO_UNINSTALL=false; DO_CLEAN=false
fi
if $UNINSTALL_ONLY; then
  DO_EXPORT=false; DO_VALIDATE=false; DO_DEINIT=false
  # clean default still true unless uninstaller ran successfully
fi
# Respect explicit NO_*
$NO_ANACONDA_CLEAN && :  # handled just-in-time

# Sanity checks
if ! command -v conda >/dev/null 2>&1; then
  if $DO_EXPORT || $DO_DEINIT; then
    warn "conda not found in PATH; export/deinit will be skipped if they require conda."
  fi
fi

# Print the final uninstall plan
PLAN=()
$DO_EXPORT   && PLAN+=("export")
$DO_VALIDATE && PLAN+=("validate")
$DO_DEINIT   && PLAN+=("deinit")
$DO_UNINSTALL&& PLAN+=("uninstall")
$DO_CLEAN    && PLAN+=("clean")
info "Execution plan: ${PLAN[*]:-(no-ops)}"

mkdir -p "$EXPORT_DIR"
info "Export directory: $EXPORT_DIR"
info "Anaconda path: $ANACONDA_PATH"

# Export environments
export_env() {
    local env_name="$1"
    local out="$EXPORT_DIR/${env_name}.yml"
    EXPORT_IN_PROGRESS=true; CURRENT_EXPORT_FILE="$out"
    if $FROM_HISTORY; then
        info "Exporting $env_name with --from-history -> $out"
        conda env export -n "$env_name" --no-builds --from-history | sed '/^prefix:/d' > "$out"
    else
        info "Exporting $env_name -> $out"
        conda env export -n "$env_name" --no-builds | sed '/^prefix:/d' > "$out"
    fi
    EXPORT_IN_PROGRESS=false; CURRENT_EXPORT_FILE=""
}

extract_envs() {
    if command -v conda >/dev/null 2>&1; then
        conda env list | awk '$1 ~ /^[a-zA-Z0-9_\-]+$/ {print $1}'
    else
        warn "\`conda\` not found; cannot extract environments!"
        echo ""
    fi
}

if $DO_EXPORT; then
  if ! command -v conda >/dev/null 2>&1; then
    warn "Skipping export: conda not available."
  else
    if $EXPORT_ALL; then
      info "Exporting all environments..."
      mapfile -t ENVS < <(extract_envs)
      for e in "${ENVS[@]}"; do [[ -n "$e" ]] && export_env "$e"; done
    else
      info "Interactive export: select environments to export."
      mapfile -t ENVS < <(extract_envs)
      if [[ ${#ENVS[@]} -eq 0 ]]; then
        warn "No environments found to export."
      else
        echo "Found environments:"
        for i in "${!ENVS[@]}"; do printf "  %2d) %s\n" "$((i+1))" "${ENVS[$i]}"; done
        echo "  a) All"
        echo "  q) Quit (no export)"
        read -r -p "Select (e.g. '1 3' or 'a' or 'q'): " sel
        if [[ "$sel" == "a" ]]; then
          for e in "${ENVS[@]}"; do export_env "$e"; done
        elif [[ "$sel" != "q" ]]; then
          for idx in $sel; do
            if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#ENVS[@]} )); then
              export_env "${ENVS[$((idx-1))]}"
            else
              warn "Ignoring selection: $idx"
            fi
          done
        fi
      fi
    fi
  fi
  info "Export step complete. Files are under: $EXPORT_DIR"
fi

if $DO_VALIDATE; then
  info "Validating exported YAML files..."
  shopt -s nullglob
  EXPORTED_FILES=("$EXPORT_DIR"/*.yml)
  if (( ${#EXPORTED_FILES[@]} == 0 )); then
    warn "No YAML files found to validate."
  else
    FAILED=false
    for file in "${EXPORTED_FILES[@]}"; do validate_export "$file" || FAILED=true; done
    if $FAILED; then
        err "⚠️  Validation failed for one or more exports. Please review the warnings above.
    
    You have these options:
    1. Fix the problematic environments and re-export them
    2. Delete the invalid .yml files if you don't need those environments
    3. Manually edit the .yml files to fix issues
    
    Re-run this script to validate again, or proceed directly to uninstallation if you're confident."
    fi
    info "✓ All exported environments validated."
    info "   Total: ${#EXPORTED_FILES[@]} environment(s)"
  fi
fi

# --export-only short-circuit
$EXPORT_ONLY && { info "--export-only done."; exit 0; }

# --deinit-only short-circuit
$DEINIT_ONLY && {
  info "--deinit-only: reversing conda init for all shells"
  if $DRY_RUN; then
    dry_run_msg "Would run: conda init --reverse --all"
  else
    if command -v conda &>/dev/null; then
      conda init --reverse --all || warn "Could not reverse conda init for all shells."
    else
      warn "conda not found; cannot reverse init automatically."
    fi
  fi
  info "--deinit-only complete."
  exit 0
}

# Find uninstaller
find_uninstaller() {
    local candidates=(
        "$ANACONDA_PATH/uninstall.sh"
        "$HOME/anaconda3/uninstall.sh"
        "/opt/anaconda3/uninstall.sh"
        "$HOME/miniconda3/uninstall.sh"
        "/opt/miniconda3/uninstall.sh"
    )
    for u in "${candidates[@]}"; do
        [[ -x "$u" ]] && { echo "$u"; return 0; }
    done
    echo ""
}

# --uninstall-only mode
if $UNINSTALL_ONLY; then
    UNINSTALLER_FOUND=$(find_uninstaller)
    
    if [[ -n "$UNINSTALLER_FOUND" ]]; then
        info "Detected Anaconda uninstaller at: $UNINSTALLER_FOUND"
        if confirm "Run the official uninstaller now?"; then
            if $DRY_RUN; then
                dry_run_msg "Would run: $UNINSTALLER_FOUND --remove-caches --remove-config-files user --remove-user-data"
                [[ "$UNINSTALLER_FOUND" == /opt/* ]] && warn "Admin privileges would be needed."
            else
                if [[ "$UNINSTALLER_FOUND" == /opt/* ]]; then
                    warn "Admin privileges needed to uninstall!"
                else
                    "$UNINSTALLER_FOUND" --remove-caches --remove-config-files user --remove-user-data
                    EXIT_CODE=$?
                    if (( EXIT_CODE == 0 )); then
                        UNINSTALLER_RAN=true
                        info "Uninstaller completed successfully (exit code: 0)."
                    else
                        warn "Uninstaller exited with non-zero code: $EXIT_CODE"
                        info "You may need to review the uninstall manually or run cleanup."
                    fi
                fi
            fi
        else
            info "Skipped official uninstaller."
        fi
    else
        info "No official uninstaller detected at common locations."
    fi
    
    # If uninstaller ran successfully, skip cleanup and exit
    if $UNINSTALLER_RAN; then
        info "--uninstall-only complete."
        exit 0
    fi
    # Otherwise, proceed to cleanup
fi

# Final confirmation before destructive operations
if ($DO_UNINSTALL || $DO_CLEAN) && ! $DRY_RUN; then
    echo ""
    echo "─────────────────────────────────────────────────────────────"
    echo "  ⚠️  POINT OF NO RETURN"
    echo "─────────────────────────────────────────────────────────────"
    echo "The following steps will REMOVE Anaconda from your system."
    echo "Exported environments are in: $EXPORT_DIR"
    echo ""
    if ! confirm "Have you verified the exports are correct and ready to proceed?"; then
        info "Aborting. No changes made to Anaconda installation."
        exit 0
    fi
fi

# Optional anaconda-clean
if ! $NO_ANACONDA_CLEAN && command -v conda >/dev/null 2>&1 && $DO_UNINSTALL; then
    info "Anaconda/Miniconda detected. Preparing cleanup via anaconda-clean."
    if confirm "Do you want to run 'anaconda-clean' (removes configs and caches) before uninstalling?"; then
        if $DRY_RUN; then
            dry_run_msg "Would install anaconda-clean in base environment"
            dry_run_msg "Would run: anaconda-clean --yes"
        else
            info "Installing anaconda-clean in current conda"
            conda install -n base anaconda-clean -y
            info "Running anaconda-clean --yes"
            anaconda-clean --yes || warn "anaconda-clean returned non-zero"
        fi
    else
        info "Skipping anaconda-clean"
    fi
elif ! $NO_ANACONDA_CLEAN && ! command -v conda >/dev/null 2>&1 && $DO_UNINSTALL; then
    warn "\`conda\` not found; skipping anaconda-clean step"
fi

# Deactivate any env and deinit
if $DO_DEINIT; then
  if command -v conda &>/dev/null; then
    $DRY_RUN && dry_run_msg "Would deactivate any active conda environment" || conda deactivate 2>/dev/null || true
    if confirm "Remove conda initialization from shell profiles?"; then
      $DRY_RUN && dry_run_msg "Would run: conda init --reverse --all" || conda init --reverse --all || warn "Could not reverse conda init for all shells."
    else
      info "Skipped conda init cleanup."
    fi
  else
    warn "conda not found; skipping deactivation/deinit."
  fi
fi

# Uninstall
if $DO_UNINSTALL; then
    UNINSTALLER_FOUND=$(find_uninstaller)
    
    if [[ -n "$UNINSTALLER_FOUND" ]]; then
        info "Detected Anaconda uninstaller at: $UNINSTALLER_FOUND"
        if confirm "Run the official uninstaller now?"; then
            if $DRY_RUN; then
                dry_run_msg "Would run: $UNINSTALLER_FOUND --remove-caches --remove-config-files user --remove-user-data"
                [[ "$UNINSTALLER_FOUND" == /opt/* ]] && warn "Admin privileges would be needed."
            else
                if [[ "$UNINSTALLER_FOUND" == /opt/* ]]; then
                    warn "Admin privileges needed to uninstall!"
                else
                    "$UNINSTALLER_FOUND" --remove-caches --remove-config-files user --remove-user-data
                    EXIT_CODE=$?
                    if (( EXIT_CODE == 0 )); then
                        UNINSTALLER_RAN=true
                        info "Uninstaller completed successfully (exit code: 0)."
                    else
                        warn "Uninstaller exited with non-zero code: $EXIT_CODE"
                        info "You may need to review the uninstall manually or run cleanup."
                    fi
                fi
            fi
        else
            info "Skipped official uninstaller."
        fi
    else
        info "No official uninstaller detected; will proceed with manual cleanup (next section)."
    fi
fi

# Clean dirs / configs - ONLY if uninstaller didn't run
if $DO_CLEAN && ! $UNINSTALLER_RAN; then
    info "Offering to clean up Anaconda directories and configs..."
    
    # Build array of existing items
    declare -a CLEANUP_ITEMS
    declare -a CLEANUP_PATHS
    declare -a CLEANUP_DESCS
    
    local idx=0
    
    # Check each item and add if it exists
    if [[ -e "$ANACONDA_PATH" ]]; then
        CLEANUP_ITEMS[$idx]="Anaconda root"
        CLEANUP_PATHS[$idx]="$ANACONDA_PATH"
        CLEANUP_DESCS[$idx]="Installation directory"
        ((idx++))
    fi
    if [[ -e "$HOME/miniconda3" ]]; then
        CLEANUP_ITEMS[$idx]="~/miniconda3"
        CLEANUP_PATHS[$idx]="$HOME/miniconda3"
        CLEANUP_DESCS[$idx]="Miniconda user dir"
        ((idx++))
    fi
    if [[ -e "$HOME/.conda" ]]; then
        CLEANUP_ITEMS[$idx]="~/.conda"
        CLEANUP_PATHS[$idx]="$HOME/.conda"
        CLEANUP_DESCS[$idx]="Conda config directory"
        ((idx++))
    fi
    if [[ -e "$HOME/.continuum" ]]; then
        CLEANUP_ITEMS[$idx]="~/.continuum"
        CLEANUP_PATHS[$idx]="$HOME/.continuum"
        CLEANUP_DESCS[$idx]="Legacy Continuum config"
        ((idx++))
    fi
    if [[ -e "$HOME/.condarc" ]]; then
        CLEANUP_ITEMS[$idx]="~/.condarc"
        CLEANUP_PATHS[$idx]="$HOME/.condarc"
        CLEANUP_DESCS[$idx]="Conda config file"
        ((idx++))
    fi
    
    if (( idx == 0 )); then
        info "No Anaconda directories or configs found to clean."
    else
        echo ""
        echo "Found the following Anaconda-related directories and configs:"
        echo ""
        for i in "${!CLEANUP_ITEMS[@]}"; do
            printf "%d) %-30s (%s)\n" "$((i+1))" "${CLEANUP_ITEMS[$i]}" "${CLEANUP_DESCS[$i]}"
            echo "   Path: ${CLEANUP_PATHS[$i]}"
        done
        echo ""
        echo "a) Remove all"
        echo "n) Remove none"
        echo ""
        read -r -p "Select items to remove (e.g. '1 3 5' or 'a' or 'n'): " selection
        
        ITEMS_TO_REMOVE=()
        
        if [[ "$selection" == "a" ]]; then
            ITEMS_TO_REMOVE=("${CLEANUP_PATHS[@]}")
        elif [[ "$selection" != "n" ]]; then
            for idx in $selection; do
                if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#CLEANUP_PATHS[@]} )); then
                    ITEMS_TO_REMOVE+=("${CLEANUP_PATHS[$((idx-1))]}")
                else
                    warn "Ignoring invalid selection: $idx"
                fi
            done
        fi
        
        if (( ${#ITEMS_TO_REMOVE[@]} > 0 )); then
            echo ""
            echo "─────────────────────────────────────────────────────────────"
            echo "  FINAL CONFIRMATION"
            echo "─────────────────────────────────────────────────────────────"
            echo "About to remove:"
            for item in "${ITEMS_TO_REMOVE[@]}"; do
                echo "  - $item"
            done
            echo ""
            
            if confirm "Are you absolutely sure? This cannot be undone."; then
                for item in "${ITEMS_TO_REMOVE[@]}"; do
                    if [[ -e "$item" ]]; then
                        if $DRY_RUN; then
                            dry_run_msg "Would remove: $item"
                        else
                            info "Removing $item"
                            rm -rf "$item"
                        fi
                    fi
                done
            else
                info "Cleanup cancelled."
            fi
        else
            info "No items selected for removal."
        fi
    fi
elif $DO_CLEAN && $UNINSTALLER_RAN; then
    info "Official uninstaller ran successfully. Skipping directory cleanup."
fi

echo ""
echo "✓ Anaconda removal procedure complete."
if $DRY_RUN; then
    echo "🔧 This was a dry-run. No actual changes were made."
    echo "   Run without --dry-run to perform the actual uninstallation."
else
    echo "⚠️  Restart shell before installing Miniforge."
    echo ""
    echo "Next steps:"
    echo "  1. Close and reopen your terminal"
    echo "  2. Run the Miniforge installation script"
    echo "  3. Your exports are preserved in: $EXPORT_DIR"
fi