$ErrorActionPreference = 'Continue'

$since = (Get-Date).AddMinutes(-10)

Write-Host '--- System log: TermService entries (last 10 min) ---'
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$since; ProviderName='Service Control Manager'} -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'TermService|Remote Desktop' } |
    Select-Object TimeCreated, LevelDisplayName, Id, Message |
    Format-List

Write-Host '--- RemoteConnectionManager/Operational (last 10 min) ---'
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational'; StartTime=$since} -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, LevelDisplayName, Id, Message |
    Format-List

Write-Host '--- RemoteConnectionManager/Admin (last 10 min) ---'
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin'; StartTime=$since} -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, LevelDisplayName, Id, Message |
    Format-List
