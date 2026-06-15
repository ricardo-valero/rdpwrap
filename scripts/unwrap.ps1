$ErrorActionPreference = 'Stop'
$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters'

Write-Host "--- current ServiceDll ---"
(Get-ItemProperty -Path $key).ServiceDll

Write-Host "--- stopping TermService ---"
Stop-Service TermService -Force

Write-Host "--- pointing ServiceDll at System32\termsrv.dll ---"
Set-ItemProperty -Path $key -Name ServiceDll `
    -Value 'C:\Windows\System32\termsrv.dll' -Type ExpandString

Write-Host "--- starting TermService ---"
Start-Service TermService
Start-Sleep -Seconds 2
Get-Service TermService | Format-Table Name, Status

Write-Host "--- 3389 listener ---"
$conn = Get-NetTCPConnection -LocalPort 3389 -ErrorAction SilentlyContinue
if ($conn) {
    $conn | Format-Table LocalAddress, LocalPort, State, OwningProcess -AutoSize
} else {
    Write-Host '  NO LISTENER on 3389'
}
