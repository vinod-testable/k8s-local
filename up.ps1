<#
Platform bring-up, zero to an installed control plane: cluster + Calico,
fabric fixtures, every image built/loaded/digest-resolved, and the
control-plane chart installed.

Deliberately does NOT create a cell -- that's a separate, manual step you run
yourself (.\create-cell.ps1), on purpose: it's a real, meaningful action
(provisions a namespace, a database, a whole Helm release) that shouldn't
happen silently as a side effect of "start the cluster."

Port-forwards ARE started automatically though: identity-service,
admin-console, and web-console are control-plane chart resources with no
dependency on any cell existing (up the moment install-charts.ps1 succeeds).
Only the cell's own ingestion-api forward depends on a cell -- port-forward.ps1
detects that it doesn't exist yet and skips just that one with a message;
re-run port-forward.ps1 after create-cell.ps1 to pick it up.

Equivalent to running, in order:
  install-cluster.ps1
  install-fabric.ps1
  build-images.ps1
  install-charts.ps1
  port-forward.ps1

Safe to re-run against an already-up cluster -- every step it calls is
idempotent. Use build-images.ps1 -Only <name> directly afterward for a fast
single-image rebuild loop instead of re-running the whole thing.
#>
param(
    [string]$ClusterName = "testable-local"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "`n=== 1/5: cluster + Calico ===" -ForegroundColor Cyan
& (Join-Path $here "install-cluster.ps1") -ClusterName $ClusterName

Write-Host "`n=== 2/5: fabric fixtures + registry config ===" -ForegroundColor Cyan
& (Join-Path $here "install-fabric.ps1") -ClusterName $ClusterName

Write-Host "`n=== 3/5: build + load images ===" -ForegroundColor Cyan
& (Join-Path $here "build-images.ps1") -ClusterName $ClusterName

Write-Host "`n=== 4/5: install control-plane chart ===" -ForegroundColor Cyan
& (Join-Path $here "install-charts.ps1")

Write-Host "`n=== 5/5: port-forwards ===" -ForegroundColor Cyan
& (Join-Path $here "port-forward.ps1")

Write-Host "`nPlatform is up. No cell exists yet -- next:" -ForegroundColor Green
Write-Host "  .\create-cell.ps1          # provisions cell-001 through the real API (manual, on purpose)"
Write-Host "  .\port-forward.ps1         # re-run afterward to pick up the cell's ingestion-api"
