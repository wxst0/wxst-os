# Repairs the USB's EFI System Partition after Rufus reported "Failed to enable boot".
# Rufus ran: bcdboot E:\Windows /v /offline /f ALL /s F:  -> failed.
# This retries with /f UEFI, which matches the GPT + protective-MBR layout Rufus created.
# Default is a read-only plan; -Apply writes boot files. Only the verified USB ESP is touched.
[CmdletBinding()]
param(
    [ValidatePattern('^[D-Zd-z]$')][string]$WindowsDriveLetter = 'E',
    [string]$ExpectedDiskUniqueId = 'USBSTOR\DISK&VEN_GENERAL&PROD_USB_FLASH_DISK&REV_1100\0301300000000778&0:DESKTOP-22BSG6H',
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated Windows PowerShell. bcdboot and ESP mounting both require administrator.'
}

$root = $WindowsDriveLetter.ToUpperInvariant() + ':\'
if ($root.TrimEnd('\') -eq $env:SystemDrive) { throw 'The target is the running Windows installation.' }

$windowsPartition = Get-Partition -DriveLetter $WindowsDriveLetter -ErrorAction Stop
$disk = $windowsPartition | Get-Disk -ErrorAction Stop
if ($disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem) { throw 'Target must be a USB disk that is not the boot or system disk.' }
if ($disk.UniqueId -ne $ExpectedDiskUniqueId) { throw ('Disk UniqueId does not match the confirmed USB. Found: ' + $disk.UniqueId) }
if (-not (Test-Path -LiteralPath (Join-Path $root 'Windows\System32\config\SOFTWARE'))) { throw 'No offline Windows installation was found on the target.' }

$espType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$esp = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.GptType -eq $espType })
if ($esp.Count -ne 1) { throw ('Expected exactly one EFI System Partition on disk ' + $disk.Number + '; found ' + $esp.Count + '.') }
$esp = $esp[0]

# Refuse outright if that ESP lives on a boot or system disk.
$protected = @(Get-Disk | Where-Object { $_.IsSystem -or $_.IsBoot } | Select-Object -ExpandProperty Number)
if ($protected -contains $esp.DiskNumber) { throw 'Refusing: the selected ESP is on the system or boot disk.' }

Write-Output ('Target Windows : ' + $root)
Write-Output ('Target disk    : ' + $disk.FriendlyName + ' (disk ' + $disk.Number + ', ' + $disk.Size + ' bytes)')
Write-Output ('Target ESP     : disk ' + $esp.DiskNumber + ' partition ' + $esp.PartitionNumber + ', ' + [math]::Round($esp.Size / 1MB) + ' MB')
Write-Output ('Command        : bcdboot ' + (Join-Path $root 'Windows') + ' /s <esp> /f UEFI /v')
if (-not $Apply) { Write-Output ''; Write-Output 'Plan only. Nothing was written. Re-run with -Apply to write the boot files.'; return }

$used = @(Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -ExpandProperty DriveLetter)
$letter = @('S','T','U','V','W','Y','Z' | Where-Object { $used -notcontains $_ }) | Select-Object -First 1
if (-not $letter) { throw 'No free drive letter is available to mount the ESP.' }
$mount = $letter + ':'

Add-PartitionAccessPath -DiskNumber $esp.DiskNumber -PartitionNumber $esp.PartitionNumber -AccessPath $mount -ErrorAction Stop
try {
    Write-Output ''
    Write-Output ('--- bcdboot (ESP mounted at ' + $mount + ') ---')
    & bcdboot.exe (Join-Path $root 'Windows') /s $mount /f UEFI /v
    $code = $LASTEXITCODE
    Write-Output ('bcdboot exit code: ' + $code)

    Write-Output ''
    Write-Output '--- resulting ESP contents ---'
    foreach ($relative in 'EFI\Microsoft\Boot\BCD', 'EFI\Microsoft\Boot\bootmgfw.efi', 'EFI\Boot\bootx64.efi') {
        $full = Join-Path $mount $relative
        if (Test-Path -LiteralPath $full) {
            Write-Output ('{0,-38} present ({1} bytes)' -f $relative, (Get-Item -LiteralPath $full).Length)
        } else {
            Write-Output ('{0,-38} MISSING' -f $relative)
        }
    }

    if ($code -eq 0) {
        Write-Output ''
        Write-Output 'Boot files written. Next: run Customize-Offline.ps1, then test boot on the target laptop.'
    } else {
        Write-Output ''
        Write-Output 'bcdboot still failed. Capture the verbose output above before retrying the Rufus write.'
    }
} finally {
    Remove-PartitionAccessPath -DiskNumber $esp.DiskNumber -PartitionNumber $esp.PartitionNumber -AccessPath $mount -ErrorAction SilentlyContinue
}
