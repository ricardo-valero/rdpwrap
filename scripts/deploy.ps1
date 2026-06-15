$ErrorActionPreference = 'Stop'

$src = 'C:\Windows\Temp\rdpwrap.dll'
$dst = 'C:\Program Files\RDP Wrapper\rdpwrap.dll'
$log = 'C:\Windows\Temp\rdpwrap.txt'

if (-not (Test-Path $src)) { throw "missing source: $src" }
if (-not (Test-Path (Split-Path $dst))) { throw "rdpwrap not installed: $(Split-Path $dst)" }

Write-Host '--- stopping TermService ---'
Stop-Service TermService -Force

Remove-Item $log -ErrorAction SilentlyContinue
Copy-Item $src $dst -Force

Write-Host '--- starting TermService ---'
Start-Service TermService
Start-Sleep -Seconds 2

Get-Service TermService | Format-Table Name, Status, StartType
Write-Host "--- $log ---"
Get-Content $log -ErrorAction SilentlyContinue
