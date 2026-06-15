$ErrorActionPreference = 'Stop'

Write-Host '--- existing rules referencing port 3389 (before) ---'
$existing = Get-NetFirewallPortFilter |
    Where-Object { $_.LocalPort -eq '3389' -or $_.LocalPort -eq 3389 } |
    ForEach-Object {
        $r = $_ | Get-NetFirewallRule -ErrorAction SilentlyContinue
        if ($r) { $r }
    }
$existing | Select-Object DisplayName, Enabled, Direction, Action | Format-Table -AutoSize

Write-Host '--- removing them ---'
foreach ($rule in $existing) {
    Write-Host ("  removing: {0}" -f $rule.DisplayName)
    Remove-NetFirewallRule -Name $rule.Name -ErrorAction Continue
}

# Belt-and-suspenders: also strip the named built-in / manual entries by
# DisplayName in case any didn't surface through the port filter.
foreach ($name in @('RDP Port 3389', 'Remote Desktop')) {
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Host ("  removing by name: {0}" -f $_.DisplayName)
            Remove-NetFirewallRule -Name $_.Name -ErrorAction Continue
        }
}

Write-Host '--- adding canonical rule rdpwrap-3389 ---'
New-NetFirewallRule `
    -DisplayName 'rdpwrap-3389' `
    -Description 'RDP listener (managed by rdpwrap-cli)' `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 3389 `
    -Action Allow `
    -Profile Any `
    -Enabled True |
    Format-Table DisplayName, Enabled, Direction, Action, Profile -AutoSize

Write-Host '--- final state ---'
Get-NetFirewallPortFilter |
    Where-Object { $_.LocalPort -eq '3389' -or $_.LocalPort -eq 3389 } |
    ForEach-Object { $_ | Get-NetFirewallRule -ErrorAction SilentlyContinue } |
    Select-Object DisplayName, Enabled, Direction, Action | Format-Table -AutoSize
