<#
Bring-down. Two very different things depending on intent:

  .\down.ps1               # pause: stop port-forwards, leave the cluster
                            # running (containers keep using CPU/RAM but all
                            # state is preserved -- resume with .\up.ps1,
                            # which no-ops the already-done steps)
  .\down.ps1 -Full          # full teardown: kind delete cluster. Every
                            # fixture (fabric-local.yaml) is emptyDir-backed,
                            # so this wipes ALL state (Postgres, MinIO,
                            # Temporal, RabbitMQ) with nothing left on the
                            # Windows host. Locally built Docker images stay
                            # cached independently and don't need rebuilding
                            # on the next .\up.ps1 unless the code changed.
#>
param(
    [string]$ClusterName = "testable-local",
    [switch]$Full
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "Stopping port-forwards..."
& (Join-Path $here "port-forward.ps1") -Stop

if ($Full) {
    Write-Host "`nDeleting kind cluster '$ClusterName' (full teardown)..."
    & (Join-Path $here "uninstall-cluster.ps1") -ClusterName $ClusterName
} else {
    Write-Host "`nCluster left running (pause only). Resume with .\up.ps1, or pass -Full to delete it entirely."
}
