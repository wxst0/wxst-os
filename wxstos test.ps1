#requires -Version 5.1
# ============================== CONFIG ==============================
$ApiBase         = "https://wxst-licenses.taxhriley.workers.dev/"
$ApiBase         = $ApiBase.TrimEnd('/')  
$AppName         = "Wxst OS"
$LicenseDir      = Join-Path $env:LOCALAPPDATA "WxstTools"
$LicenseFile     = Join-Path $LicenseDir "license.dat"
$MinAuthSeconds  = 5

# Define your supported games here:
$SupportedGames = @{
    "Game One Example" = @{ Exe = "game1.exe"; Dll = "C:\WxstTools\dlls\game1_mod.dll" }
    "Game Two Example" = @{ Exe = "game2.exe"; Dll = "C:\WxstTools\dlls\game2_mod.dll" }
}

# ============================ ANSI / COLOR ===========================
Add-Type -Name Win32 -Namespace Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool GetStdHandle_dummy();
[DllImport("kernel32.dll", SetLastError = true)] public static extern System.IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);

[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint processAccess, bool bInheritHandle, int processId);
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, uint dwSize, uint flAllocationType, uint flProtect);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpAddress, byte[] lpBuffer, uint nSize, out int lpNumberOfBytesWritten);
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetModuleHandle(string lpModuleName);
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr CreateRemoteThread(IntPtr hProcess, IntPtr lpThreadAttributes, uint dwStackSize, IntPtr lpStartAddress, IntPtr lpParameter, uint dwCreationFlags, out IntPtr lpThreadId);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr hObject);
'@ -ErrorAction SilentlyContinue

try {
    $stdOut = [Console.Win32]::GetStdHandle(-11)
    $mode = 0
    [Console.Win32]::GetConsoleMode($stdOut, [ref]$mode) | Out-Null
    [Console.Win32]::SetConsoleMode($stdOut, $mode -bor 0x0004) | Out-Null
} catch {}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Esc = [char]27
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
$TreeGradient = @(
    @{R=90;  G=5;  B=5}, @{R=120; G=8;  B=8}, @{R=150; G=12; B=12},
    @{R=180; G=18; B=18}, @{R=210; G=25; B=25}, @{R=255; G=40; B=40}
)
function Get-TreeColor($Index, $Total) {
    if ($Total -le 1) { return $TreeGradient[-1] }
    $pos = $Index / [Math]::Max(1, ($Total - 1))
    $i = [int][Math]::Floor($pos * ($TreeGradient.Count - 1))
    return $TreeGradient[$i]
}

function Show-TreeMenu($Title, [string[]]$Lines, [switch]$Centered) {
    $consoleWidth = try { [Console]::WindowWidth } catch { 120 }
    $longest = 0
    foreach ($l in $Lines) { if (('╠═' + $l).Length -gt $longest) { $longest = ('╠═' + $l).Length } }
    $leftPad = if ($Centered) { [Math]::Max(0, [int](($consoleWidth - $longest) / 2)) } else { 0 }
    if ($Title) { Write-Host (' ' * $leftPad) -NoNewline; Write-AnsiColorName "$Title`n" 'white' }
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
$GradientStops = @(
    @{R=60;G=0;B=0}, @{R=90;G=5;B=5}, @{R=115;G=10;B=10}, @{R=140;G=15;B=15},
    @{R=165;G=20;B=20}, @{R=190;G=25;B=25}, @{R=215;G=30;B=30}, @{R=235;G=35;B=35}, @{R=255;G=45;B=45}
)

function Show-Banner([switch]$Centered) {
    $width = try { [Console]::WindowWidth } catch { 120 }
    for ($i = 0; $i -lt $BannerLines.Count; $i++) {
        $line = $BannerLines[$i]
        $pad = if ($Centered) { [Math]::Max(0, [int](($width - $line.Length) / 2)) } else { 0 }
        $c = $GradientStops[$i]
        Write-Host (' ' * $pad) -NoNewline
        Write-Ansi $line $c.R $c.G $c.B
    }
}

function Get-HWID {
    try {
        $uuid = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID
        $cpu  = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1).ProcessorId
        $disk = (Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop | Select-Object -First 1).SerialNumber
        $raw  = "$uuid|$cpu|$disk"
    } catch {
        $raw = "$env:COMPUTERNAME|$env:PROCESSOR_IDENTIFIER|$env:USERNAME"
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
    $hex = -join ($hash | ForEach-Object { $_.ToString('X2') })
    return $hex.Substring(0, 16)
}

function Invoke-Activation($KeyString, $Hwid) {
    $keyClean = $KeyString.Trim().ToUpper()
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "$ApiBase/activate" -ContentType "application/json" -Body (@{ key = $keyClean; hwid = $Hwid } | ConvertTo-Json) -ErrorAction Stop
        return @{ Ok = $true; Label = $resp.label; ExpiresAt = $resp.expiresAt; Duration = $resp.duration }
    } catch {
        $msg = "Could not reach the license server."
        if ($_.ErrorDetails.Message) {
            try { $errObj = $_.ErrorDetails.Message | ConvertFrom-Json; if ($errObj.error) { $msg = $errObj.error } } catch {}
        }
        return @{ Ok = $false; Error = $msg }
    }
}

function Protect-Bytes($Bytes) { return [System.Security.Cryptography.ProtectedData]::Protect($Bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine) }
function Unprotect-Bytes($Bytes) { return [System.Security.Cryptography.ProtectedData]::Unprotect($Bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine) }

function Save-LicenseCache($Hwid, $FullKey, $Label, $ExpiresAt) {
    New-Item -ItemType Directory -Path $LicenseDir -Force | Out-Null
    $obj = [PSCustomObject]@{ Hwid = $Hwid; Key = $FullKey.Trim().ToUpper(); Label = $Label; ExpiryUtc = $ExpiresAt }
    $json = $obj | ConvertTo-Json -Compress
    [IO.File]::WriteAllBytes($LicenseFile, (Protect-Bytes [System.Text.Encoding]::UTF8.GetBytes($json)))
}

function Read-LicenseCache {
    if (-not (Test-Path $LicenseFile)) { return $null }
    try { return [System.Text.Encoding]::UTF8.GetString((Unprotect-Bytes [IO.File]::ReadAllBytes($LicenseFile))) | ConvertFrom-Json } catch { return $null }
}

function Mask-Key($KeyString) {
    $k = $KeyString.Trim()
    if ($k.Length -le 10) { return $k }
    return "$($k.Substring(0,9))****$($k.Substring($k.Length-4))"
}

function Show-HeaderScreen {
    Clear-Host; Show-Banner; Write-Host ""
    Write-AnsiColorName "PC Name : " 'gray'; Write-Host $env:COMPUTERNAME
    Write-AnsiColorName "Account : " 'gray'; Write-Host $env:USERNAME
    Write-AnsiColorName "OS      : " 'gray'; Write-Host ((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)
    Write-AnsiColorName "HWID    : " 'gray'; Write-AnsiColorName (Get-HWID) 'white'
    Write-Host "`n`n`n`n"
    return (Get-HWID)
}

function Invoke-KeyPrompt($Hwid) {
    while ($true) {
        Write-AnsiColorName "[" 'white' -NoNewline; Write-AnsiColorName "+" 'green' -NoNewline; Write-AnsiColorName "] key: " 'white' -NoNewline
        $inputKey = Read-Host
        $job = Start-Job -ScriptBlock {
            param($api, $k, $h)
            try {
                $r = Invoke-RestMethod -Method Post -Uri "$api/activate" -ContentType "application/json" -Body (@{ key = $k; hwid = $h } | ConvertTo-Json) -ErrorAction Stop
                return @{ Ok = $true; Label = $r.label; ExpiresAt = $r.expiresAt }
            } catch { return @{ Ok = $false; Error = "Activation failed." } }
        } -ArgumentList $ApiBase, $inputKey, $Hwid

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $toggle = $true
        while ($sw.Elapsed.TotalSeconds -lt $MinAuthSeconds -or $job.State -eq 'Running') {
            $sym = if ($toggle) { '*' } else { '+' }
            Write-Host "`r" -NoNewline; Write-AnsiColorName "[" 'white' -NoNewline; Write-Ansi $sym 220 0 0 -NoNewline; Write-AnsiColorName "] authorizing" 'white' -NoNewline
            Write-Host ("." * (1 + ([int]($sw.Elapsed.TotalSeconds * 2) % 3))) -NoNewline
            Start-Sleep -Milliseconds 250
            $toggle = -not $toggle
        }
        $result = Receive-Job -Job $job -Wait; Remove-Job -Job $job -Force
        if (-not $result.Ok) { Write-AnsiColorName "`n[!] Verification Error`n" 'red'; continue }
        Save-LicenseCache -Hwid $Hwid -FullKey $inputKey -Label $result.Label -ExpiresAt $result.ExpiresAt
        return @{ Label = $result.Label; ExpiresAt = $result.ExpiresAt; MaskedKey = Mask-Key $inputKey }
    }
}

function Get-TimeLeftText($ExpiryUtcString) {
    if ($ExpiryUtcString -eq 'LIFETIME') { return "Lifetime" }
    try {
        $rem = [DateTime]::Parse($ExpiryUtcString, $null, [Globalization.DateTimeStyles]::RoundtripKind) - [DateTime]::UtcNow
        if ($rem.TotalSeconds -le 0) { return "Expired" }
        return "{0}d remaining" -f [int]$rem.TotalDays
    } catch { return "Unknown" }
}

function Invoke-GameScan {
    $ScanJob = Start-Job -ScriptBlock {
        param($TargetExes)
        $Drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' } | Select-Object -ExpandProperty Name
        $Found = @{}
        foreach ($Drive in $Drives) {
            foreach ($Path in @("$Drive", "${Drive}Program Files", "${Drive}Program Files (x86)")) {
                if (Test-Path $Path) {
                    foreach ($Exe in $TargetExes) {
                        $Match = Get-ChildItem -Path $Path -Filter $Exe -File -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($Match) { $Found[$Exe] = $Match.FullName }
                    }
                }
            }
        }
        return $Found
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($ScanJob.State -eq 'Running') {
        Write-Host "`r" -NoNewline; Write-AnsiColorName "[" 'white' -NoNewline; Write-AnsiColorName "+" 'green' -NoNewline; Write-AnsiColorName "] Searching for executables" 'white' -NoNewline
        Write-Host ("." * (1 + ([int]($sw.Elapsed.TotalSeconds * 2) % 3))) -NoNewline
        Start-Sleep -Milliseconds 250
    }
    $Results = Receive-Job -Job $ScanJob -Wait; Remove-Job -Job $ScanJob -Force
    $Installed = @()
    foreach ($Key in $SupportedGames.Keys) {
        if ($Results.ContainsKey($SupportedGames[$Key].Exe)) {
            $Installed += [PSCustomObject]@{ FriendlyName = $Key; ExeName = $SupportedGames[$Key].Exe; DllPath = $SupportedGames[$Key].Dll }
        }
    }
    return $Installed
}

function Invoke-DllInjection($Pid, $DllPath) {
    $hProc = [Console.Win32]::OpenProcess(0x1F0FFF, $false, $Pid)
    if ($hProc -eq [IntPtr]::Zero) { return $false }
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("$DllPath`0")
    $pMem = [Console.Win32]::VirtualAllocEx($hProc, [IntPtr]::Zero, [uint32]$bytes.Length, 0x3000, 0x04)
    $written = 0
    [Console.Win32]::WriteProcessMemory($hProc, $pMem, $bytes, [uint32]$bytes.Length, [ref]$written) | Out-Null
    $hMod = [Console.Win32]::GetModuleHandle("kernel32.dll")
    $pLoad = [Console.Win32]::GetProcAddress($hMod, "LoadLibraryA")
    $tId = [IntPtr]::Zero
    $hThread = [Console.Win32]::CreateRemoteThread($hProc, [IntPtr]::Zero, 0, $pLoad, $pMem, 0, [ref]$tId)
    if ($hThread -eq [IntPtr]::Zero) { return $false }
    [Console.Win32]::CloseHandle($hThread) | Out-Null
    [Console.Win32]::CloseHandle($hProc) | Out-Null
    return $true
}
function Show-MainMenu($Hwid, $Label, $ExpiryUtcString, $MaskedKey) {
    $ExeList = $SupportedGames.Values | ForEach-Object { $_.Exe }
    $Detected = Invoke-GameScan -TargetExes $ExeList
    while ($true) {
        Clear-Host; Show-Banner -Centered; Write-Host ""
        $width = try { [Console]::WindowWidth } catch { 120 }
        $statusLines = @("Username: $env:USERNAME@$env:COMPUTERNAME", "License : $MaskedKey ($Label)", "Status  : $(Get-TimeLeftText $ExpiryUtcString)")
        foreach ($l in $statusLines) { Write-Host (' ' * [Math]::Max(0, [int](($width - $l.Length) / 2))) -NoNewline; Write-AnsiColorName "$l`n" 'green' }
        Write-Host ""
        $Opts = @()
        if ($Detected.Count -eq 0) { $Opts += "No supported games detected." }
        else { for ($i=0; $i -lt $Detected.Count; $i++) { $Opts += "($($i+1)) Attach to $($Detected[$i].FriendlyName)" } }
        $Opts += "(Q) Quit Launcher"
        Show-TreeMenu "Game Management Menu" $Opts
        $choice = (Read-Host "wxst>").Trim().ToUpper()
        if ($choice -eq 'Q') { exit 0 }
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -le $Detected.Count -and $idx -gt 0) {
            $Game = $Detected[$idx-1]
            $Proc = Get-Process -Name ($Game.ExeName.Replace(".exe","")) -ErrorAction SilentlyContinue
            if (-not $Proc) { Write-AnsiColorName "[!] No executable found please launch your game`n" 'red'; Read-Host "Press Enter"; continue }
            if (Invoke-DllInjection -Pid $Proc.Id -DllPath $Game.DllPath) { Write-AnsiColorName "[+] Success! The application has attached.`n" 'green' }
            Read-Host "Press Enter"
        }
    }
}
# ================================ MAIN EXECUTION ==================================
$hwid = Show-HeaderScreen
$cache = Read-LicenseCache
$needsKey = $true
if ($cache -and $cache.Hwid -eq $hwid) {
    $check = Invoke-Activation -KeyString $cache.Key -Hwid $hwid
    if ($check.Ok) { $needsKey = $false; $activeLabel = $check.Label; $activeExpiry = $check.ExpiresAt; $activeMasked = Mask-Key $cache.Key; Save-LicenseCache -Hwid $hwid -FullKey $cache.Key -Label $check.Label -ExpiresAt $check.ExpiresAt }
}
if ($needsKey) { $auth = Invoke-KeyPrompt -Hwid $hwid; Show-MainMenu -Hwid $hwid -Label $auth.Label -ExpiryUtcString $auth.ExpiresAt -MaskedKey $auth.MaskedKey }
else { Show-MainMenu -Hwid $hwid -Label $activeLabel -ExpiryUtcString $activeExpiry -MaskedKey $activeMasked }

