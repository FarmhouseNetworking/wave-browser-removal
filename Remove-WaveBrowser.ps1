<#
.SYNOPSIS
    Removes Wave Browser / Wavesor SWUpdater (and the WebNavigator rebrand) from every user
    profile and blocks it from being reinstalled.

.DESCRIPTION
    Built for SuperOps (runs as SYSTEM). Works whether or not the affected user is logged on:
    profiles whose registry hives are not loaded are loaded temporarily, cleaned, and unloaded.

    Host-neutral: no hostnames, usernames, install IDs or drive letters are hard-coded.
    Finds Wave artefacts by PATTERN rather than fixed IDs, because the per-install suffix
    (WaveBrowser.<random>) and COM CLSIDs differ between installs. Profile locations come from
    the ProfileList registry key, so redirected or non-C: profile folders are covered.
    Safe to run on a clean machine: it removes nothing, (re)applies the blocks, and reports CLEAN.

    Requires Windows 8 / Server 2012 or later (Get-ScheduledTask) and PowerShell 3+.

    Order: IFEO block -> kill processes -> remove tasks/services -> clean registry (machine +
           per user) -> delete files/shortcuts -> kill again and retry anything locked ->
           unload hives -> apply remaining blocks -> verify removal AND blocks.

    BLOCKING LAYERS (each can be skipped)
      IFEO      Image File Execution Options "Debugger" redirect for the known Wave executables,
                so they cannot start from any folder. Works on Home/Pro (unlike AppLocker).
      Folders   Locked placeholder folders at Wave's install paths in every profile. The per-user
                installer cannot write there, so installs fail even under new installer names.
      Hosts     Sinkholes Wave download/update domains (managed block between markers).
      Defender  Enables Microsoft Defender PUA protection (Defender classifies Wave as PUA).
      Recurring Optional SYSTEM task that re-runs this script at startup, logon and daily,
                which also covers users who sign in for the first time later.

    Cannot fix: the default-browser / PDF UserChoice hash. If Wave was the default, the script
    reports it; have the user pick Chrome/Edge in Settings > Apps > Default apps.

    SUPEROPS RUNTIME VARIABLES (all optional - leave empty for the default)
    Create these in the SuperOps script editor (Dropdown Yes/No works well). Names are case-sensitive.

      Operation             Remove | Unblock                                       default Remove
                            Unblock removes the IFEO entries, placeholder folders, hosts entries
                            and recurring task. Nothing is uninstalled; Defender PUA is left on.
      EnableIFEOBlock       Yes/No                                                 default Yes
      EnableFolderLock      Yes/No                                                 default Yes
      EnableHostsBlock      Yes/No                                                 default Yes
      EnableDefenderPUA     Yes/No                                                 default Yes
      EnableRecurringTask   Yes/No  copy to %ProgramData%\WaveBlock and register   default No
                                    the SYSTEM task "WaveBlock-Enforce"

    Accepted values: Yes/No, True/False, 1/0, On/Off, Enabled/Disabled (any case).
    Each variable is read exactly once, inside a quoted string, so the script works whether
    SuperOps defines them as PowerShell variables or substitutes their text into the script.
    Outside SuperOps, set environment variables WAVEBLOCK_<NAME> (e.g. WAVEBLOCK_OPERATION=Unblock).
    The recurring task stores its settings in %ProgramData%\WaveBlock\WaveBlock-Enforce.json.

.NOTES
    Output ends with a RESULT line. Exit codes:
      0  RESULT: CLEAN                 - nothing left, all requested blocks in place
      1  RESULT: LEFTOVERS             - Wave artefacts remain (reboot and re-run)
      2  not running elevated
      3  RESULT: CLEAN-BLOCK-INCOMPLETE - removed, but a requested block is missing
    Log is also appended to %ProgramData%\WaveBlock\WaveBlock.log
#>

# ============================================================================================
# Settings - SuperOps runtime variables
# Each runtime variable appears exactly ONCE below, inside double quotes. Do not reference
# them anywhere else: if SuperOps substitutes text, every occurrence would be replaced.
# ============================================================================================
$RawSettings = [ordered]@{
    Operation           = "$Operation"
    EnableIFEOBlock     = "$EnableIFEOBlock"
    EnableFolderLock    = "$EnableFolderLock"
    EnableHostsBlock    = "$EnableHostsBlock"
    EnableDefenderPUA   = "$EnableDefenderPUA"
    EnableRecurringTask = "$EnableRecurringTask"
}
$SettingsWarnings = New-Object System.Collections.Generic.List[string]
$EnforceSettingsFile = Join-Path $env:ProgramData 'WaveBlock\WaveBlock-Enforce.json'

# Leftover placeholders from text substitution with an empty value (e.g. "{{EnableHostsBlock}}") count as empty
foreach ($k in @($RawSettings.Keys)) {
    $v = ([string]$RawSettings[$k]).Trim()
    if ($v -match '^\{\{.*\}\}$|^\$') { $v = '' }
    # Fall back to environment (used for the 64-bit relaunch and for running outside SuperOps)
    if (-not $v) { $v = [string][Environment]::GetEnvironmentVariable("WAVEBLOCK_$($k.ToUpper())") }
    $RawSettings[$k] = $v.Trim()
}
# The recurring task's copy takes its settings from the JSON written when the task was registered
if ($PSCommandPath -and $PSCommandPath -eq (Join-Path $env:ProgramData 'WaveBlock\WaveBlock-Enforce.ps1') -and
    (Test-Path -LiteralPath $EnforceSettingsFile)) {
    try {
        $saved = Get-Content -LiteralPath $EnforceSettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($k in @($RawSettings.Keys)) { if ($saved.$k) { $RawSettings[$k] = [string]$saved.$k } }
    } catch { $SettingsWarnings.Add("Could not read $EnforceSettingsFile - using defaults") }
}

function ConvertTo-Flag([string]$Name, [bool]$Default) {
    $v = $RawSettings[$Name]
    if (-not $v) { return $Default }
    if ($v -match '^(1|true|yes|y|on|enabled?)$')     { return $true }
    if ($v -match '^(0|false|no|n|off|disabled?)$')   { return $false }
    $SettingsWarnings.Add("Unrecognised value '$v' for $Name - using default ($Default)")
    return $Default
}

$RunMode = if ($RawSettings.Operation -match '^unblock$') { 'Unblock' } else { 'Remove' }
if ($RawSettings.Operation -and $RawSettings.Operation -notmatch '^(remove|unblock)$') {
    $SettingsWarnings.Add("Unrecognised Operation '$($RawSettings.Operation)' - using Remove")
}
$UseIfeo       = ConvertTo-Flag 'EnableIFEOBlock'     $true
$UseFolderLock = ConvertTo-Flag 'EnableFolderLock'    $true
$UseHosts      = ConvertTo-Flag 'EnableHostsBlock'    $true
$UseDefender   = ConvertTo-Flag 'EnableDefenderPUA'   $true
$UseRecurring  = ConvertTo-Flag 'EnableRecurringTask' $false

# --- Relaunch in 64-bit PowerShell: a 32-bit host would write IFEO/HKLM into WOW6432Node only.
# Settings travel to the child through WAVEBLOCK_* environment variables.
$Is32On64 = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
if ($Is32On64 -and $PSCommandPath) {
    $ps64 = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $ps64) {
        foreach ($k in @($RawSettings.Keys)) {
            [Environment]::SetEnvironmentVariable("WAVEBLOCK_$($k.ToUpper())", $RawSettings[$k], 'Process')
        }
        & $ps64 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
}

$ErrorActionPreference = 'Continue'

# Own script text, used to install the recurring task when SuperOps runs the script inline
$script:SelfText = $null
try {
    $t = [string]$MyInvocation.MyCommand.ScriptBlock
    if ($t -match 'WaveBlock-Enforce' -and $t -match 'RESULT: CLEAN') { $script:SelfText = $t }
} catch { }

# ============================================================================================
# Configuration
# ============================================================================================
$Pattern   = 'wavesor|wavebrowser|wavebrws|swupdater|webnavigator'   # not bare "wave": spares Waves MaxxAudio
$ProcNames = @('wavebrowser','wavebrowser_proxy','wavebrowser_pwa_launcher','notification_helper',
               'SWUpdater','SWUpdaterCore','SWUpdaterSetup','SWUpdaterComRegisterShell64',
               'SWUpdaterCrashHandler','SWUpdaterCrashHandler64',
               'WebNavigatorBrowser','WebNavigatorBrowser_proxy')

# IFEO matches by file name anywhere on disk. Never list generic names (notification_helper.exe).
# Installer names rotate; the folder locks and hosts entries catch the ones this list misses.
$IfeoExecutables = @(
    'wavebrowser.exe','wavebrowser_proxy.exe','wavebrowser_pwa_launcher.exe',
    'SWUpdater.exe','SWUpdaterCore.exe','SWUpdaterSetup.exe','SWUpdaterComRegisterShell64.exe',
    'SWUpdaterCrashHandler.exe','SWUpdaterCrashHandler64.exe',
    'WaveBrowserSetup.exe','WaveBrowser.exe','Wave Browser.exe','Wave Browser Setup.exe','WaveInstaller.exe',
    'WebNavigatorBrowser.exe','WebNavigatorBrowser_proxy.exe','WebNavigatorSetup.exe'
)
$IfeoDebugger = "$env:WINDIR\System32\systray.exe"   # harmless stub that exits immediately
$IfeoRoots = @(
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
)

# Relative to each profile folder
$ProfileInstallDirs = @('Wavesor Software','WebNavigatorBrowser',
                        'AppData\Local\WaveBrowser','AppData\Local\Wavesor Software',
                        'AppData\Local\WebNavigatorBrowser','AppData\Roaming\WaveBrowser',
                        'AppData\Roaming\Wavesor Software','AppData\Local\Temp\Wavesor')
$ProfileLockDirs    = @('Wavesor Software','WebNavigatorBrowser',
                        'AppData\Local\WaveBrowser','AppData\Local\Wavesor Software',
                        'AppData\Local\WebNavigatorBrowser')
$MachineInstallDirs = @("$env:ProgramFiles\WaveBrowser","$env:ProgramFiles\Wavesor","$env:ProgramFiles\Wavesor Software",
                        "${env:ProgramFiles(x86)}\WaveBrowser","${env:ProgramFiles(x86)}\Wavesor","${env:ProgramFiles(x86)}\Wavesor Software",
                        "$env:ProgramData\WaveBrowser","$env:ProgramData\Wavesor","$env:ProgramData\Wavesor Software")

# Not exhaustive - Wave rotates infrastructure. Add domains as you see them.
$BlockedDomains = @('wavebrowser.co','www.wavebrowser.co','download.wavebrowser.co','update.wavebrowser.co',
                    'wavebrowserbase.com','www.wavebrowserbase.com','wavesor.com','www.wavesor.com',
                    'swupdater.com','webnavigatorbrowser.com','www.webnavigatorbrowser.com')

# Our own artefacts are deliberately named so that $Pattern can never match them
$WorkDir          = Join-Path $env:ProgramData 'WaveBlock'
$LogFile          = Join-Path $WorkDir 'WaveBlock.log'
$EnforceTaskName  = 'WaveBlock-Enforce'
$EnforceScript    = Join-Path $WorkDir 'WaveBlock-Enforce.ps1'   # must match the path in the Settings section
$BlockMarkerFile  = 'BLOCKED-BY-IT.txt'
$HostsFile        = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$HostsBeginMarker = '# >>> WaveBlock (managed - do not edit inside this block) >>>'
$HostsEndMarker   = '# <<< WaveBlock <<<'

# Host-specific locations, resolved at run time
$ProfileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$ProfilesDir    = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty $ProfileListKey -ErrorAction SilentlyContinue).ProfilesDirectory)
if (-not $ProfilesDir -or -not (Test-Path -LiteralPath $ProfilesDir)) { $ProfilesDir = Join-Path $env:SystemDrive 'Users' }
$PublicDir      = if ($env:PUBLIC) { $env:PUBLIC } else { Join-Path $ProfilesDir 'Public' }
$TasksDir       = Join-Path $env:SystemRoot 'System32\Tasks'

$script:Removed     = 0
$script:Failed      = New-Object System.Collections.Generic.List[string]
$script:Warnings    = New-Object System.Collections.Generic.List[string]
$script:BlockFailed = New-Object System.Collections.Generic.List[string]

# ============================================================================================
# Helpers
# ============================================================================================
# Write-Output so SuperOps captures it. Functions that RETURN values must not call this.
function Write-Log([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Output $line
    try { Add-Content -LiteralPath $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd'), $line) -ErrorAction Stop } catch { }
}

function Test-Placeholder([string]$Path) { Test-Path -LiteralPath (Join-Path $Path $BlockMarkerFile) }

function Remove-Target([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-Placeholder $Path) { return }      # our own locked folder - leave it
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) { $script:Failed.Add($Path) ; Write-Log "FAILED to remove $Path" }
    else { $script:Removed++ ; Write-Log "Removed $Path" }
}

function Remove-WildcardKeys([string]$Parent, [string]$Regex) {
    if (-not (Test-Path -LiteralPath $Parent)) { return }
    Get-ChildItem -LiteralPath $Parent -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match $Regex } |
        ForEach-Object { Remove-Target $_.PSPath }
}

# Removes values whose name (and, unless -NameOnly, data) matches $Pattern
function Remove-MatchingValues([string]$Key, [switch]$NameOnly) {
    if (-not (Test-Path -LiteralPath $Key)) { return }
    $item = Get-Item -LiteralPath $Key -ErrorAction SilentlyContinue
    if (-not $item) { return }
    foreach ($name in $item.GetValueNames()) {
        $data = [string]$item.GetValue($name)
        if ($name -match $Pattern -or (-not $NameOnly -and $data -match $Pattern)) {
            Remove-ItemProperty -LiteralPath $Key -Name $name -Force -ErrorAction SilentlyContinue
            $chk = Get-Item -LiteralPath $Key -ErrorAction SilentlyContinue
            $still = $chk -and ($chk.GetValueNames() -contains $name)
            if ($chk) { $chk.Close() }
            if ($still) { $script:Failed.Add("$Key :: $name") ; Write-Log "FAILED to remove value $Key :: $name" }
            else { $script:Removed++ ; Write-Log "Removed value $Key :: $name = $data" }
        }
    }
    $item.Close()
}

# Finds COM registrations pointing at Wave. Uses .NET directly because HKLM\Classes\CLSID has
# tens of thousands of keys. Returns sub-paths relative to $ClassesPath. Does not log.
#   CLSID      LocalServer32 / InprocServer32 / InprocHandler32 path matches
#   TypeLib    win32 / win64 path matches
#   Interface  its TypeLib is one of the Wave TypeLibs found above (no paths of its own)
#   AppID      key name or default value matches (e.g. AppID\SWUpdater.exe)
function Find-WaveComKeys([Microsoft.Win32.RegistryKey]$Root, [string]$ClassesPath) {
    $hits = New-Object System.Collections.Generic.List[string]
    $cls = $Root.OpenSubKey($ClassesPath)
    if (-not $cls) { return , $hits }
    try {
        $waveTypeLibs = @{}
        foreach ($pre in '', 'WOW6432Node\') {
            $k = $cls.OpenSubKey("${pre}CLSID")
            if ($k) { try {
                foreach ($id in $k.GetSubKeyNames()) {
                    foreach ($srv in 'LocalServer32','InprocServer32','InprocHandler32') {
                        $s = $k.OpenSubKey("$id\$srv")
                        if (-not $s) { continue }
                        $v = [string]$s.GetValue(''); $s.Close()
                        if ($v -match $Pattern) { $hits.Add("${pre}CLSID\$id"); break }
                    }
                } } finally { $k.Close() } }

            $k = $cls.OpenSubKey("${pre}TypeLib")
            if ($k) { try {
                foreach ($id in $k.GetSubKeyNames()) {
                    $lib = $k.OpenSubKey($id); if (-not $lib) { continue }
                    $hit = $false
                    foreach ($ver in $lib.GetSubKeyNames()) {
                        $vk = $lib.OpenSubKey($ver); if (-not $vk) { continue }
                        foreach ($lcid in $vk.GetSubKeyNames()) {
                            foreach ($plat in 'win32','win64') {
                                $pk = $vk.OpenSubKey("$lcid\$plat")
                                if ($pk) { if ([string]$pk.GetValue('') -match $Pattern) { $hit = $true }; $pk.Close() }
                            }
                        }
                        $vk.Close()
                    }
                    $lib.Close()
                    if ($hit) { $hits.Add("${pre}TypeLib\$id"); $waveTypeLibs[$id] = $true }
                } } finally { $k.Close() } }
        }
        if ($waveTypeLibs.Count) {
            foreach ($pre in '', 'WOW6432Node\') {
                $k = $cls.OpenSubKey("${pre}Interface")
                if ($k) { try {
                    foreach ($iid in $k.GetSubKeyNames()) {
                        $t = $k.OpenSubKey("$iid\TypeLib")
                        if ($t) { $lib = [string]$t.GetValue(''); $t.Close()
                                  if ($waveTypeLibs.ContainsKey($lib)) { $hits.Add("${pre}Interface\$iid") } }
                    } } finally { $k.Close() } }
            }
        }
        $k = $cls.OpenSubKey('AppID')
        if ($k) { try {
            foreach ($id in $k.GetSubKeyNames()) {
                if ($id -match $Pattern) { $hits.Add("AppID\$id"); continue }
                $a = $k.OpenSubKey($id)
                if ($a) { if ([string]$a.GetValue('') -match $Pattern) { $hits.Add("AppID\$id") }; $a.Close() }
            } } finally { $k.Close() } }
    } finally { $cls.Close() }
    return , $hits
}

# Vendor keys, uninstall entries, autostarts, browser registration. Shared by HKLM and HKU.
function Clear-SoftwareRoot([string]$Sw) {
    foreach ($k in 'Wavesor','WaveBrowser','WebNavigatorBrowser','Wavesor Software','Policies\Wavesor',
                   'WOW6432Node\Wavesor','WOW6432Node\WaveBrowser','WOW6432Node\WebNavigatorBrowser',
                   'Microsoft\Windows\CurrentVersion\App Paths\wavebrowser.exe',
                   'WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\wavebrowser.exe') {
        Remove-Target "$Sw\$k"
    }
    foreach ($base in $Sw, "$Sw\WOW6432Node") {
        Remove-WildcardKeys "$base\Clients\StartMenuInternet" '^(WaveBrowser|WebNavigator)'
        Remove-MatchingValues "$base\RegisteredApplications"
        foreach ($run in 'Run','RunOnce') { Remove-MatchingValues "$base\Microsoft\Windows\CurrentVersion\$run" }
        $un = "$base\Microsoft\Windows\CurrentVersion\Uninstall"
        Get-ChildItem -LiteralPath $un -ErrorAction SilentlyContinue | Where-Object {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            ("$($_.PSChildName) $($p.DisplayName) $($p.Publisher) $($p.InstallLocation)") -match "$Pattern|Wave Browser|Eightpoint Technologies"
        } | ForEach-Object { Remove-Target $_.PSPath }
    }
    # StartupApproved data is binary, so match on the value name only
    Remove-MatchingValues "$Sw\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" -NameOnly
}

# ProgIDs, COM registrations and OpenWithProgids references in one Classes root
function Clear-ClassesRoot([Microsoft.Win32.RegistryKey]$Root, [string]$SubPath, [string]$PsPath, [string[]]$Extensions) {
    if (-not (Test-Path -LiteralPath $PsPath)) { return }
    Remove-WildcardKeys $PsPath '^(WaveBrws|WavesorSWUpdater|WebNavigatorBrws|WebNavBrws|WaveBrowser|Wavesor)'
    foreach ($rel in (Find-WaveComKeys $Root $SubPath)) { Remove-Target "$PsPath\$rel" }
    if (-not $Extensions) {
        $Extensions = Get-ChildItem -LiteralPath $PsPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like '.*' } | ForEach-Object { $_.PSChildName }
    }
    foreach ($ext in $Extensions) { Remove-MatchingValues "$PsPath\$ext\OpenWithProgids" -NameOnly }
}

function Clear-UserHive([string]$UserHive, [string]$ClassesHive, [string]$Label) {
    Write-Log "--- Registry: $Label"
    $sw = "Registry::HKEY_USERS\$UserHive\Software"
    Clear-SoftwareRoot $sw

    # UsrClass.dat is what HKU\<SID>\Software\Classes resolves to; fall back if it isn't loaded
    $classesSub = if ($ClassesHive) { $ClassesHive } else { "$UserHive\Software\Classes" }
    Clear-ClassesRoot -Root ([Microsoft.Win32.Registry]::Users) -SubPath $classesSub -PsPath "Registry::HKEY_USERS\$classesSub"

    $fe = "$sw\Microsoft\Windows\CurrentVersion\Explorer\FileExts"
    Get-ChildItem -LiteralPath $fe -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-MatchingValues (Join-Path $_.PSPath 'OpenWithProgids') -NameOnly
    }

    # Report (cannot safely rewrite) UserChoice that still points at Wave
    foreach ($k in "$sw\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice",
                   "$sw\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice",
                   "$fe\.htm\UserChoice", "$fe\.html\UserChoice", "$fe\.pdf\UserChoice") {
        $prog = (Get-ItemProperty -LiteralPath $k -Name ProgId -ErrorAction SilentlyContinue).ProgId
        if ($prog -match $Pattern) {
            $script:Warnings.Add("$Label default handler still Wave ($prog) at $k - set default browser/PDF app in Settings")
        }
    }
}

function Stop-WaveProcesses {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.ExecutablePath -and $_.ExecutablePath -match $Pattern) -or
        ($ProcNames -contains [IO.Path]::GetFileNameWithoutExtension([string]$_.Name) -and -not $_.ExecutablePath)
    })
    foreach ($p in $procs) {
        # notification_helper is a generic Chromium name - only kill it when it runs from a Wave path
        if ($p.Name -eq 'notification_helper.exe' -and $p.ExecutablePath -notmatch $Pattern) { continue }
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Log "Killed process $($p.Name) (PID $($p.ProcessId)) $($p.ExecutablePath)"
    }
    if ($procs.Count) { Start-Sleep -Seconds 3 }
}

function Get-WaveTasks {
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -ne $EnforceTaskName -and (
            $_.TaskName -match $Pattern -or
            ((($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ') -match $Pattern))
    }
}

$script:Shell = New-Object -ComObject WScript.Shell
# Removes .lnk files whose NAME or TARGET points at Wave, wherever they are pinned
function Remove-WaveShortcuts([string]$Root) {
    Get-ChildItem -LiteralPath $Root -Recurse -Filter *.lnk -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $t = ''
        try { $t = $script:Shell.CreateShortcut($_.FullName).TargetPath } catch { }
        if ($_.Name -match $Pattern -or $t -match $Pattern) { Remove-Target $_.FullName }
    }
}

# --------------------------------------------------------------------------------------------
# Blocking helpers
# --------------------------------------------------------------------------------------------
function Get-SidObject([string]$Sid) { New-Object System.Security.Principal.SecurityIdentifier($Sid) }

# SYSTEM/Administrators full control, everyone else read-only, inheritance off. Users have no
# delete-child right inside it, so they cannot empty it, and a non-empty folder cannot be deleted.
function New-LockedFolder([string]$Path) {
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null }
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $none    = [System.Security.AccessControl.PropagationFlags]::None
        $allow   = [System.Security.AccessControl.AccessControlType]::Allow
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner((Get-SidObject 'S-1-5-32-544'))
        foreach ($r in @(@('S-1-5-18','FullControl'), @('S-1-5-32-544','FullControl'),
                         @('S-1-5-32-545','ReadAndExecute'), @('S-1-1-0','ReadAndExecute'))) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                (Get-SidObject $r[0]), $r[1], $inherit, $none, $allow)))
        }
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        $marker = Join-Path $Path $BlockMarkerFile
        if (-not (Test-Path -LiteralPath $marker)) {
            Set-Content -LiteralPath $marker -Encoding ASCII -ErrorAction Stop -Value @(
                'This folder was created by IT to block installation of Wave Browser,',
                'a potentially unwanted application. Do not delete it. Contact IT with questions.')
            Write-Log "Locked placeholder folder $Path"
        }
    } catch {
        $script:BlockFailed.Add("Folder lock $Path : $($_.Exception.Message)")
        Write-Log "FAILED to lock folder $Path : $($_.Exception.Message)"
    }
}

function Set-IfeoBlocks {
    foreach ($ifeo in $IfeoRoots) {
        if (-not (Test-Path -LiteralPath $ifeo)) { continue }
        foreach ($exe in $IfeoExecutables) {
            try {
                $key = Join-Path $ifeo $exe
                if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force -ErrorAction Stop | Out-Null }
                New-ItemProperty -LiteralPath $key -Name 'Debugger' -Value $IfeoDebugger -PropertyType String -Force -ErrorAction Stop | Out-Null
            } catch {
                $script:BlockFailed.Add("IFEO $exe : $($_.Exception.Message)")
                Write-Log "FAILED to set IFEO block for $exe : $($_.Exception.Message)"
            }
        }
    }
    Write-Log "IFEO execution block set for $($IfeoExecutables.Count) executable names"
}

function Remove-IfeoBlocks {
    foreach ($ifeo in $IfeoRoots) {
        foreach ($exe in $IfeoExecutables) {
            $key = Join-Path $ifeo $exe
            if ((Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).Debugger -eq $IfeoDebugger) {
                Remove-Target $key   # only entries this script created
            }
        }
    }
}

# Returns the hosts file lines minus our managed block. Does not log.
function Get-HostsWithoutBlock {
    $out = New-Object System.Collections.Generic.List[string]
    $in = $false
    foreach ($l in @(Get-Content -LiteralPath $HostsFile -ErrorAction Stop)) {
        if ($l -eq $HostsBeginMarker) { $in = $true; continue }
        if ($l -eq $HostsEndMarker)   { $in = $false; continue }
        if (-not $in) { $out.Add($l) }
    }
    while ($out.Count -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) { $out.RemoveAt($out.Count - 1) }
    return , $out
}

function Save-Hosts($Lines) {
    Copy-Item -LiteralPath $HostsFile -Destination (Join-Path $WorkDir 'hosts.bak') -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $HostsFile -Value $Lines -Encoding ASCII -Force -ErrorAction Stop
    & ipconfig.exe /flushdns | Out-Null
}

function Set-HostsBlock {
    try {
        $lines = Get-HostsWithoutBlock
        $lines.Add(''); $lines.Add($HostsBeginMarker)
        foreach ($d in $BlockedDomains) { $lines.Add("0.0.0.0 $d") }
        $lines.Add($HostsEndMarker)
        Save-Hosts $lines
        Write-Log "Hosts file: sinkholed $($BlockedDomains.Count) Wave domains"
    } catch {
        $script:BlockFailed.Add("Hosts file: $($_.Exception.Message)")
        Write-Log "FAILED to update hosts file: $($_.Exception.Message)"
    }
}

function Remove-HostsBlock {
    try { Save-Hosts (Get-HostsWithoutBlock); Write-Log 'Hosts file: removed WaveBlock section' }
    catch { $script:Failed.Add('Hosts file'); Write-Log "FAILED to update hosts file: $($_.Exception.Message)" }
}

function Enable-DefenderPUA {
    if (-not (Get-Command Set-MpPreference -ErrorAction SilentlyContinue)) {
        $script:Warnings.Add('Defender cmdlets not available - PUA protection not set'); return
    }
    try {
        Set-MpPreference -PUAProtection Enabled -ErrorAction Stop
        Write-Log 'Defender PUA protection enabled'
    } catch {
        # Normal when a third-party AV is primary, or Tamper Protection / GPO / Intune owns the setting
        $script:Warnings.Add("Defender PUA protection not set: $($_.Exception.Message)")
    }
}

function Register-EnforcementTask {
    try {
        # Copy ourselves. If SuperOps ran us inline (no file), fall back to our own script text.
        if ($PSCommandPath) {
            if ($PSCommandPath -ne $EnforceScript) { Copy-Item -LiteralPath $PSCommandPath -Destination $EnforceScript -Force -ErrorAction Stop }
        } elseif ($script:SelfText) {
            Set-Content -LiteralPath $EnforceScript -Value $script:SelfText -Encoding UTF8 -Force -ErrorAction Stop
        } else {
            throw 'script was run inline and its text is not available - cannot copy itself'
        }
        # The copy has no SuperOps variables, so persist the settings this run used
        [ordered]@{
            Operation           = 'Remove'
            EnableIFEOBlock     = "$UseIfeo"
            EnableFolderLock    = "$UseFolderLock"
            EnableHostsBlock    = "$UseHosts"
            EnableDefenderPUA   = "$UseDefender"
            EnableRecurringTask = 'True'
        } | ConvertTo-Json | Set-Content -LiteralPath $EnforceSettingsFile -Encoding ASCII -Force -ErrorAction Stop

        $argList = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$EnforceScript`""
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList
        $triggers  = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn),
                       (New-ScheduledTaskTrigger -Daily -At '12:00'))
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $EnforceTaskName -Action $action -Trigger $triggers -Principal $principal `
            -Settings $settings -Description 'Removes Wave Browser and keeps its reinstall blocks in place.' -Force -ErrorAction Stop | Out-Null
        Write-Log "Registered recurring task '$EnforceTaskName' (startup, logon, daily)"
    } catch {
        $script:BlockFailed.Add("Recurring task: $($_.Exception.Message)")
        Write-Log "FAILED to register recurring task: $($_.Exception.Message)"
    }
}

# ============================================================================================
# Start
# ============================================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Output 'RESULT: ERROR - must run as SYSTEM or elevated administrator'; exit 2 }

New-Item -ItemType Directory -Path $WorkDir -Force -ErrorAction SilentlyContinue | Out-Null
Write-Log "=== Wave Browser removal on $env:COMPUTERNAME as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) ==="
Write-Log "Settings: Operation=$RunMode IFEO=$UseIfeo FolderLock=$UseFolderLock Hosts=$UseHosts DefenderPUA=$UseDefender RecurringTask=$UseRecurring"
foreach ($w in $SettingsWarnings) { $script:Warnings.Add($w) }
if ($Is32On64) { $script:Warnings.Add('Running in 32-bit PowerShell and could not relaunch 64-bit - HKLM writes went to WOW6432Node') }

$profiles = @(Get-ChildItem $ProfileListKey -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ Sid = $_.PSChildName; Path = (Get-ItemProperty $_.PSPath).ProfileImagePath }
    } | Where-Object { $_.Sid -match '^S-1-5-21-' -and $_.Path -and (Test-Path -LiteralPath $_.Path) })

# --- Unblock mode ---------------------------------------------------------------------------
if ($RunMode -eq 'Unblock') {
    Write-Log '--- UNBLOCK: removing reinstall blocks'
    Remove-IfeoBlocks
    foreach ($p in $profiles) {
        foreach ($rel in $ProfileLockDirs) {
            $d = Join-Path $p.Path $rel
            if (Test-Placeholder $d) {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $d) { $script:Failed.Add($d); Write-Log "FAILED to remove placeholder $d" }
                else { Write-Log "Removed placeholder $d" }
            }
        }
    }
    Remove-HostsBlock
    if (Get-ScheduledTask -TaskName $EnforceTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $EnforceTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Removed task $EnforceTaskName"
    }
    Remove-Item -LiteralPath $EnforceScript, $EnforceSettingsFile -Force -ErrorAction SilentlyContinue
    if ($script:Failed.Count) { foreach ($f in $script:Failed) { Write-Log "LEFTOVER: $f" }; Write-Log 'RESULT: UNBLOCK-INCOMPLETE'; exit 1 }
    Write-Log 'RESULT: UNBLOCKED'; exit 0
}

# --- Block execution first, so nothing relaunches or reinstalls while we clean up
if ($UseIfeo) { Set-IfeoBlocks }
Stop-WaveProcesses

# --- Scheduled tasks: match on name OR action, unregister with its TaskPath
Write-Log '--- Scheduled tasks'
Get-WaveTasks | ForEach-Object {
    Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue) {
        $script:Failed.Add("Task $($_.TaskPath)$($_.TaskName)"); Write-Log "FAILED to remove task $($_.TaskPath)$($_.TaskName)"
    } else { $script:Removed++; Write-Log "Removed task $($_.TaskPath)$($_.TaskName)" }
}
# Orphaned task XML files that Task Scheduler no longer lists
Get-ChildItem $TasksDir -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $Pattern -and $_.Name -ne $EnforceTaskName } | ForEach-Object { Remove-Target $_.FullName }

# --- Services: match on name or binary path
Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $Pattern -or $_.PathName -match $Pattern } | ForEach-Object {
        Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
        & sc.exe delete $_.Name | Out-Null
        if ($LASTEXITCODE -eq 0) { $script:Removed++; Write-Log "Deleted service $($_.Name)" }
        else { $script:Failed.Add("Service $($_.Name)"); Write-Log "FAILED to delete service $($_.Name)" }
    }

# --- Machine-wide registry
Write-Log '--- Registry: HKLM'
Clear-SoftwareRoot 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE'
$hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
Clear-ClassesRoot -Root $hklm -SubPath 'SOFTWARE\Classes' -PsPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes' `
    -Extensions @('.htm','.html','.shtml','.xht','.xhtml','.pdf','.svg','.webp','.url','.mht','.mhtml')
$hklm.Close()

# --- Per-user registry, loading hives for users who are not logged on
$loaded = New-Object System.Collections.Generic.List[string]
foreach ($p in $profiles) {
    $userHive = $p.Sid
    $classHive = "$($p.Sid)_Classes"
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$userHive")) {
        $alias = "WaveRm_$($p.Sid)"
        $nt = Join-Path $p.Path 'NTUSER.DAT'
        $uc = Join-Path $p.Path 'AppData\Local\Microsoft\Windows\UsrClass.dat'
        if (-not (Test-Path -LiteralPath $nt)) { continue }
        & reg.exe load "HKU\$alias" "$nt" 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$alias")) {
            $script:Warnings.Add("Could not load NTUSER.DAT for $($p.Path) - per-user registry NOT cleaned"); continue
        }
        $loaded.Add($alias); $userHive = $alias; $classHive = $null
        if (Test-Path -LiteralPath $uc) {
            & reg.exe load "HKU\${alias}_Classes" "$uc" 2>&1 | Out-Null
            if (Test-Path -LiteralPath "Registry::HKEY_USERS\${alias}_Classes") { $loaded.Add("${alias}_Classes"); $classHive = "${alias}_Classes" }
        }
    } elseif (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$classHive")) { $classHive = $null }

    Clear-UserHive -UserHive $userHive -ClassesHive $classHive -Label (Split-Path $p.Path -Leaf)
}

# --- Files: every folder in the profiles directory PLUS any ProfileList path that lives elsewhere
Write-Log '--- Files and shortcuts'
Stop-WaveProcesses
$userDirs = @(Get-ChildItem $ProfilesDir -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('All Users','Default User') -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
foreach ($p in $profiles) {
    if (-not ($userDirs | Where-Object { $_.FullName -eq $p.Path })) {
        $d = Get-Item -LiteralPath $p.Path -Force -ErrorAction SilentlyContinue
        if ($d) { $userDirs += $d }
    }
}
foreach ($u in $userDirs) {
    $p = $u.FullName
    foreach ($rel in $ProfileInstallDirs) { Remove-Target (Join-Path $p $rel) }

    Get-ChildItem "$p\Downloads" -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^Wave.?Browser.*\.(exe|msi)$|^Wave.*(Setup|Install).*\.(exe|msi)$|wavebrowser|wavesor|swupdater|WebNavigator.*\.exe$' } |
        ForEach-Object { Remove-Target $_.FullName }

    # Desktop may be redirected into any OneDrive folder ("OneDrive", "OneDrive - Contoso", ...)
    $oneDriveDesktops = @(Get-ChildItem $p -Directory -Filter 'OneDrive*' -Force -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'Desktop' })
    foreach ($root in @("$p\Desktop","$p\AppData\Roaming\Microsoft\Windows\Start Menu",
                        "$p\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch") + $oneDriveDesktops) {
        Remove-WaveShortcuts $root
    }
}
foreach ($root in "$PublicDir\Desktop","$env:ProgramData\Microsoft\Windows\Start Menu") { Remove-WaveShortcuts $root }
foreach ($d in $MachineInstallDirs) { Remove-Target $d }

# --- Retry anything that was locked
if ($script:Failed.Count -gt 0) {
    Write-Log "--- Retrying $($script:Failed.Count) locked item(s)"
    Stop-WaveProcesses
    Start-Sleep -Seconds 3
    $retry = @($script:Failed | Where-Object { $_ -notmatch ' :: ' -and $_ -notmatch '^(Task|Service) ' })
    $keep  = @($script:Failed | Where-Object { $_ -match ' :: ' -or $_ -match '^(Task|Service) ' })
    $script:Failed.Clear()
    foreach ($k in $keep) { $script:Failed.Add($k) }
    foreach ($r in $retry) { Remove-Target $r }
}

# --- Unload any hives we loaded
[gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Seconds 2
foreach ($a in ($loaded | Sort-Object -Descending)) {
    & reg.exe unload "HKU\$a" 2>&1 | Out-Null
    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$a") {
        Start-Sleep -Seconds 2; [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload "HKU\$a" 2>&1 | Out-Null
    }
    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$a") { $script:Warnings.Add("Hive HKU\$a did not unload - reboot before that user logs on") }
}

# --- Remaining blocks (after removal, so placeholders replace the deleted install folders)
Write-Log '--- Reinstall blocks'
if ($UseFolderLock) {
    foreach ($p in $profiles) { foreach ($rel in $ProfileLockDirs) { New-LockedFolder (Join-Path $p.Path $rel) } }
}
if ($UseHosts)     { Set-HostsBlock }
if ($UseDefender)  { Enable-DefenderPUA }
if ($UseRecurring) { Register-EnforcementTask }

# ============================================================================================
# Verification sweep (independent of what we think we did)
# ============================================================================================
Write-Log '--- Verification'
$left = New-Object System.Collections.Generic.List[string]
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -match $Pattern } |
    ForEach-Object { $left.Add("Process still running: $($_.ExecutablePath)") }
foreach ($u in $userDirs) {
    foreach ($rel in $ProfileInstallDirs) {
        $d = Join-Path $u.FullName $rel
        if ((Test-Path -LiteralPath $d) -and -not (Test-Placeholder $d)) { $left.Add("Folder: $d") }
    }
}
foreach ($d in $MachineInstallDirs) { if (Test-Path -LiteralPath $d) { $left.Add("Folder: $d") } }
Get-WaveTasks | ForEach-Object { $left.Add("Task: $($_.TaskPath)$($_.TaskName)") }
foreach ($p in $profiles) {
    $run = "Registry::HKEY_USERS\$($p.Sid)\Software\Microsoft\Windows\CurrentVersion\Run"
    if (Test-Path -LiteralPath $run) {
        $i = Get-Item -LiteralPath $run
        foreach ($n in $i.GetValueNames()) { if ($n -match $Pattern -or [string]$i.GetValue($n) -match $Pattern) { $left.Add("Run value: $run :: $n") } }
        $i.Close()
    }
}
foreach ($f in $script:Failed) { if (-not ($left | Where-Object { $_ -like "*$f" })) { $left.Add("Not removed: $f") } }

# Blocks actually in place?
if ($UseIfeo) {
    foreach ($exe in 'wavebrowser.exe','SWUpdater.exe') {
        if ((Get-ItemProperty -LiteralPath (Join-Path $IfeoRoots[0] $exe) -ErrorAction SilentlyContinue).Debugger -ne $IfeoDebugger) {
            $script:BlockFailed.Add("IFEO block missing for $exe")
        }
    }
}
if ($UseFolderLock) {
    foreach ($p in $profiles) { foreach ($rel in $ProfileLockDirs) {
        $d = Join-Path $p.Path $rel
        if (-not (Test-Placeholder $d) -and -not ($script:BlockFailed | Where-Object { $_ -like "*$d*" })) {
            $script:BlockFailed.Add("Folder lock missing: $d")
        }
    } }
}
if ($UseHosts -and -not (Select-String -LiteralPath $HostsFile -SimpleMatch $HostsBeginMarker -Quiet -ErrorAction SilentlyContinue)) {
    $script:BlockFailed.Add('Hosts block missing')
}

Write-Log "Items removed: $($script:Removed)"
foreach ($w in $script:Warnings)    { Write-Log "WARNING: $w" }
foreach ($b in $script:BlockFailed) { Write-Log "BLOCK MISSING: $b" }

if ($left.Count -gt 0) {
    foreach ($l in $left) { Write-Log "LEFTOVER: $l" }
    Write-Log "RESULT: LEFTOVERS ($($left.Count)) - reboot and re-run"
    exit 1
}
if ($script:BlockFailed.Count -gt 0) {
    Write-Log "RESULT: CLEAN-BLOCK-INCOMPLETE ($($script:BlockFailed.Count))"
    exit 3
}
Write-Log 'RESULT: CLEAN'
exit 0
