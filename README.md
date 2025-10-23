## TL;DR

Procedura di migrazione del gestore di ambienti Python da **Anaconda** a **Miniforge**. L'obiettivo è garantire la conformità alle politiche di licenze software, mantenendo la compatibilità con i progetti e gli ambienti esistenti. Un eventuale abbinamento con WSL2 su Windows offre parity con runtime Linux in distribuzione, migliori prestazioni I/O e un flusso di sviluppo più coerente con le pipeline cloud.

**Quick-usage instructions:** [USAGE](./scripts/USAGE.md)

## 1. Confronto Anaconda vs. Miniforge

Entrambi gli strumenti si basano sullo stesso ecosistema, **Conda**, e sono interamente compatibili a livello di pacchetti e ambienti.

| Caratteristica           | Anaconda                                                                                       | Miniforge                                                                            |
| ------------------------ | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Licenza                  | Proprietaria                                                                                   | Open source (licenza BSD)                                                            |
| Distribuzione            | Include numerosi pacchetti preinstallati e strumenti grafici (e.g. Anaconda Navigator, Spyder) | Distribuzione minimale basata esclusivamente su `conda`/`mamba` e canali open source |
| Canali predefiniti       | `defaults` (Anaconda Repository)                                                               | `conda-forge` (community-driven repository)                                          |
| Gestore pacchetti        | `conda`                                                                                        | `conda` o `mamba` (alternativa più performante)                                      |
| Dimensione installazione | ~ 3-5 GB                                                                                       | < 500 MB                                                                             |
| Aggiornamenti            | Rilasci gestiti da Anaconda Inc.                                                               | Rilasci comunitari tramite Conda-Forge                                               |
| Compatibilità ambienti   | Formato `.yml` standard                                                                        | Formato `.yml` standard                                                              |
| Strumenti inclusi        | IDE + GUI opzionali                                                                            | N/A                                                                                  |
Alcune osservazioni operative:
- **Compatibilità:** gli ambienti creati con Anaconda sono pienamente ricreabili in Miniforge, purché i pacchetti siano disponibili su `conda-forge` (che comunque copre oltre il 99% dell'ecosistema Conda).
- **Performance:** l'uso di `mamba` consente una risoluzione delle dipendenze significativamente più rapida rispetto a `conda`.
- **Licenza:** Miniforge non impone limitazioni per l'utilizzo in contesti aziendali o commerciali (cf. [miniforge/LICENSE at main · conda-forge/miniforge](https://github.com/conda-forge/miniforge/blob/main/LICENSE))
- **Peso e manutenibilità:** Miniforge riduce tempi di installazione, ingombro su disco e complessità di aggiornamento, risultando più adatto per immagini container e CI/CD.

## 2. Procedura di migrazione
#### Esportazione degli ambienti Conda
Prima della rimozione di Anaconda, si possono esportare alcuni o tutti gli ambienti di Conda attualmente presenti nel sistema, in modo da poterli ricreare successivamente con Miniforge.

Per elencare gli ambienti disponibili:

```shell
conda env list
```

Per esportare un singolo ambiente (**Linux / macOS / WSL**):

```bash
conda env export -n <nome_ambiente> --no-builds | sed '/^prefix:/d' > <nome_ambiente>.yml
```

oppure (**Windows**):

```powershell
conda env export -n <nome_ambiente> --no-builds | Select-String -NotMatch '^prefix:' | Out-File -Encoding UTF8 <nome_ambiente>.yml
```

Si può automatizzare l'esportazione di tutti gli ambienti Conda presenti nel sistema utilizzando lo script seguente (**Linux** / **macOS** / **WSL**):

```bash
#!/usr/bin/env bash

for env in $(conda env list | awk '/^[a-zA-Z0-9_-]+/ {print $1}'); do
	conda env export -n "$env" --no-builds | sed '/^prefix:/d' > "${env}.yml"
done
```

oppure (**Windows**):

```powershell
#!/usr/bin/env pwsh

$envs = conda env list | Select-String "^\w" | ForEach-Object { ($_ -split '\s+')[0] }
foreach ($env in $envs) {
	conda env export -n $env --no-builds | Select-String -NotMatch '^prefix:' | Out-File -Encoding UTF8 "$env.yml"
}
```

>[!Note]
>I comandi precedenti producono un file `.yml` che include pacchetti installati esplicitamente e loro dipendenze, senza build strings. L'opzione addizionale `--from-history` istruisce `conda` a generare un file `.yml` che non includa le dipendenze, ma solo i pacchetti installati esplicitamente dall'utente.

> [!TIP]
> Si consiglia di archiviare i file `.yml` esportati in una directory dedicata (es. `~/env_exports/`) o in un repository condiviso.

#### Disinstallazione di Anaconda
Disinstallare Anaconda seguendo le istruzioni sulla [documentazione ufficiale](https://www.anaconda.com/docs/getting-started/anaconda/uninstall) e pulire eventuali residui - su **Windows**

```
%LOCALAPPDATA%\anaconda3
%USERPROFILE%\Anaconda3
%USERPROFILE%\.conda
%USERPROFILE%\.continuum
```

o **Linux** / **macOS** / **WSL**

```bash
rm -rf ~/anaconda3 ~/.conda ~/.continuum
```

#### Installazione di Miniforge
##### Windows
Utilizzare l'installer `.exe` più recente dal [repository GitHub](https://github.com/conda-forge/miniforge/releases).

>[!IMPORTANT]
>È fortemente raccomandabile, durante l'installazione, di **deselezionare** l'opzione per aggiungere Miniforge al `PATH` di sistema. 

Se si deseleziona l'opzione per aggiungere Miniforge a `PATH`, `conda`/`mamba` saranno disponibili unicamente su `Miniforge Prompt`. Per inizializzare `conda` e `mamba` nella propria shell di preferenza, eseguire su `Miniforge Prompt`

```
conda init [SHELL]
mamba shell init --shell [SHELL]
```

Per esempio, per inizializzare `conda` e `mamba` in PowerShell:

```
conda init powershell
mamba shell init --shell powershell
```

>[!WARNING]
>Qualora il comando
>```
>mamba shell init --shell bash
>``` 
>per inizializzare `mamba` in `Git Bash` restituisca un errore, potrebbe essere necessario procedere come segue, in `Git Bash`
>```bash
>cd ~/AppData/Local/miniforge3/Library/bin
>./mamba.exe shell init -s bash
>cd ~
>source .bash_profile
>```

>[!TIP]
>Conda rende disponibile l'opzione `--all` per inizializzare tutte le shell disponibili (`bash`, `cmd.exe`, `fish`, `powershell`, `tcsh`, `xonsh`, `zsh`).

Per disabilitare l'attivazione automatica dell'ambiente `base` (**fortemente consigliato** per favorire l'isolamento e separazione delle dipendenze tra differenti progetti):

```shell
conda config --set auto_activate_base false
```
#### Linux / macOS / WSL
Seguire le istruzioni per l'installazione sul [repository GitHub](https://github.com/conda-forge/miniforge?tab=readme-ov-file#unix-like-platforms-macos-linux--wsl).
#### Importazione degli ambienti Conda in Miniforge
Una volta completata l'installazione, è possibile ricreare gli ambienti precedentemente esportati.

Per un singolo ambiente (**Linux / macOS / WSL**):

```bash
if mamba env list | grep "<nome_ambiente>"; then
	mamba env update -f <nome_ambiente>.yml -c conda-forge
else
	mamba env create -f <nome_ambiente>.yml -c conda-forge
fi
```

oppure (**Windows**):

```powershell
if (mamba env list | Select-String "<nome_ambiente>") {
	mamba env update -f <nome_ambiente>.yml -c conda-forge
} else {
	mamba env create -f <nome_ambiente>.yml -c conda-forge
}
```

È possibile utilizzare uno script per automatizzare la creazione degli ambienti (**Linux** / **macOS** / **WSL**):

```bash
#!/usr/bin/env bash
set -euo pipefail

for file in *.yml; do
	# Reads the environment name from the yml file
	env_name=$(grep -E "^[[:space:]]*name[[:space:]]*:" $file | head -n1 | sed -E 's/^[[:space:]]*name[[:space:]]*://g' | sed -E "s/^['\"](.*)['\"]$/\1/")
	if mamba env list | grep -F -- $env_name >/dev/null; then
		mamba env update -f "$file" -c conda-forge
	else
		mamba env create -f "$file" -c conda-forge
	fi
done
```

oppure (**Windows**):

```powershell
#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Get-ChildItem -Filter '*.yml' | ForEach-Object {
	$file = $_.FullName
	# Reads the environment name from the yml file
	$line = Select-String -Path $file -Pattern '^\s*name\s*:' | Select-Object -First 1
	$name = ($line.Line -replace '^\s*name\s*:\s*','') -split '\s#' | Select-Object -First 1
	$name = $name.Trim()
	$name = $name.Trim('"',"'")
	$pattern = "\b{0}\b" -f [regex]::Escape($name)
	if (mamba env list | Select-String -Pattern $pattern -Quiet) {
		mamba env update -f $file -c conda-forge
	} else {
		mamba env create -f $file -c conda-forge
	}
}
```

>[!NOTE]
>In alternativa a `mamba`, è possibile usare `conda` senza variazioni sintattiche.

#### Verifica finale
```shell
mamba info
mamba env list
```

Confermare che tutti gli ambienti siano stati ricreati correttamente e che i pacchetti principali risultino installati come previsto.

## 3. Best practices post-migrazione

Dopo il completamento della migrazione da **Anaconda** a **Miniforge**, è raccomandabile adottare alcune pratiche standard per garantire coerenza tra gli ambienti, efficienza nella gestione dei progetti e facilità di manutenzione.

- Usare **esclusivamente** `conda-forge` come canale principale e predefinito
```shell
conda config --add channels conda-forge
conda config --set channel_priority strict
```
- Evitare di mescolare pacchetti provenienti da più canali, per ridurre il rischio di conflitti e problemi di compatibilità.
- Considerare l'utilizzo di `mamba` al posto di `conda` per operazioni di installazione e aggiornamento, per via della maggiore velocità nella risoluzione delle dipendenze.
- Controllare regolarmente la presenza di aggiornamenti dei pacchetti principali tramite:
```shell
mamba update --all
```
- Documentare eventuali pacchetti critici installati al di fuori di Conda per garantire la tracciabilità.
## 4. Confronto con le altre proposte: WSL & uv
### Windows Subsystem for Linux (WSL)
[WSL](https://learn.microsoft.com/it-it/windows/wsl/) è, a rigore, un layer di compatibilità che permette di eseguire un environment Linux direttamente su Windows, senza l'overhead di macchine virtuali tradizionali. WSL fornisce un ambiente Linux production-like, ma non è altro che un OS environment, non un manager di pacchetti di sviluppo. Fornisce uno _spazio_ in cui lavorare, ma non gestisce, in autonomia, pacchetti software, dipendenze, librerie, o ambienti virtuali. Nonostante sia possibile argomentare a favore dei vantaggi offerti dall'adozione di WSL come strumento di sviluppo (cf. [WSL](#wsl)), risulterebbe comunque necessario installare un manager come Miniforge _all'interno_ di WSL per gestire dipendenze e installazioni locali, a livello di progetto. In un certo senso, WSL è uno strumento fondazionale, che complementa un package manager, piuttosto che rimpiazzarlo.
### Gestione pacchetti con uv
[`uv`](https://docs.astral.sh/uv/) è un manager di pacchetti e ambienti di sviluppo per Python, sviluppato in Rust e progettato per essere un potenziale successore di tools come `pip` e `virtualenv`. Nonostante offra un'opzione eccezionalmente veloce e moderna, non può rappresentare un rimpiazzo 1-1 di Anaconda. Il suo punto di forza principale risiede nella velocità di installazione e risoluzione di pacchetti Python da PyPI. Anaconda, invece, tramite `conda`, può gestire anche librerie e dipendenze non strettamente Python-related, come librerie C/C++, toolkit CUDA, ecc. Anaconda rappresenta un approccio language-agnostic, aspetto che `uv` non è progettato per implementare. Proprio questa considerazione rende Anaconda una soluzione più ampia per uno stack che potenzialmente potrebbe coinvolgere più che il solo Python. Ciononostante, `uv` rappresenta un utile strumento per la gestione di progetti Python articolati, anche in abbinamento all'ecosistema Conda-Forge (`uv` permette la creazione di ambienti virtuali, ma anche l'automatic discovery di ambienti esistenti attivi, sia nativi sia Conda-like).

**In pratica**, utilizzare `uv` all'interno di un ambiente Conda per combinare la velocità di risoluzione delle dipendenze su PyPI con la stabilità dei binari `conda-forge`, mantenendo al contempo la separazione tra la gestione delle dipendenze Python pure e le librerie di sistema, rappresenta una buona soluzione, minimamente distruttiva dei workflow attualmente esistenti. Inoltre, permette un allineamento maggiore con i moderni packaging standards per Python, che evolvono intorno a [PEP 517](https://peps.python.org/pep-0517/), [518](https://peps.python.org/pep-0518/) e [621](https://peps.python.org/pep-0621/). In generale, workflow di sviluppo moderni in Python tendono a convergere verso un modello *"native-first"*, in cui:

- Configurazione del progetto e metadati sono dichiarati in un file `pyproject.toml` (PEP 621).
- Le build e le installazioni seguono interfacce standard definite dal backend (`build-backend` in PEP 517).
- Risoluzione delle dipendenze e locking sono eseguite a livello di Python, utilizzando metadati standard piuttosto che il risolutore custom di Conda.
- Ambienti sono creati e isolati utilizzando ambienti virtuali leggeri e nativi, garantendo compatiblità immediata con strumenti PEP-conformi e CI workflow.

In questo ecosistema, `uv` emerge come uno strumento di nuova generazione costruito precisamente intorno agli standard definiti sopra. Integrandolo con ambienti gestiti da Miniforge, otteniamo un'architettura a due livelli che massimizza tanto la compatibilità con i workflow esistenti quanto quella futura.

1. **Layer Miniforge**: gestisce dipendenze non Python a livello di sistema (e.g. toolkit CUDA, compilator, BLAS, node.js, ecc.) e fornisce un ambiente isolato come base per la riproducibilità.
1. **Layer `uv`**: opera all'interno dell'ambiente Conda, gestendo pacchetti Python in una maniera conforme allo standard definito da PEP. Utilizza `pyproject.toml` e `uv.lock` per la gestione delle dipendenze e la garanzia di un ambiente deterministico su tutte le macchine e le pipeline, offrendo al contempo risoluzione veloce e cache per installazioni rapide.

Da un punto di vista operativo, questa integrazione rappresenterebbe un percorso di modernizzazione a basso attrito con i workflow esistenti. Il team potrebbe continuare a utilizzare strumenti familiari afferenti a Conda, adottando progressivamente `uv` per la gestione delle dipendenze a livello di progetto e l'orchestrazione della compilazione.

#### Note pratiche per l'integrazione di `uv` e Miniforge

Integrare Miniforge (preferendo `mamba`) e `uv` seguendo un approccio stratificato:

1. **Utilizzare Miniforge _solo_ per il livello di sistema**, ovvero per fornire:
	- un interpreter Python minimale;
	- dipendenze di sistema;
	- strumenti multilingua (R, Go, Rust, js) secondo la necessità.
	Esempio:
	```shell
	mamba create -n <project_name> python=3.11 pip uv -y
	mamba activate <project_name>
	```
1. **Delegare a `uv` la gestione dei pacchetti Python**, definendo metadati e dipendenze in `pyproject.toml`, e.g.
	```toml
	[project]
	name = "<project_name>"
	version = "<project_ver>"
	description = "<project_desc>"
	dependencies = [
		"pandas",
		"numpy",
		"scikit-learn"
	]

	[build-systems]
	requires = ["hatchling"]
	build-backend = "hatchling.build"
	```
	fissando le dipendenze in maniera deterministica tramite `uv lock` e sincronizzando con `uv sync`. Inoltre, `uv` rileva automaticamente quando viene eseguito all'interno di un ambiente Conda, e installa dipendenze direttamente nel suo contesto, evitando ambienti virtuali sovrapposti inutilmente.

## Appendice e riferimenti

### Script di automazione

Per semplificare il processo di migrazione, sono disponibili **quattro script** (due Bash, due PowerShell) che automatizzano la migrazione end-to-end. Ogni coppia implementa la stessa logica.

**Script:**
1. `anaconda_uninstall.sh` / `anaconda_uninstall.ps1` — Esporta e valida gli ambienti (selezione interattiva di default; opzione “tutti” disponibile), de-inizializza conda, (opz.) esegue `anaconda-clean`, disinstalla e pulisce residui.
2. `miniforge_install.sh` / `miniforge_install.ps1` — Installa Miniforge (user-scope), inizializza shell e config (`conda-forge`, `channel_priority strict`, `auto_activate_base false`), (opz.) importa gli ambienti esportati.

#### Riferimento argomenti (Bash & PowerShell)

##### Uninstaller — `anaconda_uninstall.*`

- **Bash:**
	+ `--export-only | --deinit-only | --uninstall-only`  _(mutuamente esclusive)_
	+ `--export-all`, `--from-history`, `--export-dir PATH`
	+ `--anaconda-path DIR` (se non fornito: ricerca fra `~/anaconda3`, `~/miniconda3`, `/opt/`...; se fornito: usa **solo `DIR`**)
	+ `--with-anaconda-clean` (pre-uninstall), `--backup` (in cleanup rinomina in `.old...`)
	+ `--yes` (assumi sì), `--dry-run` (anteprima senza effetti)
- **PowerShell:** 
	+ `-ExportOnly | -DeinitOnly | -UninstallOnly | -CleanOnly` _(mutuamente esclusive via parameter sets)_
	+ `-ExportAll`, `-FromHistory`, `-ExportDir PATH`
	+ `-AnacondaPath DIR` (se non fornito: auto-rileva fra `%USERPROFILE%\anaconda3`, `%LOCALAPPDATA%\anaconda3`, `%USERPROFILE%\miniconda3`, `%LOCALAPPDATA%\miniconda3`, `C:\Anaconda3`, `C:\Miniconda3`; se fornito: usa **solo `DIR`**)
	+ `-WithAnacondaClean` (pre-uninstall), `-BackupDirs` (in cleanup rinomina in `.old...`)
	+ `-DryRun` (abilita globalmente **-WhatIf** - tutte le operazioni distruttive usano `ShouldProcess` → funzionano `-WhatIf/-Confirm`)

**Note:**
- `--from-history` / `-FromHistory` esporta solo i pacchetti installati esplicitamente (spec più snella; il risolutore ricostruisce le dipendenze in import).
- Gli YAML sono **validati** (devono contenere `name:` e `dependencies:` non vuoto).
- Bash rifiuta in esecuzione come **root**.

#### Installer — `miniforge_install.*`

- **Bash:**
	+ `--no-install`, `--no-init`, `--no-import` oppure `--init-only | --install-only | --import-only`
	+ `--test-install`, `--test-init` _read-only_ tests
	+ `--miniforge-prefix DIR` (predefinito `~/miniforge3`)
	+ `--export-dir` (cartella di esportazione di YAML spec file - predefinito `~/conda_migration_exports`)
	+ `--skip-base` (non importa / aggiorna l'ambiente `base`)
	+ `--yes`, `--dry-run`
- **PowerShell:** 
	+ `-NoInstall`, `-NoInit`, `-NoImport` oppure `-InitOnly | -InstallOnly | -ImportOnly` _(mutuamente esclusive via parameter sets)_
	+ `-TestInstall`, `-TestInit` _read-only_ tests
	+ `-MiniforgePrefix DIR` (predefinito `%USERPROFILE%\miniforge3`)
	+ `-ExportDir` (cartella di esportazione di YAML spec file - predefinito `%USERPROFILE%\conda_migration_exports`)
	+ `-SkipBase` (non importa / aggiorna l'ambiente `base`)
	+ `-DryRun`

#### Migrazione **conservativa**

Sequenza pensata per minimizzare i rischi e mantenere opzioni di rollback.

0. **\[Windows-only\] Vericare che PowerShell possa eseguire script**

	Eseguire `Get-ExecutionPolicy -List` e verificare che `UserPolicy` **o** `CurrentUser` non siano `Restricted` o `Undefined`. In caso contrario, eseguire
	```powershell
	Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
	```
	per abilitare l'esecuzione di script `*.ps1`.
1. **Export & validazione** (Anaconda ancora presente)
    - **Unix:**
        `<path to script>/anaconda_uninstall.sh --export-only [--export-all] [--from-history]`
    - **Windows:**
        `<path to script>\anaconda_uninstall.ps1 -ExportOnly [-ExportAll] [-FromHistory]`
2. **Installa Miniforge — senza init**
	Installa in **prefix utente**; non aggiungere al PATH.
    - **Unix:** 
	    `<path to script>/miniforge_install.sh --install-only [--miniforge-prefix <DIR>]`
    - **Windows:** 
	    `<path to script>\miniforge_install.ps1 -InstallOnly [-MiniforgePrefix <DIR>]`  
3. **Test d’installazione (senza init)**
	- **Unix:**
		`<miniforge prefix>/bin/conda --version`
		`<miniforge prefix>/bin/mamba --version`
	- **Windows:**
		`<miniforge prefix>\Scripts\conda.exe --version`
		`<miniforge prefix>\Library\bin\mamba.exe --version`
	Percorso di default:
	- **Unix**: `~/miniforge3`
	- **Windws**: `$env:LOCALAPPDATA/miniforge3`
4. **De-init di Anaconda**
    - **Unix:**
	    `./anaconda_uninstall.sh --deinit-only`
    - **Windows:**
	    `.\anaconda_uninstall.ps1 -DeinitOnly`
5. **Disinstalla Anaconda** (poi opzionale **Clean**)
    - **Unix:**
        - `./anaconda_uninstall.sh --uninstall-only[--with-anaconda-clean] [--backup] [--anaconda-path <DIR>]`
    - **Windows:**
        - `.\anaconda_uninstall.ps1 -UninstallOnly[-WithAnacondaClean] [-BackupDirs] [-AnacondaPath <DIR>]`
	**_Nota:_** “uninstall-only” salta **solo** l’export; esegue comunque **deinit + uninstall + clean/backup**.
6. **Riavvia il terminale** e verifica che `conda` **non** sia più nel PATH.
7. **Init di Miniforge**
    - **Unix:** 
	    `./miniforge_install.sh --init-only [--miniforge-prefix <DIR>]`
    - **Windows:** 
	    `.\miniforge_install.ps1 -InitOnly [-MiniforgePrefix <DIR>]`  
8. **Test init**
    - Nuova shell: `conda info`, `conda env list` → ok; `base` non deve auto-attivarsi.
9. **Import degli ambienti**
    - **Unix:**
	    `./miniforge_install.sh --import-only --export-dir <DIR> [--skip-base] [--miniforge-prefix <DIR>]`
    - **Windows:**
	    `.\miniforge_install.ps1 -ImportOnly -ExportDir <DIR> [-SkipBase] [-MiniforgePrefix <DIR>]` 
 
### Link utili

- [Miniforge GitHub](https://github.com/conda-forge/miniforge)
- [Conda-forge docs](https://conda-forge.org/docs/): canali, pacchetti, best practices
- [Mamba](https://mamba.readthedocs.io/): alternativa performante a Conda
- [Anaconda-clean](https://docs.conda.io/projects/conda/en/latest/user-guide/install/cleaning-up.html): rimuovere Anaconda in sicurezza
- [Microsoft Docs – WSL Architecture Comparison](https://learn.microsoft.com/en-us/windows/wsl/compare-versions)
- [Docker Docs – Docker Desktop with WSL2](https://docs.docker.com/desktop/wsl/)
- [Working on projects | uv](https://docs.astral.sh/uv/guides/projects/): gestione di progetti articolati con `uv`

### Esempio di file `environment.yml`

```yaml
name: <name>
channels:
  - conda-forge
dependencies:
  - python=3.11
  - jupyter=1.1
  - uv=0.9
  - nodejs=24.9
  - rust=1.89
```

> [!WARNING]
> Tutti i pacchetti devono essere risolvibili dal canale `conda-forge` per garantire compatibilità e velocità con `mamba`. Verificare con
> ```conda repoquery search -c conda-forge <package>```
> oppure con
> ```mamba repoquery search -c conda-forge <package>```

### WSL

Nonostante WSL non possa rappresentare di per sé un candidato per la sostituzione di Anaconda come gestore dei pacchetti Python, le considerazioni seguenti lo rendono un'opzione altamente consigliabile da **affiancare** all'adozione di un package manager come Miniforge.
#### Ambiente Linux isolato
WSL2 esegue un **kernel Linux completo** all’interno di una macchina virtuale leggera gestita da **Hyper-V**.  
La sua architettura garantisce un **elevato livello di isolamento** tra il sottosistema Linux e l’host Windows. Alcuni vantaggi:

- Una vulnerabilità all’interno di WSL2 (ad esempio, un pacchetto Python malevolo) rimane **confinata** alla macchina virtuale.  
- Per evadere dalla macchina virtuale verso il sistema host Windows sarebbe necessario un **hypervisor escape**, un tipo di attacco estremamente raro e complesso.

In tal senso, WSL2 supporta il principio di **difesa in profondità**, offrendo un ambiente sandbox ideale per lo sviluppo e la sperimentazione di workload di data science.
#### Modello di sicurezza Linux
Il sistema in esecuzione all’interno di WSL2 beneficia del modello di sicurezza **permission-based** di Linux, che include:

- Isolamento di file e processi tramite permessi e namespace UNIX;  
- Possibilità di eseguire strumenti come utente non-root, riducendo il rischio di privilege escalation;  
- Hardening opzionale tramite SELinux o AppArmor.

Questo introduce un ulteriore livello di **contenimento e controllo** rispetto ai meccanismi di sicurezza già presenti in Windows.
#### Accesso controllato ai dati
Di norma, WSL2 monta il filesystem di Windows in `/mnt/c`, `/mnt/d`, ecc.  
Tale accesso può essere **limitato o disabilitato** facilmente, consentendo di mantenere i dati sensibili esclusivamente in posizioni **enterprise-approved** (ad esempio cloud, SharePoint, ecc.), e di utilizzare WSL unicamente come ambiente computazionale e di sviluppo.  
Inoltre, poiché il sistema Linux non può accedere direttamente alle API di Windows, il rischio di **data exfiltration** o di **lateral movement** rimane molto basso.
#### Performance ed efficienza
WSL2 utilizza un filesystem **ext4 nativo**, offrendo un miglioramento delle prestazioni I/O di circa **2–5×** rispetto alla controparte Windows.  
Ciò incide direttamente sulle performance in scenari di:

- Lettura e scrittura di file CSV, Parquet o di dump di modelli e pipeline;  
- Addestramento di modelli mediante framework I/O-intensive (TensorFlow, PyTorch, ecc.).

Inoltre, WSL2 garantisce compatibilità completa con le **system call Linux**, eliminando numerosi problemi di compatibilità comuni negli ambienti Windows, specialmente per le librerie che dipendono da comportamenti **POSIX-compliant** (multiprocessing, sockets, ecc.).

*Last but not least*, Docker Desktop utilizza WSL2 in backend: l’integrazione nel workflow permette l’esecuzione dei container direttamente all’interno del kernel Linux (evitando doppi livelli di virtualizzazione), tempi di build più rapidi e un comportamento in sviluppo identico a quello in produzione su ambienti cloud.
#### Allineamento agli standard di settore
La maggior parte dei sistemi di Machine Learning e Analytics viene eseguita su server basati su Linux (AWS, Azure, GCP).  
WSL2 consente agli ambienti di sviluppo locali di **riflettere fedelmente quelli di produzione**, riducendo al minimo i problemi legati al sistema operativo.  
Inoltre, WSL2 offre accesso all’ecosistema Linux standard e a strumenti come `grep`, `awk`, `sed`, `ssh`, `rsync`, ecc., fondamentali per automazione, data wrangling e gestione sicura dei server.

_Last but not least_, la grande maggioranza della documentazione open-source per strumenti di sviluppo e data science presume l’utilizzo di una shell Linux/macOS.
#### Sicurezza
Sebbene WSL2 offra notevoli vantaggi in termini di produttività e qualità del flusso di lavoro, è opportuno menzionare alcune considerazioni di sicurezza.

| Rischio                       |                                                                                       | Mitigazione                                                                     |
| ----------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| **Shared Host Dependency**    | Se il sistema Windows viene compromesso, l’attaccante può accedere al filesystem WSL. | Mantenere una sicurezza robusta a livello dell’host Windows (enterprise-grade). |
| **Aggiornamenti del kernel**  | Un kernel Linux non aggiornato può esporre vulnerabilità note.                        | Il kernel WSL2 è mantenuto e aggiornato tramite **Windows Update**.             |
| **Integrazione file e rete**  | Il sottosistema Linux può accedere al filesystem di Windows (es. `/mnt/c`).           | Limitare o disabilitare tale integrazione tramite Group Policy o `wslconfig`.   |
| **Visibilità e monitoraggio** | Alcuni sistemi di sicurezza potrebbero non monitorare WSL di default.                 | **Microsoft Defender** include scanning hooks per WSL2 (da Windows 11 22H2).    |

In termini generali, WSL2 **non rappresenta un rischio addizionale** rispetto a un ambiente Windows standard, ma piuttosto una **sandbox controllata e ad alte prestazioni** in grado di rafforzare la postura di sicurezza e di migliorare l’efficienza dei flussi di sviluppo.