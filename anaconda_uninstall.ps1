#!/usr/bin/env pwsh
# =============================================================================
# ANACONDA UNINSTALLER (PowerShell)
# =============================================================================
# Part of a guided PS script to help migrating from Anaconda to Miniforge.
# Read the script before running.
# It will ask for confirmation before destructive steps via -Confirm,
# and will simulate with -WhatIf thanks to SupportsShouldProcess.
#
# Safety:
#   - SupportsShouldProcess: native -WhatIf / -Confirm
# =============================================================================

[CmdletBinding(
    SupportsShouldProcess = $true,
    ConfirmImpact = 'High',
    DefaultParameterSetName = 'Default'
)]
param(
    [Parameter()] [string] $ExportDir = (Join-Path -Path (Get-Location) -ChildPath "conda_migration_exports"),
    [Parameter()] [switch] $FromHistory,
    [Parameter()] [string] $AnacondaPath,
    
    [Parameter()] [switch] $BackupDirs,
    [Parameter()] [switch] $WithAnacondaClean,
    [Parameter()] [switch] $ExportAll,
    
    [Parameter(ParameterSetName = 'ExportOnly')]    [switch] $ExportOnly,
    [Parameter(ParameterSetName = 'DeinitOnly')]    [switch] $DeinitOnly,
    [Parameter(ParameterSetName = 'UninstallOnly')] [switch] $UninstallOnly,

    [Parameter()] [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# ------- Logging helpers -----------------------------------------------------
# -----------------------------------------------------------------------------
function Write-Log([string]$Level, [string]$Message, [string]$Color = "White") {
    $ts = (Get-Date).ToString("s")
    Write-Host "[$ts] ${Level}: $Message" -ForegroundColor $Color
}
function Info([string]$m) { Write-Log "INFO"  $m "Gray" }
function Warn([string]$m) { Write-Log "WARN"  $m "Yellow" }
function Fail([string]$m) { Write-Log "ERROR" $m "Red" }

if ($DryRun) { $script:WhatIfPreference = $true }

# -----------------------------------------------------------------------------
# ------- Detection helpers ---------------------------------------------------
# -----------------------------------------------------------------------------
function Test-CondaAvailable {
    try {
        $null = & conda --version 2>$null
        return $LASTEXITCODE -eq 0
    }
    catch { return $false }
}

function Find-UninstallerExe([string[]]$Roots) {
    # EXACT filename set requested
    $names = @(
        'Uninstall-Anaconda3.exe',
        'Uninstall-Miniconda3.exe',
        'Uninstall-Anaconda.exe',
        'Uninstall-Miniconda.exe',
        'Uninstall.exe',
        'uninstall.exe'
    )

    foreach ($root in $Roots) {
        foreach ($n in $names) {
            $p = Join-Path -Path $root -ChildPath $n
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    return $null
}

# -----------------------------------------------------------------------------
# ------- Backup & cleanup helpers -------------------------------------------
# -----------------------------------------------------------------------------
function Backup-PathSafe {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $base = $Path
    $candidate = "$base.old"
    if (Test-Path -LiteralPath $candidate) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $candidate = "$base.old.$stamp"
        $i = 2
        while (Test-Path -LiteralPath $candidate) {
            $candidate = "$base.old.$stamp.$i"
            $i++
        }
    }

    if ($PSCmdlet.ShouldProcess($Path, "Backup -> $candidate")) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $candidate) | Out-Null
        Move-Item -LiteralPath $Path -Destination $candidate -Force
    }
    return $candidate
}

# Items we consider safe to clean up after uninstall
function Get-AnacondaCleanupItems {
    $lapp = $env:LOCALAPPDATA

    $items = @(
        @{ Name = ".conda"; Path = Join-Path $env:USERPROFILE ".conda"; Description = "User conda data (pkgs, envs pointers)" },
        @{ Name = ".continuum"; Path = Join-Path $env:USERPROFILE ".continuum"; Description = "Continuum configs" },
        @{ Name = ".anaconda_backup"; Path = Join-Path $env:USERPROFILE ".anaconda_backup"; Description = "anaconda-clean backup dir (if present)" },
        @{ Name = ".condarc"; Path = Join-Path $env:USERPROFILE ".condarc"; Description = "User conda config" },
        @{ Name = "Anaconda3"; Path = Join-Path $env:USERPROFILE "anaconda3"; Description = "Local Anaconda install - home dir" },
        @{ Name = "Miniconda3"; Path = Join-Path $env:USERPROFILE "miniconda3"; Description = "Local Miniconda install - home dir" },
        @{ Name = "Anaconda3 (AppData)"; Path = Join-Path $lapp "anaconda3"; Description = "Local Anaconda install" },
        @{ Name = "Miniconda3 (AppData)"; Path = Join-Path $lapp "miniconda3"; Description = "Local Miniconda install" }
    )

    # Filter only those that exist
    return $items | Where-Object { Test-Path $_.Path } | Sort-Object -Property Path
}

function CleanDirs {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$BackupDirs)

    $existingItems = @(Get-AnacondaCleanupItems)

    if (-not $existingItems -or $existingItems.Count -eq 0) {
        Info "No Anaconda directories or configs found to clean."
        return
    }

    Write-Host ""
    Write-Host "Found the following Anaconda-related directories and configs:"
    Write-Host ""
    for ($i = 0; $i -lt $existingItems.Count; $i++) {
        $item = $existingItems[$i]
        Write-Host ("{0}) {1,-30} ({2})" -f ($i + 1), $item.Name, $item.Description)
        Write-Host ("   Path: {0}" -f $item.Path)
    }
    Write-Host ""
    $verb = if ($BackupDirs) { "Backup" } else { "Remove" }
    Write-Host ("a) {0} all" -f $verb)
    Write-Host ("n) {0} none" -f $verb)
    Write-Host ""
    $selection = Read-Host ("Select items to {0} (e.g. '1 3 5' or 'a'/'n')" -f $verb)

    $itemsToApply = @()
    if ($selection -eq 'a') {
        $itemsToApply = $existingItems
    }
    elseif ($selection -ne 'n') {
        $indices = $selection -split '\s+' | Where-Object { $_ -match '^\d+$' }
        foreach ($idx in $indices) {
            $i = [int]$idx
            if ($i -ge 1 -and $i -le $existingItems.Count) { $itemsToApply += $existingItems[$i - 1] }
        }
    }

    if (-not $itemsToApply -or $itemsToApply.Count -eq 0) {
        Info "No items selected."
        return
    }

    foreach ($item in $itemsToApply) {
        $p = $item.Path
        if ($BackupDirs) {
            $null = Backup-PathSafe -Path $p
        }
        else {
            if ($PSCmdlet.ShouldProcess($p, "Remove-Item -Recurse -Force")) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# -----------------------------------------------------------------------------
# ------- Actions (anaconda-clean / deinit / uninstall) -----------------------
# -----------------------------------------------------------------------------
function Invoke-AnacondaClean {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$EnsureInstalled)

    if (-not (Test-CondaAvailable)) { Warn "conda not found; skipping anaconda-clean."; return }

    if ($EnsureInstalled.IsPresent -and $PSCmdlet.ShouldProcess("base env", "conda install -n base -y anaconda-clean")) {
        try { conda install -n base -y anaconda-clean | Out-Null } catch { Warn "Could not ensure anaconda-clean is installed." }
    }

    if ($PSCmdlet.ShouldProcess("anaconda-clean", "anaconda-clean --backup")) {
        try { anaconda-clean --backup | Out-Null } catch { Warn "anaconda-clean returned non-zero." }
    }
}

function Invoke-CondaDeinit {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if (-not (Test-CondaAvailable)) { Warn "conda not found; skipping deactivation/deinit."; return }

    if ($PSCmdlet.ShouldProcess("Current session", "conda deactivate")) {
        try { conda deactivate 2>$null | Out-Null } catch { }
    }
    if ($PSCmdlet.ShouldProcess("All shells", "conda init --reverse --all")) {
        try { conda init --reverse --all | Out-Null } catch { Warn "Could not reverse conda init for all shells." }
    }
}

function Invoke-AnacondaUninstall {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string[]]$Roots)

    $uninstaller = Find-UninstallerExe $Roots
    if (-not $uninstaller) {
        Info "No official uninstaller detected at the provided candidate root(s)."
        return
    }

    Info "Detected uninstaller at: $uninstaller"
    $a = @("/S", "/RemoveCaches=1", "/RemoveConfigFiles=user", "/RemoveUserData=0")

    if ($PSCmdlet.ShouldProcess($uninstaller, "Run uninstaller")) {
        Start-Process -FilePath $uninstaller -ArgumentList $a -Wait -PassThru | Out-Null
        Info "Uninstaller completed."
    }
}

# -----------------------------------------------------------------------------
# ------- Export & validation -------------------------------------------------
# -----------------------------------------------------------------------------
function Get-CondaEnvNames {
    try {
        $list = conda env list 2>$null
    }
    catch { return @() }
    if (-not $list) { return @() }

    $names = @()
    foreach ($line in $list) {
        if ($line -match '^\s*([A-Za-z0-9_\-]+)\s') { $names += $Matches[1] }
    }
    $names | Select-Object -Unique
}

function Export-CondaEnv {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Name)

    $out = Join-Path $ExportDir "$Name.yml"
    $script:ExportInProgress = $true
    $script:CurrentExportTarget = $out

    if ($PSCmdlet.ShouldProcess($out, "conda env export -n $Name -> filtered yml")) {
        $a = @("env", "export", "-n", $Name, "--no-builds")
        if ($FromHistory) { $a += "--from-history" }
        $tmp = conda @a 2>$null
        if (-not $tmp) { Warn "Export produced no content for $Name"; $script:ExportInProgress = $false; return }
        $filtered = $tmp | Where-Object { $_ -notmatch '^\s*prefix:\s' }
        $filtered | Set-Content -Path $out -Encoding UTF8
        Info "Exported $Name -> $out"
    }

    $script:ExportInProgress = $false
    $script:CurrentExportTarget = ""
}

function Test-ExportYaml([string]$Path) {
    if (-not (Test-Path $Path)) { Warn "Export file not found: $Path"; return $false }
    # Minimal structural validation: name + dependencies list present
    $text = Get-Content -Path $Path -Raw
    $hasName = ($text -match '(?m)^\s*name:\s*.+' )
    $hasDeps = ($text -match '(?m)^(\s*)dependencies\s*:\s*\n(\1\s+-\s+.+(\n | $))+')
    if (-not $hasName) { Warn "Missing 'name:' in $Path" }
    if (-not $hasDeps) { Warn "No dependencies listed in $Path" }
    return ($hasName -and $hasDeps)
}

# -----------------------------------------------------------------------------
# ------- Pre-flight ----------------------------------------------------------
# -----------------------------------------------------------------------------
if (-not $ExportDir -and $env:EXPORT_DIR) { $ExportDir = $env:EXPORT_DIR }
if (-not $AnacondaPath -and $env:ANACONDA_PATH) { $AnacondaPath = $env:ANACONDA_PATH }

# -----------------------------------------------------------------------------
# ------- Stage plan ----------------------------------------------------------
# -----------------------------------------------------------------------------
$DO_EXPORT = $true
$DO_VALIDATE = $true
$DO_DEINIT = $true
$DO_UNINSTALL = $true
$DO_CLEAN = $true

switch ($PSCmdlet.ParameterSetName) {
    'ExportOnly' { $DO_EXPORT = $true; $DO_VALIDATE = $false; $DO_DEINIT = $false; $DO_UNINSTALL = $false; $DO_CLEAN = $false }
    'DeinitOnly' { $DO_EXPORT = $false; $DO_VALIDATE = $false; $DO_DEINIT = $true; $DO_UNINSTALL = $false; $DO_CLEAN = $false }
    'UninstallOnly' { $DO_EXPORT = $false; $DO_VALIDATE = $false; $DO_DEINIT = $true; $DO_UNINSTALL = $true; $DO_CLEAN = $true }
    default { }
}

# -----------------------------------------------------------------------------
# ------- Resolve AnacondaPath and candidate roots ----------------------------
# -----------------------------------------------------------------------------
# Build the exact candidate roots list (existing only)
$CandidateRoots = @()
$CandidateRoots += @(
    (Join-Path $env:LOCALAPPDATA 'anaconda3'),
    # (Join-Path $env:LOCALAPPDATA 'Anaconda3'),
    (Join-Path $env:LOCALAPPDATA 'miniconda3'),
    # (Join-Path $env:LOCALAPPDATA 'Miniconda3'),
    (Join-Path $env:USERPROFILE  'anaconda3'),
    # (Join-Path $env:USERPROFILE  'Anaconda3'),
    (Join-Path $env:USERPROFILE  'miniconda3'),
    # (Join-Path $env:USERPROFILE  'Miniconda3'),
    'C:\Anaconda3',
    'C:\Miniconda3'
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

# Print the plan
$plan = @()
if ($DryRun)    { $plan += "DRY-RUN" }
if ($DO_EXPORT) { $plan += ("Export environments " + $(if ($ExportAll) { "(all)" } else { "(select)" })) }
if ($DO_VALIDATE) { $plan += "Validate exported YAMLs" }
if ($DO_DEINIT) { $plan += "Deactivate env & de-init shells" }
if ($DO_UNINSTALL) { $plan += "Run vendor uninstaller" }
if ($DO_CLEAN) { $plan += ("{0} selected dirs/configs" -f $(if ($BackupDirs) { "Backup" } else { "Clean" })) }
Info ("Plan: " + ($plan -join "  ->  "))
Info ("AnacondaPath: $AnacondaPath")

# -----------------------------------------------------------------------------
# ------- Export --------------------------------------------------------------
# -----------------------------------------------------------------------------
if ($DO_EXPORT) {
    if (-not (Test-CondaAvailable)) {
        Fail "conda not available on PATH; cannot export."
    }
    if (-not (Test-Path -LiteralPath $ExportDir)) {
        if ($PSCmdlet.ShouldProcess($ExportDir, "New-Item -ItemType Directory")) {
            New-Item -ItemType Directory -Force -Path $ExportDir | Out-Null
        }
    }

    $allNames = @(Get-CondaEnvNames)
    if (-not $allNames -or $allNames.Count -eq 0) {
        Warn "No environments found to export."
    }
    else {
        $targets = @()

        if ($ExportAll) {
            $targets = $allNames
        }
        else {
            Write-Host ""
            Write-Host "Found the following conda environments:"
            Write-Host ""
            for ($i = 0; $i -lt $allNames.Count; $i++) {
                Write-Host ("{0}) {1}" -f ($i + 1), $allNames[$i])
            }
            Write-Host ""
            Write-Host "a) Export all"
            Write-Host "q) Quit (no export)"
            Write-Host ""
            $selection = Read-Host "Select envs to export (e.g. '1 3 5' or 'a'/'q')"

            if ($selection -eq 'q') {
                Info "No environments selected."
                $targets = @()
            }
            elseif ($selection -eq 'a') {
                $targets = $allNames
            }
            else {
                $indices = $selection -split '\s+' | Where-Object { $_ -match '^\d+$' }
                foreach ($idx in $indices) {
                    $ix = [int]$idx
                    if ($ix -ge 1 -and $ix -le $allNames.Count) {
                        $targets += $allNames[$ix - 1]
                    }
                    else {
                        Warn "Ignoring invalid selection index: $idx"
                    }
                }
                $targets = $targets | Select-Object -Unique
            }
        }

        if (-not $targets -or $targets.Count -eq 0) {
            Info "Nothing to export."
        }
        else {
            Info ("Exporting: " + ($targets -join ", "))
            foreach ($n in $targets) { Export-CondaEnv -Name $n }
        }
    }
}

# -----------------------------------------------------------------------------
# ------- Validate ------------------------------------------------------------
# -----------------------------------------------------------------------------
if ($DO_VALIDATE) {
    if (-not (Test-Path -LiteralPath $ExportDir)) {
        Warn "Export directory not found: $ExportDir"
    }
    else {
        $files = @(Get-ChildItem -LiteralPath $ExportDir -Filter *.yml -File -ErrorAction SilentlyContinue)
        if (-not $files -or $files.Count -eq 0) {
            Warn "No YAML files found to validate."
        }
        else {
            $failed = $false
            foreach ($f in $files) { if (-not (Test-ExportYaml $f.FullName)) { $failed = $true } }
            if ($failed) {
                Fail @"
Validation failed for one or more exports. Please review the warnings above.

You have these options:
  1. Fix the problematic environments and re-export them
  2. Delete the invalid .yml files if you don't need those environments
  3. Manually edit the .yml files to fix issues

Re-run this script to validate again, or proceed to uninstall if you're confident.
"@
            }
            else {
                Info "All exported environments validated."
            }
        }
    }
}

# Short-circuit for --export-only
if ($ExportOnly) { Info "--export-only complete."; return }

# -----------------------------------------------------------------------------
# ------- Deactivate & de-init ------------------------------------------------
# -----------------------------------------------------------------------------
if ($DO_DEINIT) {
    Invoke-CondaDeinit
}

# -----------------------------------------------------------------------------
# ------- Uninstaller ---------------------------------------------------------
# -----------------------------------------------------------------------------
if ($DO_UNINSTALL) {
    # If user supplied AnacondaPath, we ONLY look in that root.
    # Otherwise, search the candidate list we already computed above.
    $RootsForUninstall = @(if ($PSBoundParameters.ContainsKey('AnacondaPath')) {
        @($AnacondaPath) | Where-Object { $_ -and (Test-Path $_) }
    }
    else {
        $CandidateRoots
    })

    if ($WithAnacondaClean) {
        Invoke-AnacondaClean -EnsureInstalled
    }
    else {
        Info "Skipping anaconda-clean (enable with -WithAnacondaClean)."
    }
    if (-not $RootsForUninstall -or $RootsForUninstall.Count -eq 0) {
        Info "No candidate uninstall roots found to probe."
    }
    else {
        Invoke-AnacondaUninstall -Roots $RootsForUninstall
    }
}
elseif (-not (Test-CondaAvailable) -and $DO_CLEAN) {
    Warn "conda not available; proceeding to cleanup."
}

# -----------------------------------------------------------------------------
# ------- Cleanup (backup/remove) ---------------------------------------------
# -----------------------------------------------------------------------------
if ($DO_CLEAN) {
    CleanDirs -BackupDirs:$BackupDirs
}

# -----------------------------------------------------------------------------
# ------- Epilogue ------------------------------------------------------------
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "Anaconda removal procedure complete." -ForegroundColor Green
if ($WhatIfPreference) {
    Write-Host "[WHATIF] This was a simulation. No changes were made." -ForegroundColor Yellow
    Write-Host "[WHATIF] Run again without -WhatIf to actually perform the steps." -ForegroundColor Yellow
}
else {
    Write-Host "Restart your shell before installing Miniforge."
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Close and reopen your terminal"
    Write-Host "  2. Run the Miniforge installation script"
    Write-Host "  3. Your exports are preserved in: $ExportDir"
}