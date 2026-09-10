<#
Sets up the persistent kubectl port-forwards used to actually access the
local stack day-to-day: identity-service, admin-console, web-console, and a
given cell's ingestion-api.

Only the last of those four actually depends on a cell existing (it lives in
the cell's own whitebox-<key> namespace) -- the other three are control-plane
chart resources, up the moment install-charts.ps1 succeeds, with no
dependency on any cell. This script forwards all three control-plane ones
unconditionally and only attempts the cell one if that cell's Service
actually exists yet, skipping it with a clear message otherwise -- so it's
safe to run right after install-charts.ps1, before any cell is created, and
safe to re-run afterward to pick the cell one up once create-cell.ps1 has
run.

kubectl port-forward targets a specific pod IP, not the Service -- it dies
every time that pod restarts (which happens a lot while iterating on charts).
This script always kills any of its own previous forwards first, so it's
always safe to just re-run after a restart instead of hunting down stale
processes by hand.

Usage:
  .\port-forward.ps1                 # (re)start everything that exists yet
  .\port-forward.ps1 -CellKey cell-002
  .\port-forward.ps1 -Stop           # just kill them, don't restart
#>
param(
    [string]$CellKey = "cell-001",
    [string]$ControlPlaneNamespace = "testable-control-plane",
    [switch]$Stop
)

$ErrorActionPreference = "Stop"

function Stop-ExistingForwards {
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'kubectl.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "port-forward" }
    foreach ($p in $procs) {
        Write-Host "  stopping pid $($p.ProcessId): $($p.CommandLine)"
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Stopping any existing port-forwards started by this script..."
Stop-ExistingForwards

if ($Stop) {
    Write-Host "Done (stop-only)."
    return
}

function Start-Forward($ns, $svc, $localPort, $remotePort) {
    Write-Host "  svc/$svc ($ns): localhost:$localPort -> $remotePort"
    Start-Process kubectl -ArgumentList @(
        "port-forward", "-n", $ns, "svc/$svc", "${localPort}:${remotePort}"
    ) -WindowStyle Hidden | Out-Null
}

Write-Host "`nStarting port-forwards..."
Start-Forward $ControlPlaneNamespace "identity-service" 8000 8000
Start-Forward $ControlPlaneNamespace "admin-console" 3001 3000
Start-Forward $ControlPlaneNamespace "web-console" 3002 3000

$cellNs = "whitebox-$CellKey"
$cellSvc = "$CellKey-ingestion-api"
$cellSvcExists = kubectl -n $cellNs get svc $cellSvc --ignore-not-found -o name
if ($cellSvcExists) {
    Start-Forward $cellNs $cellSvc 8001 8001
    $cellForwarded = $true
} else {
    Write-Host "  svc/$cellSvc ($cellNs): doesn't exist yet -- skipping (run .\create-cell.ps1, then re-run this script)"
    $cellForwarded = $false
}

Start-Sleep -Seconds 2
Write-Host "`nUp:"
Write-Host "  Admin console:  http://localhost:3001"
Write-Host "  Web console:    http://localhost:3002"
Write-Host "  Identity API:   http://localhost:8000"
if ($cellForwarded) {
    Write-Host "  Ingestion API ($CellKey): http://localhost:8001"
}
Write-Host "`nRe-run this script any time a forward drops (e.g. after a pod restart)."
