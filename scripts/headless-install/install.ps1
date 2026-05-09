$ErrorActionPreference = 'Stop'

$stage   = 'C:\Windows\Temp\rdpwrap'
$zipPath = 'C:\Windows\Temp\RDPWrap-v1.6.2.zip'
$iniPath = 'C:\Windows\Temp\rdpwrap.ini'
$instDir = 'C:\Program Files\RDP Wrapper'

Write-Host '[*] Preparing staging dir...'
New-Item -ItemType Directory -Force $stage | Out-Null
Expand-Archive -Force $zipPath $stage
Get-ChildItem $stage -Recurse | Unblock-File

Write-Host '[*] Adding Defender exclusion...'
Add-MpPreference -ExclusionPath $instDir -ErrorAction SilentlyContinue

Write-Host '[*] Best-effort uninstall of any prior install...'
$ErrorActionPreference = 'Continue'
$null | & "$stage\RDPWInst.exe" -u 2>&1 | Out-Host
$ErrorActionPreference = 'Stop'

Write-Host '[*] Installing RDPWrap (RDPWInst.exe -i)...'
$null | & "$stage\RDPWInst.exe" -i 2>&1 | Out-Host

Write-Host '[*] Replacing bundled INI with fresh one...'
Copy-Item $iniPath (Join-Path $instDir 'rdpwrap.ini') -Force

Write-Host '[*] Restarting TermService to pick up new INI...'
Restart-Service TermService -Force

Write-Host ''
Write-Host '--- Verification ---'
$svc = Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters
Write-Host ('ServiceDll: ' + $svc.ServiceDll)
Get-Service TermService | Format-Table Name, Status, StartType -AutoSize

if ($svc.ServiceDll -notmatch 'rdpwrap\.dll$') {
    Write-Error 'ServiceDll does not point to rdpwrap.dll - install failed.'
    exit 1
}

$iniInstalled = Join-Path $instDir 'rdpwrap.ini'
if (Test-Path $iniInstalled) {
    $updated = (Select-String -Path $iniInstalled -Pattern '^Updated=' | Select-Object -First 1).Line
    Write-Host ('INI: ' + $updated)
} else {
    Write-Error 'rdpwrap.ini not found in install dir.'
    exit 1
}

Write-Host ''
Write-Host '[+] Install complete.'
