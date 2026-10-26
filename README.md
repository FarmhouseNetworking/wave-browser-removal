# Wave Browser Removal & Block

`Remove-WaveBrowser.ps1` removes Wave Browser, the Wavesor SWUpdater, and the WebNavigator rebrand from every user profile on a Windows machine. It then blocks Wave from being installed again.

It is built to run from SuperOps as SYSTEM. It also works from any RMM, or from an elevated PowerShell prompt.

## What it does

**Removal.** This covers every profile, including users who are not logged on. Their registry hives are loaded temporarily for the cleanup.

- Kills Wave, SWUpdater and WebNavigator processes.
- Removes their scheduled tasks (including orphaned task XML files) and their services.
- Removes Wave's registry entries:
  - vendor keys, uninstall entries, Run/RunOnce and StartupApproved autostarts
  - StartMenuInternet, RegisteredApplications and App Paths
  - ProgIDs (`WaveBrws*`), COM CLSID/TypeLib/Interface/AppID registrations, and OpenWithProgids
- Deletes the install folders, installers in Downloads, and shortcuts. Shortcuts are matched by their target, including OneDrive-redirected desktops.
- Retries anything that was locked, then runs an independent verification sweep.

**Blocking.** Each layer can be turned off.

| Layer | How it works |
|---|---|
| IFEO | An Image File Execution Options `Debugger` redirect stops the known Wave executables from starting, whatever folder they are in. It works on Home and Pro. |
| Folder lock | Read-only placeholder folders sit at Wave's per-user install paths. The installer can't create its folder there, so it fails. |
| Hosts | Wave's download and update domains are sinkholed in a managed, marker-delimited block of the hosts file. |
| Defender PUA | Turns on Microsoft Defender's potentially unwanted app protection. Defender classifies Wave as a PUA. |
| Recurring task | Optional. A SYSTEM task, `WaveBlock-Enforce`, re-runs the script at startup, at each logon and once a day. This also covers users who sign in for the first time later. |

**The script cannot reset default apps.** Windows protects the default-browser and PDF choice (UserChoice) with a hash. If Wave was a user's default, the script reports it, and that user needs to pick a new default in *Settings > Apps > Default apps*.

## SuperOps setup

1. Create a PowerShell script in SuperOps and paste in `Remove-WaveBrowser.ps1`. Set it to run as **System**.
2. Add these **runtime variables**. All of them are optional, and an empty value uses the default. Dropdowns with Yes/No work well. The names are case-sensitive.

| Variable | Values | Default |
|---|---|---|
| `Operation` | `Remove` / `Unblock` | `Remove` |
| `EnableIFEOBlock` | Yes / No | Yes |
| `EnableFolderLock` | Yes / No | Yes |
| `EnableHostsBlock` | Yes / No | Yes |
| `EnableDefenderPUA` | Yes / No | Yes |
| `EnableRecurringTask` | Yes / No | No |

The script also accepts `True/False`, `1/0`, `On/Off` and `Enabled/Disabled`. Each variable is read only once, inside a quoted string, so it works whether SuperOps defines the values as PowerShell variables or substitutes them into the script text.

**Outside SuperOps,** set environment variables named `WAVEBLOCK_<NAME>` instead, for example:

```powershell
$env:WAVEBLOCK_ENABLERECURRINGTASK = 'Yes'
.\Remove-WaveBrowser.ps1
```

## Output and exit codes

The output ends with a `RESULT:` line. A copy is appended to `%ProgramData%\WaveBlock\WaveBlock.log`.

| Exit | Result | Meaning |
|---|---|---|
| 0 | `CLEAN` | Wave is gone and all requested blocks are in place |
| 1 | `LEFTOVERS` | Wave artefacts remain. Reboot and run again. |
| 2 | `ERROR` | The script was not run elevated |
| 3 | `CLEAN-BLOCK-INCOMPLETE` | Wave is removed, but a requested block failed. Check the `BLOCK MISSING` lines. |

In `Unblock` mode the result is `UNBLOCKED` (exit 0) or `UNBLOCK-INCOMPLETE` (exit 1).

## Files the script creates

| Path | Purpose |
|---|---|
| `%ProgramData%\WaveBlock\WaveBlock.log` | Run log |
| `%ProgramData%\WaveBlock\hosts.bak` | Copy of the hosts file before the last change |
| `%ProgramData%\WaveBlock\WaveBlock-Enforce.ps1` / `.json` | Copy of the script and its saved settings for the recurring task |
| `<profile>\AppData\Local\WaveBrowser\BLOCKED-BY-IT.txt` (and other install paths) | Marks a locked placeholder folder |

## Maintenance

Wave changes its installer names and domains regularly. Update these lists at the top of the script:

- `$IfeoExecutables`: executable names to block.
- `$BlockedDomains`: domains to sinkhole.
- `$ProfileInstallDirs` and `$ProfileLockDirs`: install paths to remove and to lock.

The match pattern is `wavesor|wavebrowser|wavebrws|swupdater|webnavigator`. It deliberately does not include a bare `wave`, so it won't touch *Waves MaxxAudio*, which is common on Dell machines.

**Stronger option:** where you have Intune or AppLocker (Enterprise/Education), a publisher rule that blocks the signer *Eightpoint Technologies Ltd. SEZC* is the most robust block, and it works alongside this script.
