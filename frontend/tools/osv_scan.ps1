# osv.dev batch vulnerability query for the Wholesale POS dependency set.
$ErrorActionPreference = 'Stop'
$lockPath = 'c:\Users\www\wholesale_pos\app\pubspec.lock'
$lines = Get-Content $lockPath

# Parse the lockfile: package blocks look like "  name:\n    version: x.y.z"
$pkgs = @()
$current = $null
foreach ($line in $lines) {
  if ($line -match '^  ([a-z0-9_]+):\s*$') { $current = $Matches[1] }
  elseif ($line -match '^\s+version:\s*\"?([0-9][^\"\\s]*)\"?' -and $current) {
    $pkgs += [pscustomobject]@{ name = $current; version = $Matches[1] }
    $current = $null
  }
}
"locked packages: $($pkgs.Count)"

# Batch queries (<=100 per call) against Pub ecosystem.
$batch = @(); $findings = @()
foreach ($p in ($pkgs | Sort-Object name -Unique)) {
  $batch += ,@{ package = @{ name = $p.name; ecosystem = 'Pub' }; version = $p.version }
  if ($batch.Count -ge 100) {
    $body = @{ queries = $batch } | ConvertTo-Json -Depth 6 -Compress
    $r = Invoke-RestMethod -Method POST -Uri 'https://api.osv.dev/v1/querybatch' -Body $body -ContentType 'application/json'
    foreach ($res in $r.results) { if ($res.osv) { $findings += $res.osv } }
    $batch = @()
  }
}
if ($batch.Count -gt 0) {
  $body = @{ queries = $batch } | ConvertTo-Json -Depth 6 -Compress
  $r = Invoke-RestMethod -Method POST -Uri 'https://api.osv.dev/v1/querybatch' -Body $body -ContentType 'application/json'
  foreach ($res in $r.results) { if ($res.osv) { $findings += $res.osv } }
}

"--- Pub ecosystem OSV hits: $($findings.Count) ---"
foreach ($f in $findings) {
  "OSV: $f  (get details via https://api.osv.dev/v1/vulns/<id>)"
}

# Edge function pinned deps (npm ecosystem) — query individually for detail.
foreach ($np in @(
  @{ name='@noble/curves'; version='1.4.0' },
  @{ name='@supabase/supabase-js'; version='2.39.0' }
)) {
  $body = @{ package = @{ name = $np.name; ecosystem = 'npm' }; version = $np.version } | ConvertTo-Json
  $r = Invoke-RestMethod -Method POST -Uri 'https://api.osv.dev/v1/query' -Body $body -ContentType 'application/json'
  if ($r.vulns) {
    "--- npm $($np.name)@$($np.version): $($r.vulns.Count) known vulns ---"
    foreach ($v in $r.vulns) { "$($v.id) severity=$($v.database_specific.severity) summary=$($v.summary)" }
  } else {
    "--- npm $($np.name)@$($np.version): clean ---"
  }
}
