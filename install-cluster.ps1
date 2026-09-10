<#
Creates the local `testable-local` kind cluster (3 nodes) and installs Calico
for NetworkPolicy enforcement.

Requires: kind, kubectl, docker (Desktop) on PATH.
#>
param(
    [string]$ClusterName = "testable-local",
    [string]$CalicoVersion = "v3.28.0"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Assert-Cmd($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name not found on PATH. Install it before running this script."
    }
}

Assert-Cmd kind
Assert-Cmd kubectl
Assert-Cmd docker

# No stderr redirect here on purpose: PowerShell 5.1 wraps a native command's
# stderr into a terminating ErrorRecord under $ErrorActionPreference = "Stop",
# and `kind get clusters` writes "No kind clusters found." to stderr as
# normal (non-error) output when the list is empty.
$existing = kind get clusters
if ($existing -contains $ClusterName) {
    Write-Host "kind cluster '$ClusterName' already exists -- skipping create."
} else {
    Write-Host "Creating kind cluster '$ClusterName'..."
    kind create cluster --name $ClusterName --config (Join-Path $here "kind-config.yaml")
}

kubectl config use-context "kind-$ClusterName"

Write-Host "Installing Calico $CalicoVersion (tigera-operator)..."
kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/$CalicoVersion/manifests/tigera-operator.yaml"
kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/$CalicoVersion/manifests/custom-resources.yaml"

Write-Host "Waiting for the calico-system namespace to appear..."
$deadline = (Get-Date).AddSeconds(120)
while (-not (kubectl get namespace calico-system --ignore-not-found -o name)) {
    if ((Get-Date) -gt $deadline) { throw "calico-system namespace did not appear within 120s" }
    Start-Sleep -Seconds 3
}

function Wait-ForTigeraStatusReady($name) {
    # `kubectl wait` errors immediately with NotFound if the resource doesn't
    # exist yet at call time -- it does not poll for creation. The operator
    # can take a while after custom-resources.yaml is created before it
    # writes these TigeraStatus objects, so wait for existence first (same
    # shape as the calico-system namespace wait above), then wait on the
    # condition. Skipping this step (as an earlier version of this script
    # did) silently proceeds even when Calico never actually came up --
    # defeating the entire reason it's installed instead of kindnet
    # (NetworkPolicy enforcement), with no visible error.
    $deadline = (Get-Date).AddSeconds(120)
    while (-not (kubectl -n calico-system get "tigerastatus/$name" --ignore-not-found -o name)) {
        if ((Get-Date) -gt $deadline) { throw "tigerastatus/$name did not appear within 120s" }
        Start-Sleep -Seconds 3
    }
    kubectl -n calico-system wait --for=condition=Available "tigerastatus/$name" --timeout=300s
    if ($LASTEXITCODE -ne 0) { throw "tigerastatus/$name did not become Available" }
}

Write-Host "Waiting for Calico to become Available (can take a couple of minutes)..."
Wait-ForTigeraStatusReady "calico"
Wait-ForTigeraStatusReady "apiserver"

Write-Host "Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

Write-Host "`nCluster is up. Context: kind-$ClusterName"
kubectl get nodes -o wide
