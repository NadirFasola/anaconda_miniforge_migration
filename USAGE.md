# Usage — Quick Start (Anaconda → Miniforge)

Questo è il **TL;DR** per usare gli script della cartella `scripts/`.
**Esegui sempre prima una prova a secco**.

> **Prova a secco (dry run)**
> - Bash: aggiungi `--dry-run` alla fine del comando
> - PowerShell: aggiungi `-DryRun`

## 1. Prima di iniziare (1 minuto)
- Apri un terminale **Bash/Zsh** (Linux/macOS/WSL) o **PowerShell** (Windows).
- Su Windows, assicurati che PowerShell possa eseguire script locali. 
    Esegui `Get-ExecutionPolicy -List` e verifica che `UserPolicy` **o** `CurrentUser` non siano `Restricted` o `Undefined`. In caso contrario, modifica l'ExecutionPolicy per CurrentUser
	```powershell
	Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
	```
	per abilitare l'esecuzione di script `*.ps1`.

## 2. Scegli il percorso
### A. Conservativo (massima sicurezza)

**_Idea:_** installa Miniforge, prova, poi disattiva Anaconda; disinstalla solo quando tutto gira.

1. Esporta gli ambienti Conda esistenti
    + **Unix / macOS/ WSL**:
        ```bash
        ./anaconda_uninstall.sh --export-only --export-all --dry-run
        ./anaconda_uninstall.sh --export-only --export-all
        ```
    + **PowerShell**
        ```powershell
        .\anaconda_uninstall.ps1 -ExportOnly -ExportAll -DryRun
        .\anaconda_uninstall.ps1 -ExportOnly -ExportAll
        ```
1. Installa Miniforge
    + **Unix / macOS/ WSL**:
        ```bash
        ./miniforge_install.sh --install-only --dry-run
        ./miniforge_install.sh --install-only
        ```
    + **PowerShell**
        ```powershell
        .\miniforge_install.ps1 -InstallOnly -DryRun
        .\miniforge_install.ps1 -InstallOnly
        ```
1. Smoke test (senza init)
    + **Unix / macOS/ WSL**:
        ```bash
        ~/miniforge3/bin/conda --version && ~/miniforge3/bin/mamba --version
        ```
    + **PowerShell**
        ```powershell
        "$env:USERPROFILE\miniforge3\Scripts\conda.exe" --version; \
        "$env:USERPROFILE\miniforge3\Library\bin\mamba.exe" --version
        ```
1. Disattiva init di Anaconda
    + **Unix / macOS/ WSL**:
        ```bash
        ./anaconda_uninstall.sh --deinit-only --dry-run
        ./anaconda_uninstall.sh --deinit-only
        ```
    + **PowerShell**
        ```powershell
        .\anaconda_uninstall.ps1 -DeinitOnly -DryRun
        .\anaconda_uninstall.ps1 -DeinitOnly
        ```
1. Inizializza Miniforge
    + **Unix / macOS/ WSL**:
        ```bash
        ./miniforge_install.sh --init-only --dry-run
        ./miniforge_install.sh --init-only
        ```
    + **PowerShell**
        ```powershell
        .\miniforge_install.ps1 -InitOnly -DryRun
        .\miniforge_install.ps1 -InitOnly
        ```
1. Importa ambienti
    + **Unix / macOS/ WSL**:
        ```bash
        ./miniforge_install.sh --import-only --export-dir <DIR> --dry-run
        ./miniforge_install.sh --import-only --export-dir <DIR>
        ```
    + **PowerShell**
        ```powershell
        .\miniforge_install.ps1 -ImportOnly -ExportDir <DIR> -DryRun
        .\miniforge_install.ps1 -ImportOnly -ExportDir <DIR>
        ```
1. Disinstalla Anaconda quando tutto funziona
    + **Unix / macOS/ WSL**:
        ```bash
        ./anaconda_uninstall.sh --uninstall-only --with-anaconda-clean --backup --dry-run
        ./anaconda_uninstall.sh --uninstall-only --with-anaconda-clean --backup
        ```
    + **PowerShell**
        ```powershell
        .\anaconda_uninstall.ps1 -UninstallOnly -WithAnacondaClean -BackupDirs -DryRun
        .\anaconda_uninstall.ps1 -UninstallOnly -WithAnacondaClean -BackupDirs
        ```\

### B. All-in - più rapido, meno controllo

**_Idea:_** esporta → disinstalla Anaconda → installa+inizializza Miniforge → importa e riparti.

1. Disinstalla Anaconda
    + **Unix / macOS/ WSL**:
        ```bash
        ./anaconda_uninstall.sh [--export-all --from-history] --with-anaconda-clean --backup --dry-run
        ./anaconda_uninstall.sh [--export-all --from-history] --with-anaconda-clean --backup
        ```
    + **PowerShell**
        ```powershell
        .\anaconda_uninstall.ps1 [-ExportAll -FromHistory] -WithAnacondaClean -BackupDirs -DryRun
        .\anaconda_uninstall.ps1 [-ExportAll -FromHistory] -WithAnacondaClean -BackupDirs
        ```
1. Installa e inizializza Miniforge
    + **Unix / macOS/ WSL**:
        ```bash
        ./miniforge_install.sh [--skip-base] --dry-run
        ./miniforge_install.sh [--skip-base]
        ```
    + **PowerShell**
        ```powershell
        .\miniforge_install.ps1 [-SkipBase] -DryRun
        .\miniforge_install.ps1 [-SkipBase]
        ```

## 3. Verifiche rapide

- `mamba info` e `conda info` non devono attivare automaticamente `base`.
- `mamba env list` mostra i nuovi ambienti importati.
- Se un environment non si ricrea, riprova esportandolo con o senza `--from-history` (vedi [README](./README.md)) e usa `mamba` con canale `conda-forge` (come impostato di default dall'installer).