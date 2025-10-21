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
    [Parameter()] [string] $MiniforgePrefix = $(Join-Path $env:USERPROFILE 'miniforge3'),
    [Parameter()] [string] $ExportDir = $(Join-Path $env:USERPROFILE 'conda_migration_exports'),

    [Parameter(ParameterSetName = 'Default')] [switch] $NoInstall,
    [Parameter(ParameterSetName = 'Default')] [switch] $NoInit,
    [Parameter(ParameterSetName = 'Default')] [switch] $NoImport,

    [Parameter(ParameterSetName = 'InitOnly')]   [switch] $InitOnly,
    [Parameter(ParameterSetName = 'ImportOnly')] [switch] $ImportOnly,

    [Parameter()] [switch] $TestInstall,
    [Parameter()] [switch] $TestInit,

    [Parameter()] [switch] $Yes,
    [Parameter()] [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Helpers
if ($DryRun) { $script:WhatIfPreference = $true }

function Write-Log([string]$Level, [string]$Message, [string]$Color = "White") {
    $ts = (Get-Date).ToString("s")
    Write-Host "[$ts] ${Level}: $Message" -ForegroundColor $Color
}
function Info([string]$m) { Write-Log "INFO"  $m  Cyan }
function Warn([string]$m) { Write-Log "WARN"  $m  DarkYellow }
function Fail([string]$m) { Write-Log "ERROR" $m DarkRed; exit 1 }

function Confirm-Action([string]$Prompt) {
    if ($Yes) { return $true }
    $resp = Read-Host "$Prompt [y/N]"
    return ($resp -match '^(y|Y|yes|YES)$')
}

# Join-Path for files that may not exist yet
function Join-PathSafe([string]$a, [string]$b) { return [System.IO.Path]::Combine($a, $b) }

# Detect architecture for Windows Miniforge
function Get-MiniforgeAsset() {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -match 'ARM64') { return 'Miniforge3-Windows-arm64.exe' }
    else { return 'Miniforge3-Windows-x86_64.exe' }
}

# Prefer conda/mamba in the given prefix, explicitly
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

function Test-ValidYaml([string]$Path) {
    if (-not (Test-Path $Path)) { Warn "YAML not found: $Path"; return $false }
    $content = Get-Content -Path $Path -ErrorAction SilentlyContinue
    if (-not $content -or $content.Count -eq 0) { Warn "Empty YAML: $Path"; return $false }
    if (-not ($content | Select-String -SimpleMatch 'name:')) { Warn "Missing 'name:' in $(Split-Path $Path -Leaf)"; return $false }
    if (-not ($content | Select-String -SimpleMatch 'dependencies:')) { Warn "Missing 'dependencies:' in $(Split-Path $Path -Leaf)"; return $false }
    $deps = ($content | Where-Object { $_ -match '^\s*-\s' })
    if (-not $deps -or $deps.Count -eq 0) { Warn "No packages listed in $(Split-Path $Path -Leaf)"; return $false }
    return $true
}
function Get-EnvNameFromYaml([string]$Path) {
    $content = Get-Content -Path $Path -ErrorAction SilentlyContinue
    foreach ($line in $content) {
        if ($line -match '^\s*name\s*:\s*(.+)\s*$') {
            $name = $Matches[1].Trim()
            $name = $name.Trim('"').Trim("'")
            return $name
        }
    }
    return ""
}

# Resolve possible flag conflicts.
# Stages
$DO_INSTALL = $true
$DO_INIT = $true
$DO_IMPORT = $true
# Apply *ONLY* modifiers, which are mutually exclusive and override others.
switch ($PSCmdlet.ParameterSetName) {
    'InitOnly' {
        $DO_INSTALL = $false
        $DO_IMPORT = $false
        $DO_INIT = $true
        if ($NoInstall -or $NoInit -or $NoImport) {
            Fail "Flags conflict: -InitOnly cannot be combined with -NoInstall/-NoInit/-NoImport."
        }
    }
    'ImportOnly' {
        $DO_INSTALL = $false
        $DO_INIT = $false
        $DO_IMPORT = $true
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

# Sanity checks:
# - INIT without binaries is pointless: warn if INIT is requested but conda missing at prefix.
# - IMPORT requires at least conda/mamba at prefix.
if (($DO_INIT -or $DO_IMPORT -or $TestInstall -or $TestInit) -and -not (Test-Path $MiniforgePrefix)) {
    if (-not $DO_INSTALL) {
        Warn "Prefix '$MiniforgePrefix' does not exist yet."
        Warn "Requested actions need an installed Miniforge at the prefix."
    }
}

# Print the final install plan
$plan = @()
if ($DO_INSTALL) { $plan += 'install' }
if ($DO_INIT) { $plan += 'init' }
if ($DO_IMPORT) { $plan += 'import' }
if ($TestInstall) { $plan += 'test-install' }
if ($TestInit) { $plan += 'test-init' }
Info ("Execution plan: " + ($(if ($plan) { $plan -join ' ' } else { 'no-ops' })))

Info "Miniforge prefix: $MiniforgePrefix"
Info "Export dir:       $ExportDir"
New-Item -ItemType Directory -Force -Path $ExportDir | Out-Null

# --init-only short-circuit
if ($InitOnly) {
    Info "-InitOnly: initializing shells for existing prefix"
    $conda = Get-CondaPath $MiniforgePrefix
    if (-not $conda) {
        if ($WhatIfPreference) { Write-Host "What if: Initializing conda at $MiniforgePrefix (conda not found now)." }
        else { Fail "conda not found at prefix; install first." }
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
    $mamba = Get-MambaPath $MiniforgePrefix
    if ($mamba -and $PSCmdlet.ShouldProcess("Shell init", "mamba shell init (PowerShell)")) {
        & $mamba shell init --shell powershell 2>$null | Out-Null
    }
    if ($TestInit) {
        # Simple check: profile contains "conda initialize"
        $profilePath = $PROFILE
        if (Test-Path $profilePath) {
            $hit = Select-String -Path $profilePath -Pattern 'conda (initialize|init)' -SimpleMatch -ErrorAction SilentlyContinue
            if ($hit) { Info "Init block appears in: $profilePath" } else { Warn "Did not find Miniforge init block in $profilePath" }
        }
        else { Warn "PowerShell profile not found: $profilePath" }
    }
    return
}

# --import-only short-circuit
if ($ImportOnly) {
    Info "-ImportOnly: importing exported environments"
    $DO_INSTALL = $false
    $DO_INIT = $false
}

# Install Miniforge (optionally skip init)
if ($DO_INSTALL) {
    $asset = Get-MiniforgeAsset
    $url = "https://github.com/conda-forge/miniforge/releases/latest/download/$asset"
    $tmp = Join-PathSafe $env:TEMP ("miniforge_installer_{0}.exe" -f [System.Diagnostics.Process]::GetCurrentProcess().Id)

    if ($PSCmdlet.ShouldProcess($url, "Download Miniforge installer")) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing | Out-Null
            Info "Downloaded: $tmp"
        }
        catch {
            Fail "Failed to download Miniforge installer: $($_.Exception.Message)"
        }
    }

    # NSIS installer silent options: /S and /D=...
    # Keep user-scope: /InstallationType=JustMe, no PATH changes (/AddToPath=0)
    if ($PSCmdlet.ShouldProcess($MiniforgePrefix, "Run Miniforge installer (silent)")) {
        $a = @("/InstallationType=JustMe", "/AddToPath=0", "/RegisterPython=0", "/S", ("/D=" + $MiniforgePrefix))
        try {
            & $tmp @a
            Info "Installer finished (exit code $LASTEXITCODE)."
        }
        catch {
            Fail "Miniforge installer failed: $($_.Exception.Message)"
        }
    }

    # Cleanup installer file if not in WhatIf
    if (-not $WhatIfPreference -and (Test-Path $tmp)) {
        if ($PSCmdlet.ShouldProcess($tmp, "Remove installer")) {
            Remove-Item -Force -LiteralPath $tmp
        }
    }
}

# Initialise shells
if ($DO_INIT) {
    $conda = Get-CondaPath $MiniforgePrefix
    if (-not $conda) {
        if ($WhatIfPreference) { Write-Host "What if: Initializing conda at $MiniforgePrefix (conda not found now)." }
        else { Fail "conda not found at prefix ($MiniforgePrefix). Cannot initialize." }
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

    $mamba = Get-MambaPath $MiniforgePrefix
    if ($mamba -and $PSCmdlet.ShouldProcess("Shell init", "mamba shell init (PowerShell)")) {
        & $mamba shell init --shell powershell 2>$null | Out-Null
    }
}

# Import exported environments (only if installer ran or prefix exists)
if ($DO_IMPORT) {
    $conda = Get-CondaPath $MiniforgePrefix
    $mamba = Get-MambaPath $MiniforgePrefix
    if (-not ($conda -or $mamba)) {
        if ($WhatIfPreference) { Write-Host "What if: Importing environments at $MiniforgePrefix (conda/mamba not found now)." }
        else { Fail "Miniforge not present at prefix. Cannot import. ($MiniforgePrefix)" }
    }

    $files = Get-ChildItem -Path $ExportDir -Filter *.yml -ErrorAction SilentlyContinue
    if (-not $files) {
        Warn "No exported YAML files found in $ExportDir"
        Info "If your exports are elsewhere, set `\$env:EXPORT_DIR` and re-run."
    }
    else {
        Info ("Found {0} exported environment file(s) in {1}" -f $files.Count, $ExportDir)
        $valid = @()
        foreach ($f in $files) {
            if (Test-ValidYaml $f.FullName) { $valid += $f } else { Warn ("Invalid YAML: {0}" -f $f.Name) }
        }
        if (-not $valid -or $valid.Count -eq 0) { Warn "No valid YAML files to import." }
        elseif (Confirm-Action "Create/update environments from exported YAML files?") {
            $envExe = if ($mamba) { $mamba } else { $conda }
            $succ = @(); $fail = @()
            foreach ($f in $valid) {
                $envName = Get-EnvNameFromYaml $f.FullName
                if (-not $envName) { Warn "Cannot determine env name for $($f.Name); skipping."; $fail += $f.Name; continue }
                Info ("Processing {0} (env: {1})" -f $f.Name, $envName)

                # Check if env already exists
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
                foreach ($e in $succ) { Write-Host ("  - {0}" -f $e) }
                if ($fail.Count -gt 0) {
                    Write-Host ""
                    Write-Host ("Failed: {0}" -f $fail.Count)
                    foreach ($e in $fail) { Write-Host ("  - {0}" -f $e) }
                    Write-Host ""
                    Warn "Some environments failed to import. Check the logs above."
                    Warn "You can retry manually with: mamba env create -f"
                }
            }
        }
        else {
            Info "Skipped environment import."
        }
    }
}

$conda = Get-CondaPath $MiniforgePrefix
$mamba = Get-MambaPath $MiniforgePrefix
if (-not $WhatIfPreference) {
    try {
        if ($mamba) {
            & $mamba info | Out-Null
            & $mamba env list | Out-Null
        }
        elseif ($conda) {
            & $conda info | Out-Null
            & $conda env list | Out-Null
        }
    }
    catch { }
}
else {
    Write-Host "What if: Showing conda/mamba info and environment list"
}

if ($TestInstall) {
    $ok = $true
    foreach ($b in @((Join-PathSafe $MiniforgePrefix 'Scripts\conda.exe'),
            (Join-PathSafe $MiniforgePrefix 'Library\bin\mamba.exe'))) {
        if (Test-Path $b) {
            try { & $b --version | Out-Null } catch { }
        }
        else {
            Warn ("Missing: {0}" -f $b); $ok = $false
        }
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
        Warn "PowerShell profile not found: $profilePath"
    }
}

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
    Write-Host "  3. Activate an environment: mamba activate \<env_name\>"
    Write-Host ""
    Write-Host ("Your exports are preserved in: {0}" -f $ExportDir)
}