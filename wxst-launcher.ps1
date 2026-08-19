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
# $Lines are plain labels ("Woofing", "Back") - numbering/lettering
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

# ============================ TOOL PLUG-IN POINTS ============================
$VpnConnectionName   = ""                          # name of a Windows VPN connection (Settings > VPN) to drive with rasdial
$PhoneVpnScript      = ""                          # path to your own script that talks to your phone (adb, tasker webhook, etc)

function Invoke-ExternalScript($Path, $FriendlyName) {
    if (-not $Path -or -not (Test-Path $Path)) {
        Write-AnsiColorName "[!] " 'red' -NoNewline
        Write-Host "$FriendlyName isn't configured yet. Set its path/script and try again."
        return
    }
    Write-Host "Launching $FriendlyName..."
    try {
        & $Path
    } catch {
        Write-AnsiColorName "[!] " 'red' -NoNewline
        Write-Host "Error running $FriendlyName`: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "Press Enter to return to the menu"
}

# ------------------------------ Section: Woofing ------------------------------
function Invoke-VpnConnect {
    if (-not $VpnConnectionName) {
        Write-AnsiColorName "[!] " 'red' -NoNewline
        Write-Host "No VPN connection configured. Set `$VpnConnectionName to a connection you've set up under Windows Settings > VPN."
        return
    }
    Write-Host "Connecting to VPN '$VpnConnectionName'..."
    rasdial "$VpnConnectionName"
}

function Invoke-VpnDisconnect {
    if (-not $VpnConnectionName) { return }
    rasdial "$VpnConnectionName" /disconnect
}

function Show-VpnMenu {
    while ($true) {
        Clear-Host
        Show-TreeMenu "VPN" @("(1) Connect", "(2) Disconnect", "(B) Back")
        $choice = Read-Host "vpn>"
        switch ($choice.Trim().ToUpper()) {
            '1' { Invoke-VpnConnect; Read-Host "Press Enter to continue" }
            '2' { Invoke-VpnDisconnect; Read-Host "Press Enter to continue" }
            'B' { return }
        }
    }
}

function Invoke-PhoneInfo {
    Clear-Host

    $PnPDevices = Get-CimInstance -ClassName Win32_PnPEntity | Where-Object {
        $_.Service -match "winusb|wceusbsh|usbser|tsusbhub" -or
        $_.Description -match "Phone|Mobile|Android|Modem|ADB" -or
        $_.DeviceClass -match "Modem"
    }

    $boxLines = @()
    if ($PnPDevices) {
        foreach ($Device in $PnPDevices) {
            $boxLines += "$($Device.Caption)"
            $boxLines += "  Status: $($Device.Status)   ID: $($Device.DeviceID)"
        }
    } else {
        $boxLines += "No connected phone hardware or ADB interfaces detected via USB."
    }
    Show-Box "Connected Phone Hardware Info" $boxLines -Centered
    Write-Host ""

    Write-AnsiColorName "[" 'white' -NoNewline
    Write-AnsiColorName "+" 'green' -NoNewline
    Write-AnsiColorName "] Phone Number: " 'white' -NoNewline
    $PhoneNumber = Read-Host

    if (-not [string]::IsNullOrWhiteSpace($PhoneNumber)) {
        Write-Host ""
        Write-AnsiColorName "[" 'white' -NoNewline
        Write-AnsiColorName "+" 'green' -NoNewline
        Write-AnsiColorName "] Connected`n" 'white'
        Show-PhoneNumberInfo -PhoneNumber $PhoneNumber
    } else {
        Write-AnsiColorName "No phone number entered." 'red'
    }
    Write-Host ""
    Read-Host "Press Enter to return to the menu"
}

# Best-effort, offline NANP area code -> region lookup. Not exhaustive,
# and area codes can be reassigned/overlaid over time, so treat this as
# a rough first signal, not a verified source. Set $PhoneLookupApiKey
# below (numlookupapi.com, Twilio Lookup, etc.) for live carrier/line-
# type data instead of just a rough region guess.
$PhoneLookupApiKey = ""     # optional - leave blank to use offline area code lookup only
$PhoneLookupApiUrl = ""     # e.g. "https://api.numlookupapi.com/v1/validate/{number}?apikey={key}"

$AreaCodeMap = @{
    '201'='NJ - Jersey City';'202'='DC - Washington';'203'='CT - Bridgeport';'205'='AL - Birmingham'
    '206'='WA - Seattle';'207'='ME - Statewide';'208'='ID - Statewide';'209'='CA - Stockton'
    '210'='TX - San Antonio';'212'='NY - Manhattan';'213'='CA - Los Angeles';'214'='TX - Dallas'
    '215'='PA - Philadelphia';'216'='OH - Cleveland';'217'='IL - Springfield';'218'='MN - Duluth'
    '219'='IN - Gary';'224'='IL - Chicago suburbs';'225'='LA - Baton Rouge';'228'='MS - Gulfport'
    '229'='GA - Albany';'231'='MI - Traverse City';'234'='OH - Akron';'239'='FL - Fort Myers'
    '240'='MD - Suburban DC';'248'='MI - Troy';'251'='AL - Mobile';'252'='NC - Rocky Mount'
    '253'='WA - Tacoma';'254'='TX - Waco';'256'='AL - Huntsville';'260'='IN - Fort Wayne'
    '262'='WI - Kenosha';'267'='PA - Philadelphia';'269'='MI - Kalamazoo';'270'='KY - Bowling Green'
    '276'='VA - Bristol';'281'='TX - Houston';'301'='MD - Suburban DC';'302'='DE - Statewide'
    '303'='CO - Denver';'304'='WV - Statewide';'305'='FL - Miami';'307'='WY - Statewide'
    '308'='NE - North Platte';'309'='IL - Peoria';'310'='CA - Los Angeles (West)';'312'='IL - Chicago'
    '313'='MI - Detroit';'314'='MO - St. Louis';'315'='NY - Syracuse';'316'='KS - Wichita'
    '317'='IN - Indianapolis';'318'='LA - Shreveport';'319'='IA - Cedar Rapids';'320'='MN - St. Cloud'
    '321'='FL - Orlando';'323'='CA - Los Angeles';'325'='TX - Abilene';'330'='OH - Akron'
    '334'='AL - Montgomery';'336'='NC - Greensboro';'337'='LA - Lafayette';'339'='MA - Boston area'
    '340'='USVI';'347'='NY - NYC boroughs';'351'='MA - Lowell';'352'='FL - Gainesville'
    '360'='WA - Vancouver';'361'='TX - Corpus Christi';'385'='UT - Salt Lake City';'386'='FL - Daytona Beach'
    '401'='RI - Statewide';'402'='NE - Omaha';'404'='GA - Atlanta';'405'='OK - Oklahoma City'
    '406'='MT - Statewide';'407'='FL - Orlando';'408'='CA - San Jose';'409'='TX - Beaumont'
    '410'='MD - Baltimore';'412'='PA - Pittsburgh';'413'='MA - Springfield';'414'='WI - Milwaukee'
    '415'='CA - San Francisco';'417'='MO - Springfield';'419'='OH - Toledo';'423'='TN - Chattanooga'
    '424'='CA - Los Angeles';'425'='WA - Bellevue';'432'='TX - Midland';'434'='VA - Lynchburg'
    '435'='UT - St. George';'440'='OH - Cleveland suburbs';'443'='MD - Baltimore';'458'='OR - Eugene'
    '469'='TX - Dallas';'470'='GA - Atlanta';'475'='CT - New Haven';'478'='GA - Macon'
    '479'='AR - Fayetteville';'480'='AZ - Scottsdale';'484'='PA - Allentown';'501'='AR - Little Rock'
    '502'='KY - Louisville';'503'='OR - Portland';'504'='LA - New Orleans';'505'='NM - Albuquerque'
    '507'='MN - Rochester';'508'='MA - Worcester';'509'='WA - Spokane';'510'='CA - Oakland'
    '512'='TX - Austin';'513'='OH - Cincinnati';'515'='IA - Des Moines';'516'='NY - Long Island'
    '517'='MI - Lansing';'518'='NY - Albany';'520'='AZ - Tucson';'530'='CA - Redding'
    '540'='VA - Roanoke';'541'='OR - Eugene';'551'='NJ - Jersey City';'559'='CA - Fresno'
    '561'='FL - West Palm Beach';'562'='CA - Long Beach';'563'='IA - Davenport';'570'='PA - Scranton'
    '571'='VA - Suburban DC';'573'='MO - Columbia';'574'='IN - South Bend';'575'='NM - Las Cruces'
    '580'='OK - Lawton';'585'='NY - Rochester';'586'='MI - Warren';'601'='MS - Jackson'
    '602'='AZ - Phoenix';'603'='NH - Statewide';'605'='SD - Statewide';'606'='KY - Ashland'
    '607'='NY - Binghamton';'608'='WI - Madison';'609'='NJ - Trenton';'610'='PA - Allentown'
    '612'='MN - Minneapolis';'614'='OH - Columbus';'615'='TN - Nashville';'616'='MI - Grand Rapids'
    '617'='MA - Boston';'618'='IL - Belleville';'619'='CA - San Diego';'620'='KS - Hutchinson'
    '623'='AZ - Phoenix (West)';'626'='CA - Pasadena';'628'='CA - San Francisco';'629'='TN - Nashville'
    '630'='IL - Naperville';'631'='NY - Suffolk County';'636'='MO - St. Charles';'641'='IA - Mason City'
    '646'='NY - Manhattan';'650'='CA - San Mateo';'651'='MN - St. Paul';'657'='CA - Anaheim'
    '660'='MO - Sedalia';'661'='CA - Bakersfield';'662'='MS - Tupelo';'667'='MD - Baltimore'
    '669'='CA - San Jose';'678'='GA - Atlanta';'682'='TX - Fort Worth';'701'='ND - Statewide'
    '702'='NV - Las Vegas';'703'='VA - Suburban DC';'704'='NC - Charlotte';'706'='GA - Columbus'
    '707'='CA - Santa Rosa';'708'='IL - Cicero';'712'='IA - Sioux City';'713'='TX - Houston'
    '714'='CA - Anaheim';'715'='WI - Eau Claire';'716'='NY - Buffalo';'717'='PA - Harrisburg'
    '718'='NY - NYC boroughs';'719'='CO - Colorado Springs';'720'='CO - Denver';'724'='PA - New Castle'
    '725'='NV - Las Vegas';'727'='FL - St. Petersburg';'731'='TN - Jackson';'732'='NJ - New Brunswick'
    '734'='MI - Ann Arbor';'737'='TX - Austin';'740'='OH - Zanesville';'747'='CA - Burbank'
    '754'='FL - Fort Lauderdale';'757'='VA - Norfolk';'760'='CA - Oceanside';'762'='GA - Augusta'
    '763'='MN - Minneapolis suburbs';'765'='IN - Muncie';'770'='GA - Atlanta suburbs';'772'='FL - Port St. Lucie'
    '773'='IL - Chicago';'774'='MA - Worcester';'775'='NV - Reno';'781'='MA - Boston suburbs'
    '785'='KS - Topeka';'786'='FL - Miami';'801'='UT - Salt Lake City';'802'='VT - Statewide'
    '803'='SC - Columbia';'804'='VA - Richmond';'805'='CA - Ventura';'806'='TX - Amarillo'
    '808'='HI - Statewide';'810'='MI - Flint';'812'='IN - Evansville';'813'='FL - Tampa'
    '814'='PA - Erie';'815'='IL - Rockford';'816'='MO - Kansas City';'817'='TX - Fort Worth'
    '818'='CA - San Fernando Valley';'828'='NC - Asheville';'830'='TX - New Braunfels';'831'='CA - Salinas'
    '832'='TX - Houston';'843'='SC - Charleston';'845'='NY - Poughkeepsie';'847'='IL - Evanston'
    '848'='NJ - New Brunswick';'850'='FL - Tallahassee';'854'='SC - Charleston';'856'='NJ - Camden'
    '857'='MA - Boston';'858'='CA - San Diego';'859'='KY - Lexington';'860'='CT - Hartford'
    '862'='NJ - Newark';'863'='FL - Lakeland';'864'='SC - Greenville';'865'='TN - Knoxville'
    '870'='AR - Jonesboro';'872'='IL - Chicago';'878'='PA - Pittsburgh';'901'='TN - Memphis'
    '903'='TX - Tyler';'904'='FL - Jacksonville';'906'='MI - Upper Peninsula';'907'='AK - Statewide'
    '908'='NJ - Elizabeth';'909'='CA - San Bernardino';'910'='NC - Fayetteville';'912'='GA - Savannah'
    '913'='KS - Kansas City (KS)';'914'='NY - Westchester';'915'='TX - El Paso';'916'='CA - Sacramento'
    '917'='NY - NYC mobile';'918'='OK - Tulsa';'919'='NC - Raleigh';'920'='WI - Green Bay'
    '925'='CA - Concord';'928'='AZ - Flagstaff';'929'='NY - NYC boroughs';'930'='IN - Evansville'
    '931'='TN - Clarksville';'936'='TX - Conroe';'937'='OH - Dayton';'940'='TX - Wichita Falls'
    '941'='FL - Sarasota';'947'='MI - Troy';'949'='CA - Irvine';'951'='CA - Riverside'
    '952'='MN - Bloomington';'954'='FL - Fort Lauderdale';'956'='TX - Laredo';'959'='CT - Hartford'
    '970'='CO - Fort Collins';'971'='OR - Portland';'972'='TX - Dallas';'973'='NJ - Newark'
    '978'='MA - Lowell';'979'='TX - Bryan';'980'='NC - Charlotte';'984'='NC - Raleigh'
    '985'='LA - Houma';'989'='MI - Saginaw'
    '403'='AB - Calgary';'416'='ON - Toronto';'438'='QC - Montreal';'514'='QC - Montreal'
    '604'='BC - Vancouver';'613'='ON - Ottawa';'647'='ON - Toronto';'778'='BC - Vancouver'
    '780'='AB - Edmonton';'902'='NS/PEI - Halifax';'905'='ON - Toronto suburbs'
}

function Show-PhoneNumberInfo($PhoneNumber) {
    $digits = ($PhoneNumber -replace '[^\d]', '')
    if ($digits.Length -eq 11 -and $digits.StartsWith('1')) { $digits = $digits.Substring(1) }

    if ($PhoneLookupApiUrl -and $PhoneLookupApiKey) {
        try {
            $url = $PhoneLookupApiUrl -replace '\{number\}', $digits -replace '\{key\}', $PhoneLookupApiKey
            $r = Invoke-RestMethod -Uri $url -ErrorAction Stop
            Write-Host ($r | ConvertTo-Json -Depth 4)
            return
        } catch {
            Write-AnsiColorName "[!] " 'red' -NoNewline
            Write-Host "Live lookup failed, falling back to offline area code guess."
        }
    }

    if ($digits.Length -ge 3) {
        $areaCode = $digits.Substring(0, 3)
        if ($AreaCodeMap.ContainsKey($areaCode)) {
            Write-Host "Area code $areaCode is typically registered to: " -NoNewline
            Write-AnsiColorName $AreaCodeMap[$areaCode] 'green'
        } else {
            Write-AnsiColorName "Area code $areaCode isn't in the offline lookup table." 'gray'
        }
    } else {
        Write-AnsiColorName "Number too short to identify an area code." 'red'
    }
    Write-AnsiColorName "`nNote: area code = rough origin of the *number*, not proof of the caller's real location - spoofed caller ID is common with scam calls, so treat this as one signal, not confirmation." 'gray'
}

# ---- Place a call from a USB-connected Android phone via ADB ----
# Requires: USB debugging enabled on the phone, ADB authorized for
# this PC, and platform-tools' adb.exe reachable (set $AdbPath if it's
# not on your system PATH).
$AdbPath = "adb"

function Get-AdbDeviceSerial {
    $out = & $AdbPath devices 2>$null
    $line = $out | Select-Object -Skip 1 | Where-Object { $_ -match "\tdevice$" } | Select-Object -First 1
    if ($line) { return ($line -split "`t")[0] }
    return $null
}

# Per-call Caller ID blocking toggle (*67). This hides YOUR OWN number
# from the person you call (they see "Private"/"Blocked") - it does not
# display a different/fake number, so it's not caller ID spoofing.
$Global:CallerIdBlockEnabled = $false

function Invoke-AndroidCall {
    while ($true) {
    Clear-Host

    if (-not (Get-Command $AdbPath -ErrorAction SilentlyContinue)) {
        Write-AnsiColorName "[!] " 'red' -NoNewline
        Write-Host "adb not found. Install Android platform-tools and make sure adb.exe is on PATH (or set `$AdbPath)."
        Read-Host "Press Enter to return to the menu"
        return
    }

    $serial = Get-AdbDeviceSerial
    if (-not $serial) {
        Write-AnsiColorName "[!] " 'red' -NoNewline
        Write-Host "No authorized ADB device found. Plug in your phone, enable USB debugging, and accept the RSA prompt on the phone screen."
        Read-Host "Press Enter to return to the menu"
        return
    }

    $model = (& $AdbPath -s $serial shell getprop ro.product.model 2>$null).Trim()
    $manufacturer = (& $AdbPath -s $serial shell getprop ro.product.manufacturer 2>$null).Trim()
    $battery = (& $AdbPath -s $serial shell dumpsys battery 2>$null | Select-String "level").ToString().Trim()
    $callerIdText = if ($Global:CallerIdBlockEnabled) { "BLOCKED (*67 will be dialed)" } else { "Visible" }

    Show-Box "Call via Connected Android Phone" @(
        "Device    : $manufacturer $model",
        "Serial    : $serial",
        "Battery   : $battery",
        "Caller ID : $callerIdText"
    ) -Centered
    Write-Host ""
    Write-AnsiColorName "[" 'white' -NoNewline
    Write-AnsiColorName "+" 'green' -NoNewline
    Write-AnsiColorName "] Phone Number " 'white' -NoNewline
    Write-Host "(or T = toggle Caller ID block, B = back): " -NoNewline
    $action = Read-Host

    switch ($action.Trim().ToUpper()) {
        'T' {
            $Global:CallerIdBlockEnabled = -not $Global:CallerIdBlockEnabled
        }
        'B' { return }
        '' { }
        default {
            $number = $action.Trim()
            $dialable = ($number -replace '[^\d\+]', '')
            if ($Global:CallerIdBlockEnabled) { $dialable = "*67$dialable" }

            Write-Host ""
            Write-Host "Dialing $dialable from the connected phone..."
            & $AdbPath -s $serial shell am start -a android.intent.action.CALL -d "tel:$dialable" | Out-Null

            # Poll call state - OFFHOOK covers both "dialing" and "answered" since
            # plain adb/dumpsys doesn't reliably distinguish the two without extra
            # permissions, so treat this as "call is active", not strictly "answered".
            Write-Host "Waiting for the call to connect (up to 30s)..."
            $connected = $false
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 30) {
                $state = & $AdbPath -s $serial shell dumpsys telephony.registry 2>$null | Select-String "mCallState"
                if ($state -match '=2' -or $state -match 'OFFHOOK') { $connected = $true; break }
                Start-Sleep -Milliseconds 800
            }

            Write-Host ""
            if ($connected) {
                Write-AnsiColorName "[" 'white' -NoNewline
                Write-AnsiColorName "+" 'green' -NoNewline
                Write-AnsiColorName "] Connected`n" 'white'
                Show-PhoneNumberInfo -PhoneNumber $number
            } else {
                Write-AnsiColorName "[!] " 'red' -NoNewline
                Write-Host "Call state didn't confirm connected within 30s (may still be ringing on the phone)."
                Show-PhoneNumberInfo -PhoneNumber $number
            }
            Write-Host ""
            Read-Host "Press Enter to return to the menu"
        }
    }
    }
}

function Show-WoofingMenu {
    while ($true) {
        Clear-Host
        Show-TreeMenu "Woofing" @("(1) VPN", "(2) Phone VPN", "(3) Phone Hardware Info", "(4) Call (Android via ADB)", "(B) Back")
        $choice = Read-Host "woofing>"
        switch ($choice.Trim().ToUpper()) {
            '1' { Show-VpnMenu }
            '2' { Invoke-ExternalScript -Path $PhoneVpnScript -FriendlyName "Phone VPN" }
            '3' { Invoke-PhoneInfo }
            '4' { Invoke-AndroidCall }
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
        Show-TreeMenu "Menu" @("(1) Woofing", "(2) IP Tools", "(3) Misc", "(Q) Quit")
        Write-Host ""

        $choice = Read-Host "wxst>"
        switch ($choice.Trim().ToUpper()) {
            '1' { Show-WoofingMenu }
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
