<#
Deletes the local `testable-local` kind cluster. Safe to re-run;
no-ops if the cluster doesn't exist.
#>
param(
    [string]$ClusterName = "testable-local"
)

$ErrorActionPreference = "Stop"

# See install-cluster.ps1 for why this has no stderr redirect.
$existing = kind get clusters
if ($existing -contains $ClusterName) {
    kind delete cluster --name $ClusterName
    Write-Host "Deleted kind cluster '$ClusterName'."
} else {
    Write-Host "No kind cluster named '$ClusterName' found."
}
