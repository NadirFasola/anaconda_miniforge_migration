#!/usr/bin/env bash
# =============================================================================
# ANACONDA UNINSTALLER (Bash)
# =============================================================================
# Part of a guided bash script to help migrating from Anaconda to Miniforge.
# Read the script before running.
# It will ask for confirmation before destructive steps.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

EXPORT_DIR="${EXPORT_DIR:-$HOME/conda_migration_exports}"
ANACONDA_PATH="${ANACONDA_PATH:-}"
ASSUME_YES=false
DRY_RUN=false
BACKUP=false
EXPORT_ALL=false
FROM_HISTORY=false
EXPORT_ONLY=false
DEINIT_ONLY=false
UNINSTALL_ONLY=false
WITH_ANACONDA_CLEAN=false

EXPORT_IN_PROGRESS=false
CURRENT_EXPORT_FILE=""

# ------------------------------- Logging -------------------------------------
ts() { date +%Y-%m-%dT%H:%M:%S%z; }
log()  { printf "[%s] %s\n" "$(ts)" "$*"; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*"; }
err()  { log "ERROR: $*"; exit 1; }

# ------------------------------ Small Helpers --------------------------------
do_run() {
  # do_run <description> -- <command...>
  local desc="$1"; shift
  if [[ "$1" == "--" ]]; then shift; fi
  if $DRY_RUN; then
    log "DRY-RUN: $desc"
    [[ $# -gt 0 ]] && log "DRY-RUN: would run: $*"
    return 0
  fi
  [[ -n "$desc" ]] && info "$desc"
  if [[ $# -gt 0 ]]; then
    "$@"
  fi
}

confirm() {
  $ASSUME_YES && return 0
  local prompt="${1:-Proceed?} [y/N]: "
  read -r -p "$prompt" resp || true
  case "$resp" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ------------------------------ Cleanup on EXIT ------------------------------
cleanup_trap() {
  if $EXPORT_IN_PROGRESS && [[ -n "$CURRENT_EXPORT_FILE" ]] && [[ -f "$CURRENT_EXPORT_FILE" ]]; then
    warn "Export was interrupted. File may be incomplete: $CURRENT_EXPORT_FILE"
    warn "Consider deleting it and re-running the export."
  fi
}
trap cleanup_trap EXIT INT TERM

# ------------------------------ Argparse -------------------------------------
usage() {
  cat <<'EOF'
Usage: anaconda_uninstall.sh [options]

Export:
  --export-all              Export all conda envs (default: interactive selection)
  --from-history            Use 'conda env export --from-history'
  --export-dir PATH         Directory for exports (default: $HOME/conda_migration_exports)
  --export-only             Only export & validate, then exit

Deinit / Uninstall / Clean:
  --deinit-only             Only reverse conda init (all shells), then exit
  --uninstall-only          Skip only export; still deinit + uninstall + clean
  --anaconda-path DIR       Explicit Anaconda/Miniconda root; ONLY this root is used
  --with-anaconda-clean     Run 'anaconda-clean --yes' pre-uninstall (no prompt)

Common:
  --backup                  During cleanup, back up paths to *.old instead of removing
  --yes                     Assume "yes" on prompts
  --dry-run                 Print actions without performing them
  --help                    Show help

Env vars:
  EXPORT_DIR, ANACONDA_PATH behave like their flags when set.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --export-all)         EXPORT_ALL=true; shift ;;
    --from-history)       FROM_HISTORY=true; shift ;;
    --export-dir)         EXPORT_DIR="$2"; shift 2 ;;
    --export-only)        EXPORT_ONLY=true; shift ;;

    --deinit-only)        DEINIT_ONLY=true; shift ;;
    --uninstall-only)     UNINSTALL_ONLY=true; shift ;;
    --anaconda-path)      ANACONDA_PATH="$2"; shift 2 ;;
    --with-anaconda-clean)WITH_ANACONDA_CLEAN=true; shift ;;

    --backup)             BACKUP=true; shift ;;
    --yes)                ASSUME_YES=true; shift ;;
    --dry-run)            DRY_RUN=true; shift ;;
    --help|-h)            usage; exit 0 ;;
    *) warn "Unknown option: $1"; usage; exit 1 ;;
  esac
done

$DRY_RUN && log "🔧 DRY-RUN MODE ENABLED"

# ------------------------------ Stage Plan -----------------------------------
DO_EXPORT=true
DO_VALIDATE=true
DO_DEINIT=true
DO_UNINSTALL=true
DO_CLEAN=true

only_count=0
$EXPORT_ONLY   && ((only_count++))
$DEINIT_ONLY   && ((only_count++))
$UNINSTALL_ONLY&& ((only_count++))
(( only_count > 1 )) && err "Use only one of --export-only / --deinit-only / --uninstall-only."

if $EXPORT_ONLY;   then DO_DEINIT=false; DO_UNINSTALL=false; DO_CLEAN=false; fi
if $DEINIT_ONLY;   then DO_EXPORT=false; DO_VALIDATE=false; DO_UNINSTALL=false; DO_CLEAN=false; fi
if $UNINSTALL_ONLY; then DO_EXPORT=false; DO_VALIDATE=false; DO_DEINIT=true; DO_UNINSTALL=true; DO_CLEAN=true; fi

# ------------------------------ Resolve ANACONDA_PATH ------------------------
# If user supplied ANACONDA_PATH -> only search there.
# Else probe known candidates and pick the first that exists; else default to ~/anaconda3.
declare -a CANDIDATE_ROOTS=()
if [[ -n "${ANACONDA_PATH}" ]]; then
  CANDIDATE_ROOTS=("${ANACONDA_PATH}")
else
  CANDIDATE_ROOTS=(
    "$HOME/anaconda3"
    "$HOME/Anaconda3"
    "$HOME/miniconda3"
    "$HOME/Miniconda3"
    "/opt/anaconda3"
    "/opt/miniconda3"
  )
fi

pick_first_existing_root() {
  local r
  for r in "${CANDIDATE_ROOTS[@]}"; do
    [[ -d "$r" ]] && { echo "$r"; return 0; }
  done
  echo ""
}

if [[ -z "${ANACONDA_PATH}" ]]; then
  ANACONDA_PATH="$(pick_first_existing_root)"
  [[ -z "$ANACONDA_PATH" ]] && ANACONDA_PATH="$HOME/anaconda3"
fi

# ------------------------------ Print Execution Plan -------------------------
plan=()
$DO_EXPORT    && plan+=("export")
$DO_VALIDATE  && plan+=("validate")
$DO_DEINIT    && plan+=("deinit")
$DO_UNINSTALL && plan+=("uninstall")
$DO_CLEAN     && plan+=("${BACKUP:+backup}${BACKUP:-clean}")
info "Execution plan: ${plan[*]:-(no-ops)}"
info "Export directory: $EXPORT_DIR"
info "Anaconda path:   $ANACONDA_PATH"

# ------------------------------ Helpers --------------------------------------
have_conda() { command -v conda >/dev/null 2>&1; }

backup_path_safe() {
  # backup_path_safe <path>  -> moves to <path>.old[.stamp[.N]]
  local src="$1"
  [[ -e "$src" ]] || return 0
  local candidate="${src}.old"
  if [[ -e "$candidate" ]]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    candidate="${src}.old.${stamp}"
    local i=2
    while [[ -e "$candidate" ]]; do
      candidate="${src}.old.${stamp}.${i}"
      ((i++))
    done
  fi
  if $DRY_RUN; then
    log "DRY-RUN: backup $src -> $candidate"
  else
    local parent
    parent="$(dirname "$candidate")"
    [[ -d "$parent" ]] || mkdir -p "$parent"
    mv -f -- "$src" "$candidate"
  fi
}

remove_path() {
  local p="$1"
  if $DRY_RUN; then
    log "DRY-RUN: remove $p"
  else
    rm -rf -- "$p"
  fi
}

export_env() {
  local env_name="$1"
  local out="${EXPORT_DIR}/${env_name}.yml"
  EXPORT_IN_PROGRESS=true; CURRENT_EXPORT_FILE="$out"
  local cmd=(conda env export -n "$env_name" --no-builds)
  $FROM_HISTORY && cmd+=(--from-history)
  if $DRY_RUN; then
    log "DRY-RUN: export $env_name -> $out"
  else
    "${cmd[@]}" | sed '/^prefix:/d' >"$out"
  fi
  EXPORT_IN_PROGRESS=false; CURRENT_EXPORT_FILE=""
}

extract_envs() {
  have_conda || { warn "conda not found; cannot list environments."; return 0; }
  conda env list | awk '$1 ~ /^[[:alnum:]_-]+$/ {print $1}'
}

validate_export() {
  local file="$1"
  [[ -f "$file" ]] || { warn "Missing: $file"; return 1; }
  [[ -s "$file" ]] || { warn "Empty file: $file"; return 1; }
  grep -q '^[[:space:]]*name:' "$file"    || { warn "$file missing 'name:'"; return 1; }
  grep -q '^[[:space:]]*dependencies:' "$file" || { warn "$file missing 'dependencies:'"; return 1; }
  local depc
  depc=$(awk '/^dependencies:/,/^[^[:space:]-]/{if ($0 ~ /^[[:space:]]*-/) c++} END{print c+0}' "$file")
  (( depc > 0 )) || { warn "$file has zero dependencies"; return 1; }
  info "✓ Validated $file ($depc packages)"
  return 0
}

run_anaconda_clean() {
  have_conda || { warn "conda not found; skipping anaconda-clean."; return; }
  if $WITH_ANACONDA_CLEAN; then
    do_run "Installing anaconda-clean in base env" -- conda install -n base -y anaconda-clean
    do_run "Running anaconda-clean --yes" -- anaconda-clean --yes || warn "anaconda-clean returned non-zero"
  else
    if confirm "Run 'anaconda-clean --yes' before uninstall? (removes caches/configs)"; then
      do_run "Installing anaconda-clean in base env" -- conda install -n base -y anaconda-clean
      do_run "Running anaconda-clean --yes" -- anaconda-clean --yes || warn "anaconda-clean returned non-zero"
    else
      info "Skipping anaconda-clean."
    fi
  fi
}

conda_deinit() {
  if have_conda; then
    # Deactivate current env (best-effort)
    $DRY_RUN || conda deactivate 2>/dev/null || true
    if confirm "Remove conda initialization from all shells (conda init --reverse --all)?"; then
      do_run "Reversing conda init for all shells" -- conda init --reverse --all || warn "Could not reverse conda init for all shells."
    else
      info "Skipped conda init cleanup."
    fi
  else
    warn "conda not found; skipping deactivation/deinit."
  fi
}

# Uninstaller discovery
# If user provided ANACONDA_PATH: ONLY search there. Else probe candidates.
find_uninstaller() {
  local roots=()
  if [[ -n "${ANACONDA_PATH}" ]]; then
    roots=("${ANACONDA_PATH}")
  else
    roots=(
      "$HOME/anaconda3" "$HOME/Anaconda3"
      "$HOME/miniconda3" "$HOME/Miniconda3"
      "/opt/anaconda3" "/opt/miniconda3"
    )
  fi
  local r
  for r in "${roots[@]}"; do
    local u="$r/uninstall.sh"
    [[ -x "$u" ]] && { echo "$u"; return 0; }
  done
  echo ""
}

run_uninstaller() {
  local u="$1"
  info "Detected Anaconda uninstaller at: $u"
  if confirm "Run the official uninstaller now?"; then
    do_run "Running uninstaller" -- "$u" --remove-caches --remove-config-files user || \
      warn "Uninstaller exited non-zero (manual review may be needed)."
  else
    info "Skipped official uninstaller."
  fi
}

list_cleanup_items() {
  local items=(
    "$ANACONDA_PATH|Anaconda root|Installation directory"
    "$HOME/miniconda3|~/miniconda3|Miniconda user dir"
    "$HOME/.conda|~/.conda|Conda state directory"
    "$HOME/.continuum|~/.continuum|Legacy Continuum config"
    "$HOME/.condarc|~/.condarc|Conda config file"
  )
  local entry p
  for entry in "${items[@]}"; do
    p="${entry%%|*}"
    [[ -e "$p" ]] && echo "$entry"
  done
}

apply_cleanup_selection() {
  local selection="$1"
  local -a paths=()
  local -a labels=()
  local -a descs=()

  mapfile -t rows < <(list_cleanup_items)
  ((${#rows[@]}==0)) && { info "No Anaconda directories or configs found to clean."; return; }

  echo ""
  echo "Found the following Anaconda-related directories and configs:"
  echo ""
  local i=0
  for row in "${rows[@]}"; do
    IFS='|' read -r path label desc <<<"$row"
    printf "  %2d) %-30s (%s)\n" "$((i+1))" "$label" "$desc"
    echo "      Path: $path"
    paths[$i]="$path"; labels[$i]="$label"; descs[$i]="$desc"
    ((i++))
  done
  echo ""
  local verb; verb=$($BACKUP && echo "Backup" || echo "Remove")
  echo "  a) ${verb} all"
  echo "  n) ${verb} none"
  echo ""

  local pick="$selection"
  if [[ -z "$pick" ]]; then
    read -r -p "Select items to ${verb,,} (e.g. '1 3 5' or 'a'/'n'): " pick
  fi

  local -a chosen=()
  if [[ "$pick" == "a" ]]; then
    chosen=("${paths[@]}")
  elif [[ "$pick" == "n" || -z "$pick" ]]; then
    info "No items selected."
    return
  else
    for idx in $pick; do
      if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#paths[@]} )); then
        chosen+=("${paths[$((idx-1))]}")
      else
        warn "Ignoring invalid selection: $idx"
      fi
    done
    ((${#chosen[@]}==0)) && { info "No items selected."; return; }
  fi

  echo ""
  echo "─────────────────────────────────────────────────────────────"
  echo "  FINAL CONFIRMATION"
  echo "─────────────────────────────────────────────────────────────"
  echo "About to $([ $BACKUP = true ] && echo "backup" || echo "remove"):"
  for c in "${chosen[@]}"; do echo "  - $c"; done
  echo ""

  if confirm "Are you sure?"; then
    local c
    for c in "${chosen[@]}"; do
      if [[ -e "$c" ]]; then
        if $BACKUP; then
          backup_path_safe "$c"
        else
          remove_path "$c"
        fi
      fi
    done
  else
    info "Cleanup cancelled."
  fi
}

# ------------------------------ Export Stage ---------------------------------
if $DO_EXPORT; then
  do_run "Ensuring export directory exists: $EXPORT_DIR" -- mkdir -p -- "$EXPORT_DIR"
  if have_conda; then
    if $EXPORT_ALL; then
      info "Exporting all environments…"
      mapfile -t ENVS < <(extract_envs)
      ((${#ENVS[@]}==0)) && warn "No environments found to export."
      for e in "${ENVS[@]}"; do [[ -n "$e" ]] && export_env "$e"; done
    else
      info "Interactive export selection."
      mapfile -t ENVS < <(extract_envs)
      if ((${#ENVS[@]}==0)); then
        warn "No environments found to export."
      else
        echo "Found environments:"
        for i in "${!ENVS[@]}"; do printf "  %2d) %s\n" "$((i+1))" "${ENVS[$i]}"; done
        echo "  a) All"
        echo "  q) Quit (no export)"
        read -r -p "Select (e.g. '1 3' or 'a' or 'q'): " sel
        if [[ "$sel" == "a" ]]; then
          for e in "${ENVS[@]}"; do export_env "$e"; done
        elif [[ "$sel" != "q" && -n "$sel" ]]; then
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
    info "Export step complete. Files: $EXPORT_DIR/*.yml"
  else
    warn "conda not found in PATH; skipping export."
  fi
fi

# ------------------------------ Validate Stage -------------------------------
if $DO_VALIDATE; then
  info "Validating exported YAML files…"
  shopt -s nullglob
  EXPORTED_FILES=("$EXPORT_DIR"/*.yml)
  if ((${#EXPORTED_FILES[@]}==0)); then
    warn "No YAML files found to validate."
  else
    FAILED=false
    for f in "${EXPORTED_FILES[@]}"; do validate_export "$f" || FAILED=true; done
    if $FAILED; then
      err "Validation failed for one or more exports. Fix or re-export before uninstall."
    fi
    info "✓ All exported environments validated. Total: ${#EXPORTED_FILES[@]}"
  fi
fi

# Short-circuit
$EXPORT_ONLY && { info "--export-only complete."; exit 0; }

# ------------------------------ Deinit Stage ---------------------------------
if $DO_DEINIT; then
  conda_deinit
fi

# ------------------------------ Uninstall Stage ------------------------------
if $DO_UNINSTALL; then
  # Optional anaconda-clean first
  if have_conda; then
    run_anaconda_clean
  else
    warn "conda not found; skipping anaconda-clean."
  fi

  UNINSTALLER="$(find_uninstaller)"
  if [[ -n "$UNINSTALLER" ]]; then
    run_uninstaller "$UNINSTALLER"
  else
    info "No official uninstaller detected for root(s) searched."
  fi
fi

# ------------------------------ Cleanup Stage --------------------------------
if $DO_CLEAN; then
  apply_cleanup_selection ""   # interactive selection; pass a preset string to automate
fi

# ------------------------------ Epilogue -------------------------------------
echo ""
echo "✓ Anaconda removal procedure complete."
if $DRY_RUN; then
  echo "🔧 This was a dry run. No changes were made."
  echo "   Re-run without --dry-run to perform actions."
else
  echo "⚠️  Restart your shell before installing Miniforge."
  echo ""
  echo "Next steps:"
  echo "  1) Close and reopen your terminal"
  echo "  2) Install Miniforge"
  echo "  3) Your exports are in: $EXPORT_DIR"
fi