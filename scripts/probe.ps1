$ErrorActionPreference = 'Continue'

Write-Host '--- ServiceDll registry ---'
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters' |
    Select-Object ServiceDll | Format-List

Write-Host '--- TermService PID ---'
$svc = Get-CimInstance Win32_Service -Filter "Name='TermService'"
$svc | Format-Table Name, State, ProcessId, StartName

Write-Host '--- loaded modules (rdpwrap / termsrv) ---'
if ($svc.ProcessId -gt 0) {
    Get-Process -Id $svc.ProcessId -Module -ErrorAction SilentlyContinue |
        Where-Object { $_.ModuleName -match 'rdpwrap|termsrv' } |
        Format-Table ModuleName, FileName -AutoSize
} else {
    Write-Host '  (TermService not running)'
}

Write-Host '--- rdpwrap.dll on disk ---'
$dst = 'C:\Program Files\RDP Wrapper\rdpwrap.dll'
if (Test-Path $dst) {
    Get-Item $dst | Format-Table Name, Length, LastWriteTime -AutoSize
} else {
    Write-Host "  (missing: $dst)"
}

Write-Host '--- termsrv.dll version (live) ---'
$termsrv = 'C:\Windows\System32\termsrv.dll'
if (Test-Path $termsrv) {
    (Get-Item $termsrv).VersionInfo | Format-List ProductVersion, FileVersion
} else {
    Write-Host "  (missing: $termsrv)"
}

Write-Host '--- rdpwrap.ini version sections ---'
$ini = 'C:\Program Files\RDP Wrapper\rdpwrap.ini'
if (Test-Path $ini) {
    $live = (Get-Item $termsrv).VersionInfo.ProductVersion
    Write-Host "  live termsrv version: $live"
    $sections = Select-String -Path $ini -Pattern '^\[(\d+\.\d+\.\d+\.\d+)\]' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } |
        Sort-Object -Unique
    Write-Host ("  total version sections: {0}" -f $sections.Count)
    if ($sections -contains $live) {
        Write-Host "  EXACT MATCH for $live present in INI"
    } else {
        Write-Host "  no exact match - nearest sections:"
        $sections | Select-Object -Last 10 | ForEach-Object { Write-Host "    $_" }
    }
} else {
    Write-Host "  (missing: $ini)"
}

Write-Host '--- C:\Windows\Temp\rdpwrap.txt ---'
if (Test-Path 'C:\Windows\Temp\rdpwrap.txt') {
    Get-Content 'C:\Windows\Temp\rdpwrap.txt'
} else {
    Write-Host '  (no log file)'
}
