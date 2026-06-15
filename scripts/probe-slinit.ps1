$ErrorActionPreference = 'Continue'
$ini = 'C:\Program Files\RDP Wrapper\rdpwrap.ini'

$termsrv = 'C:\Windows\System32\termsrv.dll'
$live = (Get-Item $termsrv).VersionInfo.ProductVersion
Write-Host "--- live termsrv version: $live ---"

$wantSections = @(
    "[$live]",
    "[$live-SLInit]",
    "[SLInit]"
)

$lines = Get-Content $ini
$current = $null
$buckets = @{}
foreach ($w in $wantSections) { $buckets[$w] = New-Object System.Collections.ArrayList }

foreach ($line in $lines) {
    $trim = $line.Trim()
    if ($trim.StartsWith('[') -and $trim.EndsWith(']')) {
        if ($wantSections -contains $trim) { $current = $trim }
        else { $current = $null }
        continue
    }
    if ($current -and $trim) {
        [void]$buckets[$current].Add($trim)
    }
}

foreach ($w in $wantSections) {
    Write-Host ""
    Write-Host "--- $w ($(($buckets[$w]).Count) entries) ---"
    $buckets[$w] | ForEach-Object { Write-Host "  $_" }
}
