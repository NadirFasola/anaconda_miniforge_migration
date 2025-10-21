#!/usr/bin/env pwsh
# =============================================================================
# ANACONDA UNINSTALLER (PowerShell)
# =============================================================================
# Part of a guided PS script to help migrating from Anaconda to Miniforge.
# Read the script before running.
# It will ask for confirmation before destructive steps.
# 
# Safety:
#   - SupportsShouldProcess: native -WhatIf / -Confirm
#   - Elevation guard (refuses uninstall if elevated rights)
# =============================================================================

[CmdletBinding(
    SupportsShouldProcess = $true,
    ConfirmImpact = 'High',
    DefaultParameterSetName = 'Default'
)]
param(
    [Parameter()] [string] $ExportDir = $(Join-Path $env:USERPROFILE 'conda_migration_exports'),
    [Parameter()] [string] $AnacondaPath,  # optional; autodetect if not set
    [Parameter()] [switch] $Yes,
    [Parameter()] [switch] $DryRun,

    [Parameter(ParameterSetName = 'Default')] [switch] $ExportAll,
    [Parameter(ParameterSetName = 'Default')] [switch] $FromHistory,

    [Parameter(ParameterSetName = 'ExportOnly')]    [switch] $ExportOnly,
    [Parameter(ParameterSetName = 'DeinitOnly')]    [switch] $DeinitOnly,
    [Parameter(ParameterSetName = 'UninstallOnly')] [switch] $UninstallOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Helpers
function Write-Log([string]$Level, [string]$Message, [string]$Color = "White") {
    $ts = (Get-Date).ToString("s")
    Write-Host "[$ts] ${Level}: $Message" -ForegroundColor $Color
}
function Info([string]$m) { Write-Log "INFO"  $m  "Cyan" }
function Warn([string]$m) { Write-Log "WARN"  $m  "DarkYellow" }
function Fail([string]$m) { Write-Log "ERROR" $m "DarkRed"; exit 1 }

function Confirm-Action([string]$Prompt) {
    if ($Yes) { return $true }
    $resp = Read-Host "$Prompt [y/N]"
    return ($resp -match '^(y|Y|yes|YES)$')
}

# If -DryRun is set, make all ShouldProcess calls behave like -WhatIf
if ($DryRun) { $script:WhatIfPreference = $true }

# Clean & validate
if (-not $ExportDir -and $env:EXPORT_DIR) { $ExportDir = $env:EXPORT_DIR }
if (-not $AnacondaPath -and $env:ANACONDA_PATH) { $AnacondaPath = $env:ANACONDA_PATH }

$IsElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).
IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($IsElevated -and ($PSCmdlet.ParameterSetName -in 'Default')) {
    Warn "Script is running with Administrator privileges."
    Warn "For safety, uninstallation will not proceed while elevated."
    return
}

# Stages
$DO_EXPORT = $true
$DO_VALIDATE = $true
$DO_DEINIT = $true
$DO_UNINSTALL = $true
$DO_CLEAN = $true

# ONLY flags are mutually exclusive
switch ($PSCmdlet.ParameterSetName) {
    'ExportOnly' { $DO_EXPORT = $true; $DO_VALIDATE = $false; $DO_DEINIT = $false; $DO_UNINSTALL = $false; $DO_CLEAN = $false }
    'DeinitOnly' { $DO_EXPORT = $false; $DO_VALIDATE = $false; $DO_DEINIT = $true; $DO_UNINSTALL = $false; $DO_CLEAN = $false }
    'UninstallOnly' { $DO_EXPORT = $false; $DO_VALIDATE = $false; $DO_DEINIT = $false; $DO_UNINSTALL = $true; $DO_CLEAN = $true }
    default { }
}

# conda candidate roots
function Test-CondaAvailable {
    try { $null = Get-Command conda -ErrorAction Stop; return $true } catch { return $false }
}

# Candidate roots (user-first); include LOCALAPPDATA
$CandidateRoots = @()
if ($AnacondaPath) { $CandidateRoots += $AnacondaPath }
$CandidateRoots += @(
    (Join-Path $env:USERPROFILE  'anaconda3'),
    (Join-Path $env:USERPROFILE  'miniconda3'),
    (Join-Path $env:LOCALAPPDATA 'anaconda3'),
    (Join-Path $env:LOCALAPPDATA 'miniconda3'),
    'C:\Anaconda3',
    'C:\Miniconda3'
) | Where-Object { $_ -and (Test-Path $_) }

if (-not $AnacondaPath -and $CandidateRoots) {
    $AnacondaPath = $CandidateRoots[0]
}
if (-not $AnacondaPath) {
    $AnacondaPath = (Join-Path $env:USERPROFILE 'anaconda3')
}

# Print the final uninstall plan
$plan = @()
if ($DO_EXPORT) { $plan += 'export' }
if ($DO_VALIDATE) { $plan += 'validate' }
if ($DO_DEINIT) { $plan += 'deinit' }
if ($DO_UNINSTALL) { $plan += 'uninstall' }
if ($DO_CLEAN) { $plan += 'clean' }
Info ("Execution plan: " + ($plan -join ' '))

New-Item -ItemType Directory -Force -Path $ExportDir | Out-Null
Info "Export directory: $ExportDir"
Info "Anaconda path:    $AnacondaPath"

# Export environments
$script:ExportInProgress = $false
$script:CurrentExportTarget = ""

function Get-CondaEnvs {
    if (-not (Test-CondaAvailable)) { return @() }
    $list = conda env list 2>$null
    if (-not $list) { return @() }
    $names = @()
    foreach ($line in $list) {
        if ($line -match '^\s*([A-Za-z0-9_\-]+)\s') { $names += $Matches[1] }
    }
    return $names | Select-Object -Unique
}

function Export-CondaEnv([string]$Name) {
    $out = Join-Path $ExportDir "$Name.yml"
    $script:ExportInProgress = $true
    $script:CurrentExportTarget = $out
    if ($WhatIfPreference) {
        Write-Host "[WHATIF] conda env export -n $Name --no-builds" + ($(if ($FromHistory) { " --from-history" } else { "" })) + " | remove 'prefix:' -> $out"
    }
    else {
        $a = @("env", "export", "-n", $Name, "--no-builds")
        if ($FromHistory) { $a += "--from-history" }
        $tmp = conda @a 2>$null
        if (-not $tmp) { Warn "Export produced no content for $Name"; $script:ExportInProgress = $false; return }
        $filtered = $tmp | Where-Object { $_ -notmatch '^\s*prefix:\s' }
        $filtered | Set-Content -NoNewline -Path $out -Encoding UTF8
        Info "Exported $Name -> $out"
    }
    $script:ExportInProgress = $false
    $script:CurrentExportTarget = ""
}

function Test-ExportYaml([string]$Path) {
    if (-not (Test-Path $Path)) { Warn "Export file not found: $Path"; return $false }
    $content = Get-Content -Path $Path -ErrorAction SilentlyContinue
    if (-not $content -or $content.Count -eq 0) { Warn "Export file is empty: $Path"; return $false }
    if (-not ($content | Select-String -SimpleMatch "name:")) { Warn "Missing 'name:' in $Path"; return $false }
    if (-not ($content | Select-String -SimpleMatch "dependencies:")) { Warn "Missing 'dependencies:' in $Path"; return $false }
    $deps = ($content | Where-Object { $_ -match '^\s*-\s' })
    if (-not $deps -or $deps.Count -eq 0) { Warn "No packages listed in $Path"; return $false }
    Info ("Validated " + (Split-Path $Path -Leaf) + " (" + $deps.Count + " packages)")
    return $true
}

# Warn if export was interrupted
$script:cleanup = {
    if ($script:ExportInProgress -and $script:CurrentExportTarget -and (Test-Path $script:CurrentExportTarget)) {
        Warn "Export was interrupted. File may be incomplete: $script:CurrentExportTarget"
        Warn "Consider deleting it and re-running the export."
    }
}
Register-EngineEvent PowerShell.Exiting -Action $script:cleanup | Out-Null

if ($DO_EXPORT) {
    if (-not (Test-CondaAvailable)) {
        Warn "conda not found in PATH; skipping export."
    }
    else {
        if ($ExportAll) {
            Info "Exporting all environments..."
            foreach ($e in (Get-CondaEnvs)) { if ($e) { Export-CondaEnv $e } }
        }
        else {
            Info "Interactive export: select environments to export."
            $envs = Get-CondaEnvs
            if (-not $envs -or $envs.Count -eq 0) {
                Warn "No environments found to export."
            }
            else {
                Write-Host "Found environments:"
                for ($j = 0; $j -lt $envs.Count; $j++) {
                    Write-Host ("  {0,1}) {1}" -f ($j + 1), $envs[$j])
                }
                Write-Host "  a) All"
                Write-Host "  q) Quit (no export)"
                $sel = Read-Host "Select (e.g. '1 3' or 'a' or 'q')"
                if ($sel -eq 'a') {
                    foreach ($e in $envs) { Export-CondaEnv $e }
                }
                elseif ($sel -ne 'q') {
                    $indices = $sel -split '\s+' | Where-Object { $_ -match '^\d+$' }
                    foreach ($idx in $indices) {
                        $n = [int]$idx
                        if ($n -ge 1 -and $n -le $envs.Count) { Export-CondaEnv $envs[$n - 1] } else { Warn "Ignoring selection: $idx" }
                    }
                }
            }
        }
    }
    Info "Export step complete. Files are under: $ExportDir"
}

if ($DO_VALIDATE) {
    Info "Validating exported YAML files..."
    $files = Get-ChildItem -Path $ExportDir -Filter *.yml -ErrorAction SilentlyContinue
    if (-not $files) {
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
    
Re-run this script to validate again, or proceed directly to uninstallation if you're confident.
"@
        }
        else {
            Info "All exported environments validated."
        }
    }
}

# --export-only short-circuit
if ($ExportOnly) { Info "--export-only complete."; return }

# --deinit-only short-circuit
if ($DeinitOnly) {
    Info "--deinit-only: reversing conda init for all shells"
    if ($PSCmdlet.ShouldProcess("All shells", "conda init --reverse --all")) {
        if (Test-CondaAvailable) {
            try { conda init --reverse --all | Out-Null } catch { Warn "Could not reverse conda init for all shells." }
        }
        else {
            Warn "conda not found; cannot reverse init automatically."
        }
    }
    Info "--deinit-only complete."
    return
}

# --uninstall-only short-circuit
if ($UninstallOnly) {
    if ($IsElevated) { Fail "Running elevated; refusing to uninstall. Launch from a normal user shell." }
    
    $roots = @($AnacondaPath) + ($CandidateRoots | Where-Object { $_ -ne $AnacondaPath })
    $uninstaller = Find-UninstallerExe $roots

    if ($uninstaller) {
        Info "Detected Anaconda/Miniconda uninstaller at: $uninstaller"
        if (Confirm-Action "Run the official uninstaller now?") {
            if ($PSCmdlet.ShouldProcess($uninstaller, "Run uninstaller")) {
                $a = @("/S", "/RemoveCaches=1", "/RemoveConfigFiles=user", "/RemoveUserData=1")
                Start-Process -FilePath $uninstaller -ArgumentList $a -Wait -PassThru | Out-Null
                $UninstallerRan = $true
                Info "Uninstaller completed successfully."
            }
        }
        else {
            Info "Skipped official uninstaller."
        }
    }
    else {
        Info "No official uninstaller detected at common locations."
    }
    
    # Proceed to cleanup if uninstaller didn't run
    if (-not $UninstallerRan) {
        # Reuse cleanup logic below
        $DO_UNINSTALL = $false
        $DO_DEINIT = $false
    }
    else {
        Info "--uninstall-only complete."
        return
    }
}

# Find uninstaller
function Find-UninstallerExe([string[]]$Roots) {
    $names = @('Uninstall-Anaconda3.exe', 'Uninstall-Miniconda3.exe', 'Uninstall.exe', 'Uninstall-Anaconda.exe', 'uninstall.exe')
    foreach ($r in $Roots) {
        foreach ($n in $names) {
            $p = Join-Path $r $n
            if (Test-Path $p) { return $p }
        }
    }
    return $null
}

$UninstallerRan = $false

# Final confirmation before destructive operations
if (($DO_UNINSTALL -or $DO_DEINIT) -and -not $WhatIfPreference) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "  POINT OF NO RETURN"
    Write-Host "============================================================"
    Write-Host "This will remove Anaconda from your system."
    Write-Host "Exports are in: $ExportDir"
    if (-not (Confirm-Action "Proceed with uninstallation/cleanup?")) { Info "Aborting."; return }
}

# Optional anaconda-clean
if ($DO_UNINSTALL -and (Test-CondaAvailable)) {
    Info "Preparing cleanup via anaconda-clean."
    if (Confirm-Action "Run 'anaconda-clean' before uninstalling?") {
        if ($PSCmdlet.ShouldProcess("base env", "conda install -n base -y anaconda-clean")) {
            try { conda install -n base -y anaconda-clean | Out-Null } catch { }
        }
        if ($PSCmdlet.ShouldProcess("anaconda-clean", "anaconda-clean --yes")) {
            try { anaconda-clean --yes | Out-Null } catch { Warn "anaconda-clean returned non-zero" }
        }
    }
    else {
        Info "Skipping anaconda-clean."
    }
}
elseif ($DO_UNINSTALL -and -not (Test-CondaAvailable)) {
    Warn "conda not available; skipping anaconda-clean step."
}

# Deactivate any env and deinit
if ($DO_DEINIT) {
    if (Test-CondaAvailable) {
        if ($PSCmdlet.ShouldProcess("Current session", "conda deactivate")) {
            try { conda deactivate 2>$null | Out-Null } catch { }
        }
        if (Confirm-Action "Remove conda initialization from shell profiles?") {
            if ($PSCmdlet.ShouldProcess("All shells", "conda init --reverse --all")) {
                try { conda init --reverse --all | Out-Null } catch { Warn "Could not reverse conda init for all shells." }
            }
        }
        else {
            Info "Skipped conda init cleanup."
        }
    }
    else {
        Warn "conda not found; skipping deactivation/deinit."
    }
}

# Uninstall
if ($DO_UNINSTALL) {
    if ($IsElevated) { Fail "Running elevated; refusing to uninstall. Launch from a normal user shell." }

    $roots = @($AnacondaPath) + ($CandidateRoots | Where-Object { $_ -ne $AnacondaPath })
    $uninstaller = Find-UninstallerExe $roots

    if ($uninstaller) {
        Info "Detected Anaconda/Miniconda uninstaller at: $uninstaller"
        if (Confirm-Action "Run the official uninstaller now?") {
            if ($PSCmdlet.ShouldProcess($uninstaller, "Run uninstaller")) {
                $a = @("/S", "/RemoveCaches=1", "/RemoveConfigFiles=user", "/RemoveUserData=1")
                $process = Start-Process -FilePath $uninstaller -ArgumentList $a -Wait -PassThru
                if ($process.ExitCode -eq 0) {
                    $UninstallerRan = $true
                    Info "Uninstaller completed successfully (exit code: 0)."
                }
                else {
                    Warn "Uninstaller exited with non-zero code: $($process.ExitCode)"
                    Info "You may need to review the uninstall manually or run cleanup."
                }
            }
        }
        else {
            Info "Skipped official uninstaller."
        }
    }
    else {
        Info "No official uninstaller detected at common locations."
    }
}

# Clean dirs / configs - ONLY if uninstaller didn't run
if ($DO_CLEAN -and -not $UninstallerRan) {
    Info "Offering to clean up Anaconda directories and configs..."
    
    # Define all available cleanup items
    $cleanupItems = @(
        @{ Name = "Anaconda root"; Path = $AnacondaPath; Description = "Installation directory" },
        @{ Name = "~/Miniconda3"; Path = (Join-Path $env:USERPROFILE 'miniconda3'); Description = "Miniconda user dir" },
        @{ Name = "~/miniconda3"; Path = (Join-Path $env:USERPROFILE 'miniconda3'); Description = "Miniconda user dir" },
        @{ Name = "~/anaconda3"; Path = (Join-Path $env:USERPROFILE 'miniconda3'); Description = "Miniconda user dir" },
        @{ Name = "~/Anaconda3"; Path = (Join-Path $env:USERPROFILE 'miniconda3'); Description = "Miniconda user dir" },
        @{ Name = "%LOCALAPPDATA%\anaconda3"; Path = (Join-Path $env:LOCALAPPDATA 'anaconda3'); Description = "AppData Anaconda" },
        @{ Name = "%LOCALAPPDATA%\Anaconda3"; Path = (Join-Path $env:LOCALAPPDATA 'anaconda3'); Description = "AppData Anaconda" },
        @{ Name = "%LOCALAPPDATA%\miniconda3"; Path = (Join-Path $env:LOCALAPPDATA 'miniconda3'); Description = "AppData Miniconda" },
        @{ Name = "%LOCALAPPDATA%\Miniconda3"; Path = (Join-Path $env:LOCALAPPDATA 'miniconda3'); Description = "AppData Miniconda" },
        @{ Name = "~/.conda"; Path = (Join-Path $env:USERPROFILE '.conda'); Description = "Conda config directory" },
        @{ Name = "~/.continuum"; Path = (Join-Path $env:USERPROFILE '.continuum'); Description = "Legacy Continuum config" },
        @{ Name = "~/.condarc"; Path = (Join-Path $env:USERPROFILE '.condarc'); Description = "Conda config file"; IsFile = $true }
    )
    
    # Filter to only items that exist
    $existingItems = $cleanupItems | Where-Object { Test-Path $_.Path } | Sort-Object -Property Path -Unique
    
    if (-not $existingItems -or $existingItems.Count -eq 0) {
        Info "No Anaconda directories or configs found to clean."
    }
    else {
        Write-Host ""
        Write-Host "Found the following Anaconda-related directories and configs:"
        Write-Host ""
        for ($i = 0; $i -lt $existingItems.Count; $i++) {
            $item = $existingItems[$i]
            Write-Host ("{0}) {1,-30} ({2})" -f ($i + 1), $item.Name, $item.Description)
            Write-Host ("   Path: {0}" -f $item.Path)
        }
        Write-Host ""
        Write-Host "a) Remove all"
        Write-Host "n) Remove none"
        Write-Host ""
        $selection = Read-Host "Select items to remove (e.g. '1 3 5' or 'a' or 'n')"
        
        $itemsToRemove = @()
        
        if ($selection -eq 'a') {
            $itemsToRemove = $existingItems
        }
        elseif ($selection -ne 'n') {
            $indices = $selection -split '\s+' | Where-Object { $_ -match '^\d+$' }
            foreach ($idx in $indices) {
                $n = [int]$idx
                if ($n -ge 1 -and $n -le $existingItems.Count) {
                    $itemsToRemove += $existingItems[$n - 1]
                }
                else {
                    Warn "Ignoring invalid selection: $idx"
                }
            }
        }
        
        if ($itemsToRemove.Count -gt 0) {
            Write-Host ""
            Write-Host "============================================================"
            Write-Host "  FINAL CONFIRMATION"
            Write-Host "============================================================"
            Write-Host "About to remove:"
            foreach ($item in $itemsToRemove) {
                Write-Host "  - $($item.Name)"
            }
            Write-Host ""
            
            if (Confirm-Action "Are you absolutely sure? This cannot be undone.") {
                foreach ($item in $itemsToRemove) {
                    if (Test-Path $item.Path) {
                        if ($PSCmdlet.ShouldProcess($item.Path, "Remove-Item -Recurse -Force")) {
                            try {
                                if ($item.IsFile) {
                                    Remove-Item -Force -LiteralPath $item.Path
                                    Info "Removed $($item.Name)"
                                }
                                else {
                                    Remove-Item -Recurse -Force -LiteralPath $item.Path
                                    Info "Removed $($item.Name)"
                                }
                            }
                            catch {
                                Warn "Failed to remove $($item.Name): $($_.Exception.Message)"
                            }
                        }
                    }
                }
            }
            else {
                Info "Cleanup cancelled."
            }
        }
        else {
            Info "No items selected for removal."
        }
    }
}
elseif ($DO_CLEAN -and $UninstallerRan) {
    Info "Official uninstaller ran successfully. Skipping directory cleanup."
}

Write-Host ""
Write-Host "Anaconda removal procedure complete." -ForegroundColor Green
if ($WhatIfPreference) {
    Write-Host "[WHATIF] This was a what-if run. No actual changes were made."  -ForegroundColor Yellow
    Write-Host "[WHATIF] Run without --dry-run to perform the actual uninstallation."  -ForegroundColor Yellow
}
else {
    Write-Host "Restart your shell before installing Miniforge."
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Close and reopen your terminal"
    Write-Host "  2. Run the Miniforge installation script"
    Write-Host "  3. Your exports are preserved in: $ExportDir"
}