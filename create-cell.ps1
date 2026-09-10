<#
Provisions a real cell through the actual control-plane-api, exactly the way
a real dev/qa/live cell gets created: POST /api/v1/cells, then cell-controller
ticks it REQUESTED -> PROVISIONING -> VALIDATING -> READY on its own.

Does NOT bootstrap a platform-admin account -- global-migrate's own seed
(backend/database/platform_operator_seed.py) already creates
platform.admin@testable.cloud / Str0ng!PlatAdm1 on every fresh install, via
the Helm pre-upgrade hook install-charts.ps1 triggers, and it deliberately
never overwrites an existing password. This script used to call a separate
POST /v1/internal/platform-operators bootstrap step that unconditionally
RESET that password to a different hardcoded value on every single run
(upsert_platform_operator's `elif password:` branch has no "only if unset"
guard) -- so the login that actually worked kept silently drifting away from
the documented seeded one. Removed 2026-09-08 after that cost real
debugging time chasing a "wrong password" that was actually a right
password the script itself kept overwriting. Cell creation below
authenticates with the static $AdminToken bootstrap token, not this user
account, so nothing here depended on that call anyway.

No manual Helm install for the whitebox chart -- that's the point of this
script replacing the old "helm upgrade --install testable-wb" step.

Deliberately not called automatically by up.ps1: provisioning a cell is a
real, meaningful action (a namespace, a database, a whole Helm release), not
something that should happen silently as a side effect of "start the cluster."

Safe to re-run: createCell is a reuse-or-create upsert (see
backend/go-control-plane/internal/api/handlers.go's createCell), so re-running
this against an already-READY cell-001 just confirms it's still there.

Usage:
  .\create-cell.ps1
  .\create-cell.ps1 -CellKey cell-002

If the cell already exists and is FAILED (e.g. after fixing whatever broke
it), createCell alone won't re-trigger reconciliation -- it just returns any
existing non-DECOMMISSIONED cell as-is (see handlers.go's createCell reuse
logic). This script detects that and automatically calls the real
POST .../retry lifecycle action before polling.
#>
param(
    [string]$CellKey = "cell-001",
    [string]$ClusterContext = "kind-testable-local",
    [string]$ControlPlaneNamespace = "testable-control-plane",
    [string]$AdminToken = "local-placeholder-admin-bootstrap-token",
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = "Stop"

function Assert-Cmd($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name not found on PATH. Install it before running this script."
    }
}
Assert-Cmd kubectl

# No stderr redirect -- PS 5.1 wraps redirected native stderr (even to
# $null) into a terminating ErrorRecord under $ErrorActionPreference = "Stop"
# regardless of exit code; unredirected stderr text is just normal output.
$currentCtx = kubectl config current-context
if ($LASTEXITCODE -ne 0) { $currentCtx = "" }
if ($currentCtx.Trim() -ne $ClusterContext) {
    throw "kubectl context is '$($currentCtx.Trim())', expected '$ClusterContext'."
}

$cpApiLocalPort = 18021
$procs = @()

function Start-TempForward($svc, $localPort, $remotePort) {
    $p = Start-Process kubectl -ArgumentList @(
        "port-forward", "-n", $ControlPlaneNamespace, "svc/$svc", "${localPort}:${remotePort}"
    ) -PassThru -WindowStyle Hidden
    return $p
}

try {
    Write-Host "Starting temporary port-forward for bootstrap..."
    $procs += Start-TempForward "testable-control-plane-api" $cpApiLocalPort 8021
    Start-Sleep -Seconds 3

    $bearer = @{ Authorization = "Bearer $AdminToken" }

    Write-Host "`nCreating cell '$CellKey' via POST /api/v1/cells..."
    $cellBody = @{ cell_key = $CellKey; display_name = $CellKey; environment = "development" } | ConvertTo-Json
    $created = Invoke-RestMethod -Method Post -Uri "http://localhost:$cpApiLocalPort/api/v1/cells" `
        -Headers $bearer -ContentType "application/json" -Body $cellBody
    Write-Host "  status: $($created.status)"

    if ($created.status -eq "FAILED") {
        Write-Host "`nCell is FAILED -- calling POST /api/v1/cells/$CellKey/retry..."
        $created = Invoke-RestMethod -Method Post -Uri "http://localhost:$cpApiLocalPort/api/v1/cells/$CellKey/retry" -Headers $bearer
        Write-Host "  status: $($created.status)"
    }

    Write-Host "`nWaiting for cell-controller to reconcile it to READY (timeout ${TimeoutSeconds}s)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $status = $created.status
    # FAILED is terminal, not something cell-controller ever revisits on its
    # own -- Tick() only reconciles REQUESTED/PROVISIONING/VALIDATING/
    # DECOMMISSIONING. Without this check, a genuine failure used to just sit
    # here polling the same status until the full timeout instead of
    # reporting the real problem immediately.
    while ($status -ne "READY" -and $status -ne "FAILED" -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $cell = Invoke-RestMethod -Method Get -Uri "http://localhost:$cpApiLocalPort/api/v1/cells/$CellKey" -Headers $bearer
        $status = $cell.status
        Write-Host "  $(Get-Date -Format 'HH:mm:ss')  status: $status"
    }

    if ($status -eq "FAILED") {
        throw "Cell '$CellKey' reached FAILED. Check: kubectl -n $ControlPlaneNamespace logs deployment/cell-controller -- then POST /api/v1/cells/$CellKey/retry once fixed."
    }
    if ($status -ne "READY") {
        throw "Cell '$CellKey' did not reach READY within ${TimeoutSeconds}s (last status: $status). Check: kubectl -n $ControlPlaneNamespace logs deployment/cell-controller"
    }

    Write-Host "`nCell '$CellKey' is READY." -ForegroundColor Green
    Write-Host "Runtime images (BuildKit) publish themselves automatically from here -- this takes a"
    Write-Host "while on a fresh cell. Watch progress with:"
    Write-Host "  kubectl -n whitebox-$CellKey get pods -l app.kubernetes.io/name=runtime-reconciler -w"
    Write-Host "`nAdmin-console login: platform.admin@testable.cloud / Str0ng!PlatAdm1 (the migration seed -- see this script's header comment)"
    Write-Host "Next: .\port-forward.ps1  (sets up the persistent port-forwards for actual use)"
} finally {
    foreach ($p in $procs) {
        if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
}
