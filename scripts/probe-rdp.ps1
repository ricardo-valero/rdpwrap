$ErrorActionPreference = 'Continue'

Write-Host '--- fDenyTSConnections (must be 0) ---'
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' |
    Select-Object fDenyTSConnections | Format-List

Write-Host '--- TermService + UmRdpService ---'
Get-Service TermService, UmRdpService | Format-Table Name, Status, StartType

Write-Host '--- 3389 listener ---'
$conn = Get-NetTCPConnection -LocalPort 3389 -ErrorAction SilentlyContinue
if ($conn) {
    $conn | Format-Table LocalAddress, LocalPort, State, OwningProcess -AutoSize
    $conn | ForEach-Object {
        $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        if ($p) { Write-Host ("  pid {0} = {1}" -f $p.Id, $p.ProcessName) }
    }
} else {
    Write-Host '  NO LISTENER on 3389'
}

Write-Host '--- firewall rules: Remote Desktop ---'
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue |
    Select-Object DisplayName, Enabled, Direction, Action, Profile |
    Format-Table -AutoSize

Write-Host '--- firewall: any rule on 3389 ---'
$port_rules = Get-NetFirewallPortFilter |
    Where-Object { $_.LocalPort -eq 3389 } |
    ForEach-Object {
        $r = $_ | Get-NetFirewallRule -ErrorAction SilentlyContinue
        if ($r) { $r }
    }
if ($port_rules) {
    $port_rules | Select-Object DisplayName, Enabled, Direction, Action, Profile |
        Format-Table -AutoSize
} else {
    Write-Host '  no rules referencing port 3389'
}

Write-Host '--- last 20 lines C:\Windows\Temp\rdpwrap.txt ---'
if (Test-Path 'C:\Windows\Temp\rdpwrap.txt') {
    Get-Content 'C:\Windows\Temp\rdpwrap.txt' -Tail 20
} else {
    Write-Host '  (no log file)'
}
