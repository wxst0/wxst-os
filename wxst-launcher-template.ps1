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
            Write-Host $l
        }
        Write-Host ""
        $menu = "----------------------------------------"
        $pad = [Math]::Max(0, [int](($width - $menu.Length) / 2))
        Write-Host (' ' * $pad) -NoNewline
        Write-Host $menu

        # ---- Add your own menu options / sections here ----
        $opts = @(
            "[Q] Quit"
        )
        foreach ($o in $opts) {
            $pad = [Math]::Max(0, [int](($width - $o.Length) / 2))
            Write-Host (' ' * $pad) -NoNewline
            Write-Host $o
        }
        Write-Host ""

        $choice = Read-Host "wxst>"
        switch ($choice.Trim().ToUpper()) {
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
