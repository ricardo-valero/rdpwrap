$ErrorActionPreference = 'Stop'

$instDir = 'C:\Program Files\RDP Wrapper'
$ini     = Join-Path $instDir 'rdpwrap.ini'
$tools   = 'C:\Windows\Temp\rdpwrap-offset'
$exe     = Join-Path $tools 'RDPWrapOffsetFinder.exe'
$dll     = Join-Path $tools 'Zydis.dll'

Write-Host '[*] Reading termsrv.dll version...'
$termsrv = 'C:\Windows\System32\termsrv.dll'
$ver     = (Get-Item $termsrv).VersionInfo.ProductVersion
Write-Host ('    termsrv.dll: ' + $ver)

if ((Get-Content $ini -Raw) -match ("\[" + [regex]::Escape($ver) + "\]")) {
    Write-Host "[+] INI already covers $ver. Nothing to do."
    if ((Get-Service TermService).Status -ne 'Running') {
        Start-Service TermService
    }
    exit 0
}

Write-Host "[*] Running OffsetFinder for $ver..."
New-Item -ItemType Directory -Force $tools | Out-Null
Copy-Item C:\Windows\Temp\RDPWrapOffsetFinder.exe $exe -Force
Copy-Item C:\Windows\Temp\Zydis.dll              $dll -Force
Get-ChildItem $tools | Unblock-File

$out = & $exe 2>&1
$outText = ($out | Out-String)

if ($LASTEXITCODE -ne 0 -or $outText -notmatch '\[\d') {
    Write-Host '--- OffsetFinder output ---'
    Write-Host $outText
    Write-Error "OffsetFinder did not produce expected section output"
    exit 1
}

Write-Host '[*] Stopping TermService and dependents to release INI...'
$dependents = @(Get-Service TermService -DependentServices |
                Where-Object { $_.Status -eq 'Running' } |
                Select-Object -ExpandProperty Name)
Stop-Service TermService -Force

try {
    Write-Host '[*] Appending generated section to rdpwrap.ini...'
    Add-Content -Path $ini -Value ''
    Add-Content -Path $ini -Value $out
}
finally {
    Write-Host '[*] Starting TermService...'
    Start-Service TermService
    foreach ($d in $dependents) {
        $s = Get-Service $d -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Running') {
            Start-Service $d -ErrorAction SilentlyContinue
        }
    }
}

if ((Get-Content $ini -Raw) -notmatch ("\[" + [regex]::Escape($ver) + "\]")) {
    Write-Host '--- OffsetFinder output (for diagnosis) ---'
    Write-Host $outText
    Write-Error "Section [$ver] not found in INI after append."
    exit 1
}

Write-Host ''
Write-Host '--- Verification ---'
$svc = Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters
Write-Host ('ServiceDll: ' + $svc.ServiceDll)
Get-Service TermService | Format-Table Name, Status -AutoSize
Write-Host "[+] Section [$ver] added to rdpwrap.ini"

Remove-Item $tools -Recurse -Force -ErrorAction SilentlyContinue
