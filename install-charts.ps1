<#
Installs the control-plane Helm chart against the local `testable-local` kind
cluster, and applies the local-only capacity RBAC that real infra applies
per-cell via an external cluster-manifest repo we don't have here.

This no longer installs a second "testable-wb" whitebox release. That was the
old manual-cell path, superseded once cell-controller could provision cells
for real -- see create-cell.ps1, which calls the actual POST /api/v1/cells
API instead. values-whitebox.kind.yaml is left in place for reference /
manual use, just not part of this automated flow.

Reads the charts from -RepoPath (default: the ai-testable-platform checkout
next to this folder) but never writes anything there -- output/state all
lives under this k8s-local folder and in the kind cluster.

Usage:
  .\install-charts.ps1 -LintOnly     # helm lint only, no cluster needed
  .\install-charts.ps1 -Render       # helm template only, no cluster needed
  .\install-charts.ps1               # real install (run install-fabric.ps1 and
                                      # build-images.ps1 first)
#>
param(
    [string]$RepoPath = (Resolve-Path (Join-Path $PSScriptRoot "..\ai-testable-platform")).Path,
    [string]$ClusterContext = "kind-testable-local",
    [string]$ControlPlaneNamespace = "testable-control-plane",
    [switch]$Render,
    [switch]$LintOnly,
    [switch]$Force,
    # Override for testing against a second, disposable cluster -- points at
    # that cluster's own build-images.ps1 -OutFile instead of the real one.
    [string]$GeneratedValuesFile = (Join-Path $PSScriptRoot "values-generated.kind.yaml")
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cpChart = Join-Path $RepoPath "deploy\control-plane\helm"

if (-not (Test-Path $cpChart)) {
    throw "Chart not found: $cpChart (pass -RepoPath if ai-testable-platform isn't at $RepoPath)"
}

Write-Host "== helm lint =="
helm lint $cpChart
if ($LintOnly) { return }

$generatedValues = $GeneratedValuesFile
$cpArgs = @(
    $cpChart,
    "-f", (Join-Path $cpChart "values.yaml"),
    "-f", (Join-Path $cpChart "values-testing.yaml"),
    "-f", (Join-Path $here "values-control-plane.kind.yaml")
)
if (Test-Path $generatedValues) {
    $cpArgs += @("-f", $generatedValues)
} else {
    Write-Host "NOTE: $generatedValues not found -- run build-images.ps1 first if this is a fresh cluster." -ForegroundColor Yellow
}

if ($Render) {
    Write-Host "`n== helm template: control-plane =="
    helm template testable-cp @cpArgs
    return
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw "kubectl not found on PATH."
}
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    throw "helm not found on PATH."
}

# Guard rail: this kubeconfig may also have real dev/staging/prod contexts in
# it. Refuse to install unless kubectl is actually pointed at the local kind
# cluster, so a stray run of this script can never touch a real cluster.
# No stderr redirect -- PS 5.1 wraps redirected native stderr (even to
# $null) into a terminating ErrorRecord under $ErrorActionPreference = "Stop"
# regardless of exit code; unredirected stderr text is just normal output.
$currentCtx = kubectl config current-context
if ($LASTEXITCODE -ne 0) { $currentCtx = "" }
$currentCtx = $currentCtx.Trim()
if ($currentCtx -ne $ClusterContext -and -not $Force) {
    throw "kubectl context is '$currentCtx', expected '$ClusterContext'. Run 'kubectl config use-context $ClusterContext' first (see install-cluster.ps1), or pass -Force if you really mean it."
}

Write-Host "`n== helm upgrade --install: control-plane (namespace $ControlPlaneNamespace) =="
helm upgrade --install testable-cp @cpArgs --namespace $ControlPlaneNamespace --create-namespace
if ($LASTEXITCODE -ne 0) {
    # Without this check, a failed install used to fall through to applying
    # RBAC and waiting on a Deployment that was never created -- confusing
    # unrelated errors instead of the real one.
    throw "helm upgrade --install failed -- see output above."
}

Write-Host "`n== applying local-only runtime-capacity RBAC =="
kubectl apply -f (Join-Path $here "runtime-capacity-rbac.yaml")

Write-Host "`nWaiting for cell-controller to be Ready..."
kubectl -n $ControlPlaneNamespace rollout status deployment/cell-controller --timeout=180s
if ($LASTEXITCODE -ne 0) { throw "cell-controller did not become Ready." }

Write-Host "`nDone."
kubectl -n $ControlPlaneNamespace get pods
Write-Host "`nNext (if not using up.ps1, which already does both):"
Write-Host "  .\port-forward.ps1     # identity-service/admin-console/web-console -- no cell needed for these"
Write-Host "  .\create-cell.ps1      # provisions cell-001 (manual, on purpose -- see up.ps1's own comment)"
