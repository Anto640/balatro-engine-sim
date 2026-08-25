# tools/progress.ps1 -- show progress of any running sim batch (workers + ETA).
# A parallel batch (tools/sim_par.sh) writes one shard file per worker named <batch>__p<N>.jsonl
# and DELETES them once it merges into <batch>.jsonl at the end. So: shard files present = running;
# gone = finished (a merged <batch>.jsonl exists). Scans the main repo AND sibling bes_* worktrees
# (A/B arms run from worktrees).
#
#   Snapshot:   powershell -ExecutionPolicy Bypass -File tools\progress.ps1
#   Live watch: powershell -ExecutionPolicy Bypass -File tools\progress.ps1 -Watch   (or double-click progress.bat)
#
# Workers = number of shard files. ETA: in -Watch mode it's the completion rate measured across the
# watch session (steady, and immune to Windows creation-time quirks); a one-shot snapshot falls back
# to the shard creation time and prints "(snapshot)".
param([switch]$Watch)

$expected = 160   # the n every arm this session uses; edit if you run a different size
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo  = Split-Path -Parent $here
$script:first = @{}   # name -> @{done; time} recorded the FIRST time this watch session sees the batch

function Show-Progress {
  $roots = @("$repo\sim_out")
  Get-ChildItem (Split-Path -Parent $repo) -Directory -Filter "bes_*" -ErrorAction SilentlyContinue |
    ForEach-Object { $roots += "$($_.FullName)\sim_out" }
  $any = $false
  foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    $shards = Get-ChildItem "$root\*__p*.jsonl" -ErrorAction SilentlyContinue
    if (-not $shards) { continue }
    $groups = $shards | Group-Object { ($_.Name -replace '__p\d+\.jsonl$','') }
    foreach ($g in $groups) {
      $newest = ($g.Group | Measure-Object LastWriteTime -Maximum).Maximum
      if ((New-TimeSpan -Start $newest -End (Get-Date)).TotalMinutes -gt 5) {
        "{0,-14} (stale shards, not running -- delete or merge)" -f $g.Name; continue
      }
      $workers = $g.Group.Count
      $started = 0; $done = 0
      foreach ($f in $g.Group) {
        $txt = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($txt) {
          $started += ([regex]::Matches($txt, '"kind":"run_start"')).Count
          $done    += ([regex]::Matches($txt, '"kind":"(win|death)"')).Count
        }
      }

      # ---- rate + ETA ----
      $now = Get-Date
      $rate = $null   # completed runs per minute
      if ($script:first.ContainsKey($g.Name)) {
        $fst = $script:first[$g.Name]
        $dt  = (New-TimeSpan -Start $fst.time -End $now).TotalMinutes
        if ($dt -gt 0.05 -and $done -gt $fst.done) { $rate = ($done - $fst.done) / $dt }
      } else {
        $script:first[$g.Name] = @{ done = $done; time = $now }
      }
      $snap = $false
      if (-not $rate) {
        # fallback for a one-shot snapshot: rate since the shards were created
        $start = ($g.Group | Measure-Object CreationTime -Minimum).Minimum
        $el = (New-TimeSpan -Start $start -End $now).TotalMinutes
        if ($el -gt 0.2 -and $done -gt 0) { $rate = $done / $el; $snap = $true }
      }
      $eta = "computing..."
      if ($rate -and $rate -gt 0) {
        $rem = $expected - $done
        if ($rem -le 0) { $eta = "finishing" }
        else { $eta = ("~{0} min" -f [math]::Ceiling($rem / $rate)) + $(if ($snap) { " (snapshot)" } else { "" }) }
      }

      $pct = [math]::Floor(100 * $started / $expected)
      $bar = ('#' * [math]::Floor($pct / 5)).PadRight(20)
      "{0,-14} [{1}] {2,3}/{3}  {4}w  {5,3} done  ETA {6}" -f $g.Name, $bar, $started, $expected, $workers, $done, $eta
      $any = $true
    }
  }
  if (-not $any) { "No batch running right now (no active shard files). Check sim_out\ for merged *.jsonl results." }
}

if ($Watch) {
  while ($true) {
    Clear-Host
    "sim progress -- refreshes every 15s; close the window or press Ctrl+C to stop   ($(Get-Date -Format HH:mm:ss))"
    ""
    Show-Progress
    Start-Sleep -Seconds 15
  }
} else {
  Show-Progress
}
