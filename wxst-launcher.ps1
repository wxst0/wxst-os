#requires -Version 5.1
<#
    Wxst OS - License Launcher
    ------------------------------------------------------------------
    Keys are generated server-side (see wxst-license-worker.js) and
    validated by calling that server on activation and on every
    launch after. No secret lives in this file - a key cannot be
    forged offline, and you can revoke a leaked key from the server
    at any time, even after it's already been activated.
#>

# ============================== CONFIG ==============================
$ApiBase         = "https://wxst-licenses.taxhriley.workers.dev"
$ApiBase         = $ApiBase.TrimEnd('/')  # guards against a trailing slash breaking /activate routing
$AppName         = "Wxst OS"
$LicenseDir      = Join-Path $env:LOCALAPPDATA "WxstTools"
$LicenseFile     = Join-Path $LicenseDir "license.dat"
$MinAuthSeconds  = 5

# ============================ ANSI / COLOR ===========================
# Enable virtual terminal (ANSI) processing so 24-bit color + cursor
# tricks work even when launched from an old-style cmd/bat window.
Add-Type -Name Win32 -Namespace Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool GetStdHandle_dummy();
[DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction SilentlyContinue

try {
    $stdOut = [Console.Win32]::GetStdHandle(-11)
    $mode = 0
    [Console.Win32]::GetConsoleMode($stdOut, [ref]$mode) | Out-Null
    [Console.Win32]::SetConsoleMode($stdOut, $mode -bor 0x0004) | Out-Null
} catch {}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Esc = [char]27

# Needed for DPAPI-based license cache encryption below - not loaded by
# default in Windows PowerShell 5.1.
Add-Type -AssemblyName System.Security

function Write-Ansi($Text, $R, $G, $B, [switch]$NoNewline) {
    $seq = "$Esc[38;2;$R;$G;${B}m$Text$Esc[0m"
    if ($NoNewline) { Write-Host $seq -NoNewline } else { Write-Host $seq }
}

function Write-AnsiColorName($Text, $ColorName, [switch]$NoNewline) {
    switch ($ColorName) {
        'green' { Write-Ansi $Text 0 220 0 -NoNewline:$NoNewline }
        'red'   { Write-Ansi $Text 220 0 0 -NoNewline:$NoNewline }
        'white' { Write-Ansi $Text 235 235 235 -NoNewline:$NoNewline }
        'gray'  { Write-Ansi $Text 150 150 150 -NoNewline:$NoNewline }
        default { Write-Host $Text -NoNewline:$NoNewline }
    }
}

# Draws a title above a bordered box containing the given lines (each
# line already formatted, e.g. "[1] VPN"). Used for every menu screen
# so options/numbers are easy to scan.
# Dark red -> bright red gradient used across every box.
$BoxGradient = @(
    @{R=90;  G=5;  B=5},
    @{R=120; G=8;  B=8},
    @{R=150; G=12; B=12},
    @{R=180; G=18; B=18},
    @{R=210; G=25; B=25},
    @{R=255; G=40; B=40}
)
function Get-BoxColor($Index, $Total) {
    if ($Total -le 1) { return $BoxGradient[-1] }
    $pos = $Index / [Math]::Max(1, ($Total - 1))
    $i = [int][Math]::Floor($pos * ($BoxGradient.Count - 1))
    return $BoxGradient[$i]
}

function Show-Box($Title, [string[]]$Lines, [switch]$Centered) {
    $consoleWidth = try { [Console]::WindowWidth } catch { 120 }
    $longest = 0
    foreach ($l in (@($Title) + $Lines)) { if ($l.Length -gt $longest) { $longest = $l.Length } }
    $boxWidth = $longest + 4
    if ($boxWidth -gt $consoleWidth - 2) { $boxWidth = $consoleWidth - 2 }
    $inner = $boxWidth - 2
    $leftPad = if ($Centered) { [Math]::Max(0, [int](($consoleWidth - $boxWidth) / 2)) } else { 0 }

    $totalRows = 2 + $Lines.Count  # top border + content rows + bottom border
    $rowIdx = 0

    $titlePad = $leftPad + [Math]::Max(0, [int](($boxWidth - $Title.Length) / 2))
    Write-Host (' ' * $titlePad) -NoNewline
    $tc = $BoxGradient[-1]
    Write-Ansi "$Title`n" $tc.R $tc.G $tc.B

    Write-Host (' ' * $leftPad) -NoNewline
    $c = Get-BoxColor $rowIdx $totalRows
    Write-Ansi ('┌' + ('─' * $boxWidth) + "┐`n") $c.R $c.G $c.B
    $rowIdx++

    foreach ($l in $Lines) {
        $content = ' ' + $l
        if ($content.Length -lt $inner) { $content = $content.PadRight($inner) }
        elseif ($content.Length -gt $inner) { $content = $content.Substring(0, $inner) }
        $c = Get-BoxColor $rowIdx $totalRows
        Write-Host (' ' * $leftPad) -NoNewline
        Write-Ansi '│' $c.R $c.G $c.B -NoNewline
        Write-Host $content -NoNewline
        Write-Ansi "│`n" $c.R $c.G $c.B
        $rowIdx++
    }

    $c = Get-BoxColor $rowIdx $totalRows
    Write-Host (' ' * $leftPad) -NoNewline
    Write-Ansi ('└' + ('─' * $boxWidth) + "┘`n") $c.R $c.G $c.B
}

# Dark red -> bright red gradient used for the tree-style choice menus.
$TreeGradient = @(
    @{R=90;  G=5;  B=5},
    @{R=120; G=8;  B=8},
    @{R=150; G=12; B=12},
    @{R=180; G=18; B=18},
    @{R=210; G=25; B=25},
    @{R=255; G=40; B=40}
)
function Get-TreeColor($Index, $Total) {
    if ($Total -le 1) { return $TreeGradient[-1] }
    $pos = $Index / [Math]::Max(1, ($Total - 1))
    $i = [int][Math]::Floor($pos * ($TreeGradient.Count - 1))
    return $TreeGradient[$i]
}

# Renders a branch-style choice list:
#   |=(1) Option one
#   |=(2) Option two
#   L=(3) Option three
#   L==>
# $Lines are plain labels ("OS Tools", "Back") - numbering/lettering
# and the (N) formatting is added here, in order, with the last entry
# getting the elbow connector automatically.
function Show-TreeMenu($Title, [string[]]$Lines, [switch]$Centered) {
    $consoleWidth = try { [Console]::WindowWidth } catch { 120 }
    $longest = 0
    foreach ($l in $Lines) { if (('╠═' + $l).Length -gt $longest) { $longest = ('╠═' + $l).Length } }
    $leftPad = if ($Centered) { [Math]::Max(0, [int](($consoleWidth - $longest) / 2)) } else { 0 }

    if ($Title) {
        Write-Host (' ' * $leftPad) -NoNewline
        Write-AnsiColorName "$Title`n" 'white'
    }

    $totalRows = $Lines.Count + 1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $connector = if ($i -eq $Lines.Count - 1) { '╚═' } else { '╠═' }
        $c = Get-TreeColor $i $totalRows
        Write-Host (' ' * $leftPad) -NoNewline
        Write-Ansi "$connector$($Lines[$i])`n" $c.R $c.G $c.B
    }
    $c = Get-TreeColor $Lines.Count $totalRows
    Write-Host (' ' * $leftPad) -NoNewline
    Write-Ansi "  ╚══>`n" $c.R $c.G $c.B
}

# ============================== BANNER ===============================
# "WXST OS" - Bloody font
$BannerLines = @(
    ' █     █░▒██   ██▒  ██████ ▄▄▄█████▓   ▒█████    ██████ ',
    '▓█░ █ ░█░▒▒ █ █ ▒░▒██    ▒ ▓  ██▒ ▓▒  ▒██▒  ██▒▒██    ▒ ',
    '▒█░ █ ░█ ░░  █   ░░ ▓██▄   ▒ ▓██░ ▒░  ▒██░  ██▒░ ▓██▄   ',
    '░█░ █ ░█  ░ █ █ ▒   ▒   ██▒░ ▓██▓ ░   ▒██   ██░  ▒   ██▒',
    '░░██▒██▓ ▒██▒ ▒██▒▒██████▒▒  ▒██▒ ░   ░ ████▓▒░▒██████▒▒',
    '░ ▓░▒ ▒  ▒▒ ░ ░▓ ░▒ ▒▓▒ ▒ ░  ▒ ░░     ░ ▒░▒░▒░ ▒ ▒▓▒ ▒ ░',
    '  ▒ ░ ░  ░░   ░▒ ░░ ░▒  ░ ░    ░        ░ ▒ ▒░ ░ ░▒  ░ ░',
    '  ░   ░   ░    ░  ░  ░  ░    ░        ░ ░ ░ ▒  ░  ░  ░  ',
    '    ░     ░    ░        ░                 ░ ░        ░  '
)

# Dark red (top) -> bright red (bottom) gradient
$GradientStops = @(
    @{R=60;  G=0;   B=0},
    @{R=90;  G=5;   B=5},
    @{R=115; G=10;  B=10},
    @{R=140; G=15;  B=15},
    @{R=165; G=20;  B=20},
    @{R=190; G=25;  B=25},
    @{R=215; G=30;  B=30},
    @{R=235; G=35;  B=35},
    @{R=255; G=45;  B=45}
)

function Show-Banner([switch]$Centered) {
    $width = try { [Console]::WindowWidth } catch { 120 }
    for ($i = 0; $i -lt $BannerLines.Count; $i++) {
        $line = $BannerLines[$i]
        $pad = 0
        if ($Centered) {
            $pad = [Math]::Max(0, [int](($width - $line.Length) / 2))
        }
        $c = $GradientStops[$i]
        Write-Host (' ' * $pad) -NoNewline
        Write-Ansi $line $c.R $c.G $c.B
    }
}

# =============================== HWID =================================
function Get-HWID {
    try {
        $uuid = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID
        $cpu  = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1).ProcessorId
        $disk = (Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop | Select-Object -First 1).SerialNumber
        $raw  = "$uuid|$cpu|$disk"
    } catch {
        # Fallback if WMI/CIM is unavailable for some reason
        $raw = "$env:COMPUTERNAME|$env:PROCESSOR_IDENTIFIER|$env:USERNAME"
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
    $hex = -join ($hash | ForEach-Object { $_.ToString('X2') })
    return $hex.Substring(0, 16)
}

# ========================= LICENSE / SERVER CALL =========================
function Invoke-Activation($KeyString, $Hwid) {
    $keyClean = $KeyString.Trim().ToUpper()
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "$ApiBase/activate" `
            -ContentType "application/json" `
            -Body (@{ key = $keyClean; hwid = $Hwid } | ConvertTo-Json) `
            -ErrorAction Stop
        return @{ Ok = $true; Label = $resp.label; ExpiresAt = $resp.expiresAt; Duration = $resp.duration }
    } catch {
        $msg = "Could not reach the license server."
        if ($_.ErrorDetails.Message) {
            try {
                $errObj = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($errObj.error) { $msg = $errObj.error }
            } catch {}
        }
        return @{ Ok = $false; Error = $msg }
    }
}

function Protect-Bytes($Bytes) {
    return [System.Security.Cryptography.ProtectedData]::Protect(
        $Bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
}
function Unprotect-Bytes($Bytes) {
    return [System.Security.Cryptography.ProtectedData]::Unprotect(
        $Bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
}

function Save-LicenseCache($Hwid, $FullKey, $Label, $ExpiresAt) {
    New-Item -ItemType Directory -Path $LicenseDir -Force | Out-Null
    $obj = [PSCustomObject]@{
        Hwid      = $Hwid
        Key       = $FullKey.Trim().ToUpper()
        Label     = $Label
        ExpiryUtc = $ExpiresAt
    }
    $json = $obj | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $protected = Protect-Bytes $bytes
    [IO.File]::WriteAllBytes($LicenseFile, $protected)
}

function Read-LicenseCache {
    if (-not (Test-Path $LicenseFile)) { return $null }
    try {
        $bytes = [IO.File]::ReadAllBytes($LicenseFile)
        $plain = Unprotect-Bytes $bytes
        $json = [System.Text.Encoding]::UTF8.GetString($plain)
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Mask-Key($KeyString) {
    $k = $KeyString.Trim()
    if ($k.Length -le 10) { return $k }
    return "$($k.Substring(0,9))****$($k.Substring($k.Length-4))"
}

# =============================== SCREENS ================================
function Show-HeaderScreen {
    Clear-Host
    Show-Banner
    Write-Host ""
    $hwid = Get-HWID
    Write-AnsiColorName "PC Name : " 'gray'; Write-Host $env:COMPUTERNAME
    Write-AnsiColorName "Account : " 'gray'; Write-Host $env:USERNAME
    Write-AnsiColorName "OS      : " 'gray'; Write-Host ((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)
    Write-AnsiColorName "HWID    : " 'gray'; Write-AnsiColorName $hwid 'white'
    Write-Host ""
    Write-Host ""
    Write-Host ""
    Write-Host ""
    return $hwid
}

function Invoke-KeyPrompt($Hwid) {
    while ($true) {
        Write-AnsiColorName "[" 'white' -NoNewline
        Write-AnsiColorName "+" 'green' -NoNewline
        Write-AnsiColorName "] key: " 'white' -NoNewline
        $inputKey = Read-Host

        # ---- authorizing animation (>=5s), plus flashes between * and + in red
        # Kick off the real server call in the background, then run the
        # animation for at least $MinAuthSeconds regardless of how fast
        # the server actually answers.
        $job = Start-Job -ScriptBlock {
            param($api, $k, $h)
            $body = @{ key = $k; hwid = $h } | ConvertTo-Json
            try {
                $r = Invoke-RestMethod -Method Post -Uri "$api/activate" -ContentType "application/json" -Body $body -ErrorAction Stop
                return @{ Ok = $true; Label = $r.label; ExpiresAt = $r.expiresAt; Duration = $r.duration }
            } catch {
                $msg = "Could not reach the license server."
                if ($_.ErrorDetails.Message) {
                    try { $e = $_.ErrorDetails.Message | ConvertFrom-Json; if ($e.error) { $msg = $e.error } } catch {}
                }
                return @{ Ok = $false; Error = $msg }
            }
        } -ArgumentList $ApiBase, $inputKey, $Hwid

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $toggle = $true
        while ($sw.Elapsed.TotalSeconds -lt $MinAuthSeconds -or $job.State -eq 'Running') {
            $sym = if ($toggle) { '*' } else { '+' }
            Write-Host "`r" -NoNewline
            Write-AnsiColorName "[" 'white' -NoNewline
            Write-Ansi $sym 220 0 0 -NoNewline
            Write-AnsiColorName "] authorizing" 'white' -NoNewline
            Write-Host ("." * (1 + ([int]($sw.Elapsed.TotalSeconds * 2) % 3))) -NoNewline
            Write-Host "   " -NoNewline
            Start-Sleep -Milliseconds 250
            $toggle = -not $toggle
        }
        $result = Receive-Job -Job $job -Wait
        Remove-Job -Job $job -Force
        Write-Host "`r" -NoNewline
        Write-Host (' ' * 60) -NoNewline
        Write-Host "`r" -NoNewline

        if (-not $result.Ok) {
            Write-AnsiColorName "[" 'white' -NoNewline
            Write-AnsiColorName "!" 'red' -NoNewline
            Write-AnsiColorName "] $($result.Error)" 'red'
            continue
        }

        Save-LicenseCache -Hwid $Hwid -FullKey $inputKey -Label $result.Label -ExpiresAt $result.ExpiresAt

        Write-AnsiColorName "[" 'white' -NoNewline
        Write-AnsiColorName "+" 'green' -NoNewline
        Write-AnsiColorName "] Success, your license has been authorized(" 'white' -NoNewline
        Write-AnsiColorName $result.Label 'green' -NoNewline
        Write-AnsiColorName ")" 'white'
        Start-Sleep -Seconds 2
        return @{ Label = $result.Label; ExpiresAt = $result.ExpiresAt; MaskedKey = Mask-Key $inputKey }
    }
}

function Get-TimeLeftText($ExpiryUtcString) {
    if ($ExpiryUtcString -eq 'LIFETIME') { return "Lifetime (never expires)" }
    $expiry = [DateTime]::Parse($ExpiryUtcString, $null, [Globalization.DateTimeStyles]::RoundtripKind)
    $remaining = $expiry - [DateTime]::UtcNow
    if ($remaining.TotalSeconds -le 0) { return $null }
    if ($remaining.TotalDays -ge 1) { return "{0}d {1}h remaining" -f [int]$remaining.Days, $remaining.Hours }
    if ($remaining.TotalHours -ge 1) { return "{0}h {1}m remaining" -f [int]$remaining.Hours, $remaining.Minutes }
    return "{0}m remaining" -f [int]$remaining.TotalMinutes
}

# ------------------------------ Section: OS Tools ------------------------------
function Invoke-Debloat {
    Clear-Host
    Show-TreeMenu "Debloat / Tweaks" @("Launching Chris Titus Tech's WinUtil (christitus.com/win)...")
    Write-Host ""
    try {
        Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -Command "irm christitus.com/win | iex"'
    } catch {
        Write-AnsiColorName "[!] " 'red' -NoNewline
        Write-Host "Couldn't launch WinUtil (needs admin elevation): $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "WinUtil opens in its own elevated window - press Enter here to return to the menu"
}

function Invoke-SystemInfo {
    Clear-Host
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $mem = $os.TotalVisibleMemorySize, $os.FreePhysicalMemory
    $totalGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeGB  = [Math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $uptime = (Get-Date) - $os.LastBootUpTime

    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue

    $lines = @(
        "OS       : $($os.Caption)",
        "CPU      : $($cpu.Name)",
        "RAM      : $freeGB GB free / $totalGB GB total",
        "Uptime   : {0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
    )
    foreach ($d in $disks) {
        $freeD = [Math]::Round($d.FreeSpace / 1GB, 1)
        $totalD = [Math]::Round($d.Size / 1GB, 1)
        $lines += "Disk $($d.DeviceID)   : $freeD GB free / $totalD GB total"
    }
    Show-Box "System Info" $lines
    Write-Host ""
    Read-Host "Press Enter to return to the menu"
}

function Invoke-ProcessManager {
    while ($true) {
        Clear-Host
        $procs = Get-Process | Sort-Object -Property CPU -Descending | Select-Object -First 15
        $lines = @()
        $i = 1
        $indexed = @()
        foreach ($p in $procs) {
            $cpuTime = if ($p.CPU) { [Math]::Round($p.CPU, 1) } else { 0 }
            $mem = [Math]::Round($p.WorkingSet64 / 1MB, 1)
            $lines += "($i) $($p.ProcessName)  (PID $($p.Id), ${mem}MB, CPU ${cpuTime}s)"
            $indexed += [PSCustomObject]@{ Index = $i; Id = $p.Id; Name = $p.ProcessName }
            $i++
        }
        Show-TreeMenu "Process Manager (top 15 by CPU)" ($lines + @("(B) Back"))
        $choice = Read-Host "Enter a number to end that process, or B"
        if ($choice.Trim().ToUpper() -eq 'B') { return }
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx)) {
            $target = $indexed | Where-Object { $_.Index -eq $idx }
            if ($target) {
                $confirm = Read-Host "End '$($target.Name)' (PID $($target.Id))? (y/N)"
                if ($confirm.Trim().ToUpper() -eq 'Y') {
                    try {
                        Stop-Process -Id $target.Id -Force -ErrorAction Stop
                        Write-AnsiColorName "[+] Process ended.`n" 'green'
                    } catch {
                        Write-AnsiColorName "[!] " 'red' -NoNewline
                        Write-Host "Couldn't end process: $($_.Exception.Message)"
                    }
                    Start-Sleep -Seconds 1
                }
            }
        }
    }
}

function Invoke-TempCleanup {
    Clear-Host
    Show-Box "Temp File Cleanup" @("Clearing user + Windows temp folders...")
    $paths = @($env:TEMP, "$env:WINDIR\Temp")
    $freedBytes = 0
    foreach ($p in $paths) {
        if (Test-Path $p) {
            Get-ChildItem -Path $p -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $freedBytes += $_.Length
                    Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
                } catch {}
            }
        }
    }
    $freedMB = [Math]::Round($freedBytes / 1MB, 1)
    Write-Host ""
    Write-AnsiColorName "[+] " 'green' -NoNewline
    Write-Host "Done. Freed approximately $freedMB MB (files in use were skipped)."
    Write-Host ""
    Read-Host "Press Enter to return to the menu"
}

function Invoke-StartupManager {
    while ($true) {
        Clear-Host
        $items = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object -First 15
        if (-not $items) {
            Show-Box "Startup Programs" @("No startup entries found (or need to run as admin to see all).")
            Read-Host "Press Enter to return to the menu"
            return
        }
        $lines = @()
        $i = 1
        $indexed = @()
        foreach ($it in $items) {
            $lines += "($i) $($it.Name)  [$($it.Location)]"
            $indexed += [PSCustomObject]@{ Index = $i; Name = $it.Name; Command = $it.Command; Location = $it.Location; User = $it.User }
            $i++
        }
        Show-TreeMenu "Startup Programs" ($lines + @("(B) Back"))
        $choice = Read-Host "Enter a number for details, or B"
        if ($choice.Trim().ToUpper() -eq 'B') { return }
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx)) {
            $target = $indexed | Where-Object { $_.Index -eq $idx }
            if ($target) {
                Write-Host ""
                Show-Box "Startup Entry" @(
                    "Name    : $($target.Name)",
                    "Command : $($target.Command)",
                    "Location: $($target.Location)"
                )
                Write-AnsiColorName "`nTo disable this, remove it via Task Manager > Startup, or the registry/folder shown above.`n" 'gray'
                Read-Host "Press Enter to continue"
            }
        }
    }
}

function Show-OsToolsMenu {
    while ($true) {
        Clear-Host
        Show-TreeMenu "OS Tools" @("(1) Debloat / Tweaks (WinUtil)", "(2) System Info", "(3) Process Manager", "(4) Temp File Cleanup", "(5) Startup Program Manager", "(B) Back")
        $choice = Read-Host "ostools>"
        switch ($choice.Trim().ToUpper()) {
            '1' { Invoke-Debloat }
            '2' { Invoke-SystemInfo }
            '3' { Invoke-ProcessManager }
            '4' { Invoke-TempCleanup }
            '5' { Invoke-StartupManager }
            'B' { return }
        }
    }
}

# ------------------------------ Section 3: IP Tools ------------------------------
function Invoke-IpCleaner {
    Write-Host "Flushing DNS cache..."
    ipconfig /flushdns | Out-Null
    Write-Host "Releasing IP..."
    ipconfig /release | Out-Null
    Write-Host "Renewing IP..."
    ipconfig /renew | Out-Null
    Write-AnsiColorName "[+] " 'green' -NoNewline
    Write-Host "Done."
}

function Invoke-IpGeolocation {
    $target = Read-Host "IP address to look up (blank = your own public IP)"
    try {
        $url = if ($target) { "http://ip-api.com/json/$target" } else { "http://ip-api.com/json/" }
        $r = Invoke-RestMethod -Uri $url -ErrorAction Stop
        if ($r.status -eq 'fail') {
            Write-AnsiColorName "[!] " 'red' -NoNewline
            Write-Host $r.message
        } else {
            Write-Host "IP      : $($r.query)"
            Write-Host "City    : $($r.city)"
            Write-Host "Region  : $($r.regionName)"
            Write-Host "Country : $($r.country)"
            Write-Host "ISP     : $($r.isp)"
            Write-Host "Org     : $($r.org)"
            Write-Host "Lat/Lon : $($r.lat), $($r.lon)"
        }
    } catch {
        Write-AnsiColorName "[!] " 'red' -NoNewline
        Write-Host "Lookup failed: $($_.Exception.Message)"
    }
}

function Invoke-ReverseIp {
    $target = Read-Host "IP address to reverse-lookup (find other domains on it)"
    if (-not $target) { return }
    try {
        $r = Invoke-RestMethod -Uri "https://api.hackertarget.com/reverseiplookup/?q=$target" -ErrorAction Stop
        Write-Host $r
    } catch {
        Write-AnsiColorName "[!] " 'red' -NoNewline
        Write-Host "Lookup failed: $($_.Exception.Message)"
    }
}

function Invoke-ReverseDns {
    $target = Read-Host "IP address to reverse-DNS"
    if (-not $target) { return }
    try {
        $entry = [System.Net.Dns]::GetHostEntry($target)
        Write-Host "Hostname: $($entry.HostName)"
    } catch {
        Write-AnsiColorName "[!] " 'red' -NoNewline
        Write-Host "No PTR record found / lookup failed."
    }
}

function Show-IpToolsMenu {
    while ($true) {
        Clear-Host
        Show-TreeMenu "IP Tools" @("(1) IP Cleaner (flush DNS + renew IP)", "(2) IP Geolocation", "(3) Reverse IP", "(4) Reverse DNS", "(B) Back")
        $choice = Read-Host "iptools>"
        switch ($choice.Trim().ToUpper()) {
            '1' { Invoke-IpCleaner; Read-Host "`nPress Enter to continue" }
            '2' { Invoke-IpGeolocation; Read-Host "`nPress Enter to continue" }
            '3' { Invoke-ReverseIp; Read-Host "`nPress Enter to continue" }
            '4' { Invoke-ReverseDns; Read-Host "`nPress Enter to continue" }
            'B' { return }
        }
    }
}

# ------------------------------ Section: Misc ------------------------------
function Invoke-WhoisLookup {
    $target = Read-Host "Domain to WHOIS"
    if (-not $target) { return }
    try {
        $r = Invoke-RestMethod -Uri "https://api.hackertarget.com/whois/?q=$target" -ErrorAction Stop
        Write-Host $r
    } catch {
        Write-AnsiColorName "[!] " 'red' -NoNewline
        Write-Host "Lookup failed: $($_.Exception.Message)"
    }
}

function Invoke-DnsRecordLookup {
    $target = Read-Host "Domain to look up DNS records for"
    if (-not $target) { return }
    foreach ($type in @('A', 'AAAA', 'MX', 'NS', 'TXT')) {
        try {
            $records = Resolve-DnsName -Name $target -Type $type -ErrorAction Stop
            foreach ($rec in $records) {
                Write-Host "$type : $($rec | Select-Object -ExpandProperty * -ErrorAction SilentlyContinue | Out-String)".Trim()
            }
        } catch { }
    }
}

function Invoke-RemoteDesktop {
    Clear-Host
    Show-Box "Remote Desktop Connection" @("Enter connection details below") -Centered
    Write-Host ""
    $ip   = Read-Host "Remote IP or hostname"
    if (-not $ip) { return }
    $user = Read-Host "Username"
    $securePass = Read-Host "Password" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
    $plainPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

    try {
        cmdkey /generic:$ip /user:$user /pass:$plainPass | Out-Null
        Write-Host "Connecting to $ip..."
        Start-Process mstsc -ArgumentList "/v:$ip" -Wait
    } finally {
        # Don't leave the credential sitting in Windows Credential Manager
        cmdkey /delete:$ip | Out-Null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $plainPass = $null
    }
}

# ---- Network device scan (discovery only - see note below) ----
# Actively disconnecting or throttling another device on the network
# from a regular PC requires ARP spoofing / deauth techniques - the
# same technique used for unauthorized network attacks, so that's not
# included here regardless of which device it'd be pointed at. If your
# router exposes a real local admin API (many do), a script that logs
# in with YOUR OWN router admin credentials and calls its legitimate
# device-blocking/QoS feature is a completely different, buildable
# thing - tell me the router brand/model and I can look at that.
function Invoke-NetworkScan {
    Clear-Host
    Write-Host "Scanning local subnet (this populates the ARP table, may take a few seconds)..."

    $localIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notlike '169.254*' } |
        Select-Object -First 1).IPAddress
    if (-not $localIp) {
        Write-AnsiColorName "[!] " 'red' -NoNewline
        Write-Host "Couldn't determine your local IP/subnet."
        return
    }
    $prefix = ($localIp -split '\.')[0..2] -join '.'

    $jobs = 1..254 | ForEach-Object {
        Start-Job -ScriptBlock { param($p, $i) Test-Connection -ComputerName "$p.$i" -Count 1 -Quiet -TimeoutSeconds 1 } -ArgumentList $prefix, $_
    }
    $jobs | Wait-Job -Timeout 20 | Out-Null
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue

    $arp = arp -a | Select-String "$prefix\." | ForEach-Object {
        $parts = ($_ -replace '\s+', ' ').Trim().Split(' ')
        if ($parts.Count -ge 2) { [PSCustomObject]@{ IP = $parts[0]; MAC = $parts[1] } }
    } | Where-Object { $_.MAC -match '-' } | Sort-Object IP -Unique

    if (-not $arp) {
        Write-AnsiColorName "No devices found." 'gray'
        return
    }

    $devices = @()
    $i = 1
    foreach ($d in $arp) {
        $hostname = try { ([System.Net.Dns]::GetHostEntry($d.IP)).HostName } catch { "" }
        $devices += [PSCustomObject]@{ Index = $i; IP = $d.IP; MAC = $d.MAC; Hostname = $hostname }
        $i++
    }

    $boxLines = $devices | ForEach-Object { "($($_.Index)) $($_.IP)  $($_.MAC)  $($_.Hostname)" }
    Clear-Host
    Show-TreeMenu "Network Device Scan" $boxLines
    Write-Host ""
    $choice = Read-Host "Select a device number for details (or Enter to skip)"
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx)) {
        $selected = $devices | Where-Object { $_.Index -eq $idx }
        if ($selected) {
            Write-Host ""
            Show-Box "Device Detail" @(
                "IP       : $($selected.IP)",
                "MAC      : $($selected.MAC)",
                "Hostname : $($selected.Hostname)"
            ) -Centered
            Write-Host ""
            Write-AnsiColorName "Disconnect / throttle isn't available from here - see the note in the script for why, and use your router's device management / parental controls for that.`n" 'gray'
        }
    }
}

function Show-MiscMenu {
    while ($true) {
        Clear-Host
        Show-TreeMenu "Misc" @("(1) WHOIS Lookup", "(2) DNS Record Lookup", "(3) Remote Desktop Connection", "(4) Scan Network Devices", "(B) Back")
        $choice = Read-Host "misc>"
        switch ($choice.Trim().ToUpper()) {
            '1' { Invoke-WhoisLookup; Read-Host "`nPress Enter to continue" }
            '2' { Invoke-DnsRecordLookup; Read-Host "`nPress Enter to continue" }
            '3' { Invoke-RemoteDesktop; Read-Host "`nPress Enter to continue" }
            '4' { Invoke-NetworkScan; Read-Host "`nPress Enter to continue" }
            'B' { return }
        }
    }
}

function Show-MainMenu($Hwid, $Label, $ExpiryUtcString, $MaskedKey) {
    while ($true) {
        Clear-Host
        Show-Banner -Centered
        Write-Host ""
        $width = try { [Console]::WindowWidth } catch { 120 }
        $lines = @(
            "Username: $env:USERNAME@$env:COMPUTERNAME",
            "License : $MaskedKey  ($Label)"
        )
        $timeLeft = Get-TimeLeftText $ExpiryUtcString
        $lines += "Status  : $timeLeft"

        foreach ($l in $lines) {
            $pad = [Math]::Max(0, [int](($width - $l.Length) / 2))
            Write-Host (' ' * $pad) -NoNewline
            Write-AnsiColorName "$l`n" 'green'
        }
        Write-Host ""
        Show-TreeMenu "Menu" @("(1) OS Tools", "(2) IP Tools", "(3) Misc", "(Q) Quit")
        Write-Host ""

        $choice = Read-Host "wxst>"
        switch ($choice.Trim().ToUpper()) {
            '1' { Show-OsToolsMenu }
            '2' { Show-IpToolsMenu }
            '3' { Show-MiscMenu }
            'Q' {
                Write-Host ""
                Write-Host "Closing $AppName..."
                Start-Sleep -Milliseconds 400
                exit 0
            }
            default { Write-Host "Unknown option." }
        }
    }
}

# ================================ MAIN ==================================
$hwid = Show-HeaderScreen
$cache = Read-LicenseCache
$needsKey = $true
$activeLabel = $null
$activeExpiry = $null
$activeMasked = $null

if ($cache -and $cache.Hwid -eq $hwid) {
    # Re-validate against the server every launch, so a revoked key
    # stops working immediately even though it's cached locally.
    $check = Invoke-Activation -KeyString $cache.Key -Hwid $hwid
    if ($check.Ok) {
        $needsKey = $false
        $activeLabel = $check.Label
        $activeExpiry = $check.ExpiresAt
        $activeMasked = Mask-Key $cache.Key
        Save-LicenseCache -Hwid $hwid -FullKey $cache.Key -Label $check.Label -ExpiresAt $check.ExpiresAt
    } elseif ($check.Error -eq 'Could not reach the license server.') {
        # Offline grace: trust the local cache if it hasn't expired yet
        $t = Get-TimeLeftText $cache.ExpiryUtc
        if ($t -or $cache.ExpiryUtc -eq 'LIFETIME') {
            $needsKey = $false
            $activeLabel = $cache.Label
            $activeExpiry = $cache.ExpiryUtc
            $activeMasked = Mask-Key $cache.Key
        }
    }
    # any other error (revoked / expired / bound elsewhere) -> needsKey stays true
}

if ($needsKey) {
    $auth = Invoke-KeyPrompt -Hwid $hwid
    Show-MainMenu -Hwid $hwid -Label $auth.Label -ExpiryUtcString $auth.ExpiresAt -MaskedKey $auth.MaskedKey
} else {
    Show-MainMenu -Hwid $hwid -Label $activeLabel -ExpiryUtcString $activeExpiry -MaskedKey $activeMasked
}
