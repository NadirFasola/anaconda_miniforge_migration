#!/usr/bin/env pwsh
# =============================================================================
# MINIFORGE INSTALLER (PowerShell)
# =============================================================================
# Part of a guided PS script to help migrating from Anaconda to Miniforge.
# Read the script before running.
# It will ask for confirmation before destructive steps.

# Safety:
#   - SupportsShouldProcess: native -WhatIf / -Confirm
#   - User-scope install by default (no elevation required)
# =============================================================================

[CmdletBinding(
    SupportsShouldProcess = $true,
    ConfirmImpact = 'High',
    DefaultParameterSetName = 'Default'
)]
param(
    [Parameter()] [string] $MiniforgePrefix = (Join-Path $env:LOCALAPPDATA 'miniforge3'),
    [Parameter()] [string] $ExportDir = (Join-Path $env:USERPROFILE 'conda_migration_exports'),

    [Parameter(ParameterSetName = 'Default')] [switch] $NoInstall,
    [Parameter(ParameterSetName = 'Default')] [switch] $NoInit,
    [Parameter(ParameterSetName = 'Default')] [switch] $NoImport,

    [Parameter(ParameterSetName = 'InstallOnly')] [switch] $InstallOnly,
    [Parameter(ParameterSetName = 'InitOnly')]    [switch] $InitOnly,
    [Parameter(ParameterSetName = 'ImportOnly')]  [switch] $ImportOnly,

    [Parameter(ParameterSetName = 'Default')][Parameter(ParameterSetName = 'ImportOnly')] [switch] $SkipBase,

    [Parameter()] [switch] $TestInstall,
    [Parameter()] [switch] $TestInit,

    [Parameter()] [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# ------- Logging --------------------------------------------------------------
# -----------------------------------------------------------------------------
function Write-Log([string]$Level, [string]$Message, [string]$Color = "White") {
    $ts = (Get-Date).ToString("s")
    Write-Host "[$ts] ${Level}: $Message" -ForegroundColor $Color
}
function Info([string]$m) { Write-Log "INFO"  $m "Gray" }
function Warn([string]$m) { Write-Log "WARN"  $m "Yellow" }
function Fail([string]$m) { Write-Log "ERROR" $m "Red"; exit 1 }

if ($DryRun) { $script:WhatIfPreference = $true }

# -----------------------------------------------------------------------------
# ------- Small Helpers -------------------------------------------------------
# -----------------------------------------------------------------------------
function Join-PathSafe([string]$a, [string]$b) { [System.IO.Path]::Combine($a, $b) }

function Get-MiniforgeAsset() {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -match 'ARM64') { 'Miniforge3-Windows-arm64.exe' }
    else { 'Miniforge3-Windows-x86_64.exe' }
}

function Get-CondaPath([string]$prefix) {
    $candidates = @(
        (Join-PathSafe $prefix 'Scripts\conda.exe'),
        (Join-PathSafe $prefix 'condabin\conda.bat')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}
function Get-MambaPath([string]$prefix) {
    $candidates = @(
        (Join-PathSafe $prefix 'Library\bin\mamba.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

# Minimal YAML check
function Test-ValidYaml([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $text = Get-Content -LiteralPath $Path -Raw
    $hasName = ($text -match '^\s*name:\s*\S' )
    $hasDeps = ($text -match '^\s*dependencies:\s*' -and $text -match '^\s*-\s*\S')
    return ($hasName -and $hasDeps)
}

# -----------------------------------------------------------------------------
# ------- Install helpers ------------------------------------------------------
# -----------------------------------------------------------------------------
function Invoke-MiniforgeDownload {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$OutPath)

    $asset = Get-MiniforgeAsset
    $url = "https://github.com/conda-forge/miniforge/releases/latest/download/$asset"

    if ($PSCmdlet.ShouldProcess($url, "Download Miniforge installer")) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $OutPath -UseBasicParsing | Out-Null
            Info "Downloaded: $OutPath"
        }
        catch {
            Fail "Failed to download Miniforge installer: $($_.Exception.Message)"
        }
    }
}

function Invoke-MiniforgeInstall {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $InstallerPath,
        [Parameter(Mandatory)] [string] $Prefix
    )

    $a = @('/InstallationType=JustMe', '/RegisterPython=0', '/AddToPath=0', '/S', ("/D={0}" -f $Prefix))
    if ($PSCmdlet.ShouldProcess($Prefix, "Run Miniforge installer")) {
        try {
            Start-Process -FilePath $InstallerPath -ArgumentList $a -Wait -PassThru | Out-Null
            Info "Miniforge installed at: $Prefix"
        }
        catch {
            Fail "Miniforge installer failed: $($_.Exception.Message)"
        }
    }
}

function Remove-FileSafe {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$Path)
    if ((-not $WhatIfPreference) -and (Test-Path -LiteralPath $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, "Remove file")) {
            Remove-Item -LiteralPath $Path -Force
        }
    }
}

# -----------------------------------------------------------------------------
# ------- Init helpers ---------------------------------------------------------
# -----------------------------------------------------------------------------
function Initialize-Conda {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$Prefix)

    $conda = Get-CondaPath $Prefix
    if (-not $conda) {
        if ($WhatIfPreference) { Write-Host "What if: Initializing conda at $Prefix (conda not found yet)." }
        else { Fail "conda not found at prefix ($Prefix). Cannot initialize." }
        return
    }

    if ($PSCmdlet.ShouldProcess("All shells", "conda init --all")) {
        & $conda init --all | Out-Null
    }
    if ($PSCmdlet.ShouldProcess("conda config", "Set auto_activate_base false")) {
        & $conda config --set auto_activate_base false | Out-Null
    }
    if ($PSCmdlet.ShouldProcess("conda config", "Add conda-forge; channel_priority strict")) {
        & $conda config --add channels conda-forge | Out-Null
        & $conda config --set channel_priority strict | Out-Null
    }

    # Mamba shell init (if present)
    $mamba = Get-MambaPath $Prefix
    if ($mamba -and $PSCmdlet.ShouldProcess("Shell init", "mamba shell init (PowerShell)")) {
        & cmd /c "echo . | `"$mamba`" shell init --shell powershell --log-level 4" 2>$null | Out-Null
    }
}

# -----------------------------------------------------------------------------
# ------- Import helpers -------------------------------------------------------
# -----------------------------------------------------------------------------
function Resolve-Importer {
    param([string]$Prefix)
    $m = Get-MambaPath $Prefix
    if ($m) { return $m }
    return (Get-CondaPath $Prefix)
}

function Import-Environments {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$ExportDir,
        [switch]$SkipBase
    )

    $conda = Get-CondaPath $Prefix
    $mamba = Get-MambaPath $Prefix
    if (-not ($conda -or $mamba)) {
        if ($WhatIfPreference) {
            Write-Host "What if: Importing environments at $Prefix (conda/mamba not found yet)."
            return
        }
        Fail "Neither conda nor mamba found at $Prefix; cannot import."
    }

    if (-not (Test-Path -LiteralPath $ExportDir)) {
        Warn "No exported YAML directory found: $ExportDir"
        return
    }

    $files = Get-ChildItem -LiteralPath $ExportDir -Filter *.yml -File -ErrorAction SilentlyContinue
    if (-not $files -or $files.Count -eq 0) {
        Warn "No exported YAML files found in $ExportDir"
        Info "If your exports are elsewhere, set `$env:EXPORT_DIR` and re-run."
        return
    }

    Info ("Found {0} exported environment file(s) in {1}" -f $files.Count, $ExportDir)
    $valid = @()
    foreach ($f in $files) {
        if (Test-ValidYaml $f.FullName) { $valid += $f } else { Warn ("Invalid YAML: {0}" -f $f.Name) }
    }
    if (-not $valid -or $valid.Count -eq 0) {
        Warn "No valid YAML files to import."
        return
    }

    $envExe = if ($mamba) { $mamba } else { $conda }
    $succ = @(); $fail = @()

    foreach ($f in $valid | Sort-Object Name) {
        # env name: read "name: ..." line
        $envName = (Select-String -Path $f.FullName -Pattern '^\s*name:\s*(\S+)' -AllMatches | ForEach-Object { $_.Matches } | Select-Object -First 1).Groups[1].Value
        if (-not $envName) {
            Warn ("Cannot determine env name from {0}" -f $f.Name)
            continue
        }

        if ($SkipBase -and $envName -eq "base") {
            Info "-SkipBase: skipping 'base'"
            continue
        }

        $exists = $false
        try {
            $listOut = & $envExe env list 2>$null
            if ($listOut -match "^\s*$([regex]::Escape($envName))\s") { $exists = $true }
        }
        catch { }

        if ($exists) {
            if ($PSCmdlet.ShouldProcess($envName, "env update -f $($f.Name)")) {
                try {
                    & $envExe env update -f $f.FullName 2>&1 | Tee-Object -Variable _out | Out-Null
                    $succ += $envName
                }
                catch {
                    Warn ("Failed to update {0}" -f $envName)
                    $fail += $envName
                }
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($envName, "env create -f $($f.Name)")) {
                try {
                    & $envExe env create -f $f.FullName 2>&1 | Tee-Object -Variable _out | Out-Null
                    $succ += $envName
                }
                catch {
                    Warn ("Failed to create {0}" -f $envName)
                    $fail += $envName
                }
            }
        }
    }

    if (-not $WhatIfPreference) {
        Write-Host ""
        Write-Host "============================================================"
        Write-Host "Import Summary"
        Write-Host "============================================================"
        Write-Host ("Successful: {0}" -f $succ.Count)
        if ($succ) { $succ | Sort-Object | ForEach-Object { Write-Host ("  - {0}" -f $_) } }
        if ($fail) {
            Write-Host ("Failed:     {0}" -f $fail.Count)
            $fail | Sort-Object | ForEach-Object { Write-Host ("  - {0}" -f $_) }
        }
        Write-Host "============================================================"
    }
    else {
        Write-Host "What if: Would create/update {0} environment(s)." -f $valid.Count
    }
}

# -----------------------------------------------------------------------------
# ------- Stage planning -------------------------------------------------------
# -----------------------------------------------------------------------------
$DO_INSTALL = $true
$DO_INIT = $true
$DO_IMPORT = $true

switch ($PSCmdlet.ParameterSetName) {
    'InstallOnly' {
        $DO_INSTALL = $true; $DO_INIT = $false; $DO_IMPORT = $false
        if ($NoInstall -or $NoInit -or $NoImport) {
            Fail "Flags conflict: -InstallOnly cannot be combined with -NoInstall/-NoInit/-NoImport."
        }
    }
    'InitOnly' {
        $DO_INSTALL = $false; $DO_INIT = $true; $DO_IMPORT = $false
        if ($NoInstall -or $NoInit -or $NoImport) {
            Fail "Flags conflict: -InitOnly cannot be combined with -NoInstall/-NoInit/-NoImport."
        }
    }
    'ImportOnly' {
        $DO_INSTALL = $false; $DO_INIT = $false; $DO_IMPORT = $true
        if ($NoInstall -or $NoInit -or $NoImport) {
            Fail "Flags conflict: -ImportOnly cannot be combined with -NoInstall/-NoInit/-NoImport."
        }
    }
    default {
        if ($NoInstall) { $DO_INSTALL = $false }
        if ($NoInit) { $DO_INIT = $false }
        if ($NoImport) { $DO_IMPORT = $false }
    }
}

# Sanity check
if (($DO_INIT -or $DO_IMPORT -or $TestInstall -or $TestInit) -and -not (Test-Path $MiniforgePrefix)) {
    if (-not $DO_INSTALL) {
        Warn "Prefix '$MiniforgePrefix' does not exist."
        Warn "Requested actions need an installed Miniforge at the prefix."
    }
}

# Plan summary
$plan = @()
if ($DO_INSTALL) { $plan += "Install Miniforge" }
if ($DO_INIT) { $plan += "Initialize shells & config" }
if ($DO_IMPORT) { $plan += ("Import envs from {0}{1}" -f $ExportDir, ($(if ($SkipBase) { " (skip base)" } else { "" }))) }
if ($TestInstall) { $plan += "Test binaries" }
if ($TestInit) { $plan += "Test init block" }
Info ("Plan: " + ($plan -join "  ->  "))
Info ("MiniforgePrefix: $MiniforgePrefix")

# -----------------------------------------------------------------------------
# ------- INSTALL --------------------------------------------------------------
# -----------------------------------------------------------------------------
if ($DO_INSTALL) {
    $tmp = Join-PathSafe $env:TEMP ("miniforge_installer_{0}.exe" -f [System.Diagnostics.Process]::GetCurrentProcess().Id)
    Invoke-MiniforgeDownload -OutPath $tmp
    Invoke-MiniforgeInstall -InstallerPath $tmp -Prefix $MiniforgePrefix
    Remove-FileSafe -Path $tmp
}

# -----------------------------------------------------------------------------
# ------- INIT ----------------------------------------------------------------
# -----------------------------------------------------------------------------
if ($DO_INIT) {
    Initialize-Conda -Prefix $MiniforgePrefix
}

# -----------------------------------------------------------------------------
# ------- IMPORT ---------------------------------------------------------------
# -----------------------------------------------------------------------------
if ($DO_IMPORT) {
    Import-Environments -Prefix $MiniforgePrefix -ExportDir $ExportDir -SkipBase:$SkipBase
}

# -----------------------------------------------------------------------------
# ------- Diagnostics ----------------------------------------------------------
# -----------------------------------------------------------------------------
# Show conda/mamba info + env list (quietly tolerate absence during WhatIf)
$envExe = Resolve-Importer -Prefix $MiniforgePrefix
if ($envExe) {
    try {
        if (-not $WhatIfPreference) {
            & $envExe info | Out-Null
            & $envExe env list | Out-Null
        }
        else {
            Write-Host "What if: Showing conda/mamba info and environment list"
        }
    }
    catch { }
}

if ($TestInstall) {
    $ok = $true
    foreach ($b in @((Join-PathSafe $MiniforgePrefix 'Scripts\conda.exe'),
            (Join-PathSafe $MiniforgePrefix 'Library\bin\mamba.exe'))) {
        if (Test-Path $b) {
            try { & $b --version | Out-Null } catch { }
        }
        else { Warn ("Missing: {0}" -f $b); $ok = $false }
    }
    if ($ok) { Info "Miniforge binaries present." } else { Warn "Some binaries missing." }
}

if ($TestInit) {
    $profilePath = $PROFILE
    if (Test-Path $profilePath) {
        $hit = Select-String -Path $profilePath -Pattern 'conda (initialize|init)' -SimpleMatch -ErrorAction SilentlyContinue
        if ($hit) { Info "Init block appears in: $profilePath" } else { Warn "Did not find Miniforge init block in $profilePath" }
    }
    else {
        Warn "Profile file not found: $profilePath"
    }
}

# -----------------------------------------------------------------------------
# ------- Epilogue -------------------------------------------------------------
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "Miniforge installation complete!" -ForegroundColor Green
if ($WhatIfPreference) {
    Write-Host "What if: This was a dry-run. No actual changes were made." -ForegroundColor Yellow
    Write-Host "What if: Run without -DryRun to perform the actual installation." -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Restart your terminal"
    Write-Host "  2. Verify installation: mamba --version"
    Write-Host "  3. Activate an environment: mamba activate <env_name>"
    Write-Host ""
    Write-Host ("Your exports are in: {0}" -f $ExportDir)
}