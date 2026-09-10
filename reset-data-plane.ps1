<#
Resets every stateful store on the local kind cluster and rebuilds a fresh
platform in place -- the local counterpart of
infra/cluster-manifest/{dev,pilot,qa}/reset-data-plane.sh, built for
k8s-local's actual architecture. That script targets dev-eks specifically
(hard-aborts unless the kube context contains "dev-eks") and everything it
touches -- RDS, CNPG, Strimzi Kafka, ArgoCD-managed apps, real ECR images --
simply doesn't exist here. It is not reusable against this cluster even by
accident.

Locally, every fixture in fabric-local.yaml (global-postgres, cell-postgres,
temporal-postgres, temporal, kafka, rabbitmq, valkey, minio, oci-registry) is
a bare Pod backed by emptyDir (see that file's own header comment) -- so
"delete the Pod" IS the wipe, with no per-database DROP/CREATE dance needed.
That's simpler than the dev script, not a lesser version of it: dev-eks's
CNPG-managed Postgres is a real HA cluster you can't just Pod-delete, so it
resorts to SQL; a single throwaway local Pod doesn't have that constraint.

DESTROYS: testable_global (tenants, users, cell registry, entitlements),
          every cell_* database on cell-postgres, Temporal's postgres +
          server state, Kafka, RabbitMQ, Valkey, and every whitebox-cell-*
          namespace (Helm release + namespace) -- generalized across
          whichever cell namespaces actually exist, not hardcoded to
          cell-001, since a session may have created more than one.

KEEPS:    the kind cluster itself, and the actual pushed image *content* in
          oci-registry/minio (expensive to rebuild, same reasoning the dev
          script keeps ECR/S3 untouched). Pass -IncludeRegistry to wipe those
          Pods too and force a genuinely cold rebuild.

Unlike down.ps1 -Full, this does NOT delete the kind cluster -- it resets
data in place. build-images.ps1 ALWAYS runs (see Phase 3b below) regardless
of -IncludeRegistry -- that flag only controls whether oci-registry/minio
get wiped first. With them left alone, build-images.ps1's own build cache
means every step reports CACHED; it's still real minutes of work (~15-20,
observed 2026-09-08) pushing ~20 platform images through kind load, not the
instant no-op an earlier version of this script assumed.

Usage:
  .\reset-data-plane.ps1                   # reset everything, recreate cell-001
  .\reset-data-plane.ps1 -NoCell           # reset only, skip create-cell.ps1
  .\reset-data-plane.ps1 -IncludeRegistry  # also wipe oci-registry + minio
                                            # Pods first -- forces a genuinely
                                            # cold image rebuild, slower still
                                            # (~20-30 min on top of the above)

No interactive confirmation prompt -- matching down.ps1 -Full's convention
already established in this repo: the explicit flag/invocation IS the
confirmation, not a typed phrase (that's dev's script's pattern, appropriate
there because dev-eks is real shared infrastructure; this is a disposable
local sandbox). What this script does NOT relax is the context guard: unlike
install-charts.ps1's -Force escape hatch, there is deliberately no bypass
here -- a wrong-context run of a data-wipe script has no legitimate use case
worth the risk.
#>
param(
    [string]$ClusterName = "testable-local",
    [string]$ClusterContext = "kind-testable-local",
    [switch]$IncludeRegistry,
    [switch]$NoCell
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Assert-Cmd($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name not found on PATH. Install it before running this script."
    }
}
Assert-Cmd kubectl
Assert-Cmd helm

# Hard guard, no bypass -- see header comment. No stderr redirect: PS 5.1
# wraps redirected native stderr (even to $null) into a terminating
# ErrorRecord under $ErrorActionPreference = "Stop" regardless of exit code,
# a gotcha documented throughout this script suite -- unredirected stderr
# text is just normal output.
$currentCtx = kubectl config current-context
if ($LASTEXITCODE -ne 0) { $currentCtx = "" }
$currentCtx = $currentCtx.Trim()
if ($currentCtx -ne $ClusterContext) {
    throw "kubectl context is '$currentCtx', expected '$ClusterContext'. This script wipes data -- refusing to run against any other context, no override."
}

Write-Host "Resetting local data plane (context: $currentCtx)..." -ForegroundColor Yellow
if ($IncludeRegistry) {
    Write-Host "  -IncludeRegistry: oci-registry + minio will ALSO be wiped (images cold-rebuild)." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Phase 1: tear down every cell namespace
# ---------------------------------------------------------------------------
# Same two actions handleDecommission (go-control-plane/internal/k8sactuator/
# reconcile.go) takes on a real cell: uninstall its Helm release, delete its
# namespace. Generalized across every whitebox-cell-* namespace that actually
# exists rather than one hardcoded key.
Write-Host "`n== Phase 1: tear down cell namespaces =="
$cellNamespaces = kubectl get ns -o name |
    Where-Object { $_ -match '^namespace/whitebox-cell-' } |
    ForEach-Object { $_ -replace '^namespace/', '' }

if (-not $cellNamespaces) {
    Write-Host "  none found"
} else {
    foreach ($ns in $cellNamespaces) {
        Write-Host "  $ns"
        $releases = helm list -n $ns -q
        foreach ($r in $releases) {
            helm uninstall $r -n $ns | Out-Null
        }
        kubectl delete ns $ns --wait=false --ignore-not-found | Out-Null
    }
    foreach ($ns in $cellNamespaces) {
        Write-Host "  waiting for $ns to terminate..."
        $deadline = (Get-Date).AddSeconds(180)
        while ((kubectl get ns $ns --ignore-not-found -o name) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
        }
        if (kubectl get ns $ns --ignore-not-found -o name) {
            throw "$ns did not finish terminating within 180s -- check for stuck finalizers."
        }
    }
}

# ---------------------------------------------------------------------------
# Phase 2: wipe stateful fabric pods
# ---------------------------------------------------------------------------
# Every fixture in fabric-local.yaml is emptyDir-backed -- deleting the Pod
# IS the wipe. Service objects (and their ClusterIPs) are untouched, so
# nothing downstream needs to learn a new address.
Write-Host "`n== Phase 2: wipe stateful fabric pods =="
$podsToWipe = @(
    @{ Ns = "testable-control-plane";  Pod = "global-postgres" },
    @{ Ns = "testable-whitebox-local"; Pod = "cell-postgres" },
    @{ Ns = "testable-whitebox-local"; Pod = "temporal-postgres" },
    @{ Ns = "testable-whitebox-local"; Pod = "temporal" },
    @{ Ns = "testable-whitebox-local"; Pod = "kafka" },
    @{ Ns = "testable-whitebox-local"; Pod = "rabbitmq" },
    @{ Ns = "default";                 Pod = "valkey" }
)
if ($IncludeRegistry) {
    $podsToWipe += @{ Ns = "testable-whitebox-local"; Pod = "oci-registry" }
    $podsToWipe += @{ Ns = "testable-whitebox-local"; Pod = "minio" }
}
foreach ($p in $podsToWipe) {
    Write-Host "  $($p.Ns)/$($p.Pod)"
    kubectl -n $p.Ns delete pod $p.Pod --ignore-not-found --wait=true --timeout=60s | Out-Null
}

# ---------------------------------------------------------------------------
# Phase 3: recreate fabric fixtures
# ---------------------------------------------------------------------------
# Re-running install-fabric.ps1 is deliberate reuse, not duplication: it
# already does exactly what's needed here -- kubectl apply (recreates every
# deleted Pod; a no-op for ones left alone), waits for Ready, re-creates the
# 'testable' NOLOGIN role global-migrate requires, and re-resolves +
# re-saves oci-registry's ClusterIP (unchanged unless -IncludeRegistry, since
# only the Service -- not the Pod -- determines it, but re-saving is
# harmless and avoids duplicating that logic here).
Write-Host "`n== Phase 3: recreate fabric fixtures =="
& (Join-Path $here "install-fabric.ps1") -ClusterName $ClusterName

# ---------------------------------------------------------------------------
# Phase 3b: build-images.ps1 -- always, not just when -IncludeRegistry
# ---------------------------------------------------------------------------
# This is NOT an optimization skipped by default -- it's required for
# correctness every time. build-images.ps1 is the only thing that writes
# values-generated.kind.yaml, and that file carries more than oci-registry
# content: cellController.migrateImage and every CELL_IMAGE_* digest
# cell-controller needs to install the whitebox chart for a cell. A stale
# copy of that file (e.g. from before migrateImage support existed) breaks
# brand-new cell creation with "cellMigrate.image.digest or tag is required"
# -- confirmed live on 2026-09-08: skipping this step here left cell-001
# stuck FAILED every single time, since a truly fresh cell (as opposed to
# the DB-status-flip "soft reset" elsewhere in this suite) is the one path
# that actually exercises whatever that file is missing.
#
# With Docker's build cache warm and -IncludeRegistry NOT wiping
# oci-registry, every build step here hits cache (`docker build` reports
# CACHED on nearly every layer) -- this is a re-tag-and-verify pass, not a
# cold rebuild, though it still takes real time to push everything through
# `kind load` / `ctr images import` for ~20 platform images (observed
# ~15-20 minutes end to end on 2026-09-08, not the 20-30 minute *cold*
# rebuild that only -IncludeRegistry's wiped oci-registry would force).
Write-Host "`n== Phase 3b: build-images.ps1 (keeps values-generated.kind.yaml correct) =="
& (Join-Path $here "build-images.ps1") -ClusterName $ClusterName

# ---------------------------------------------------------------------------
# Phase 4: reinstall the control-plane chart
# ---------------------------------------------------------------------------
# helm upgrade --install re-fires global-migrate (a pre-upgrade hook) against
# the now-empty testable_global database, rebuilding its schema from scratch.
Write-Host "`n== Phase 4: reinstall control-plane chart =="
& (Join-Path $here "install-charts.ps1")

# Existing control-plane pods held connections to the OLD global-postgres pod
# IP (the Service ClusterIP didn't change, but the TCP connection did) --
# restart them so they reconnect against the freshly-migrated schema instead
# of relying on each client's own retry/backoff to notice the reset.
#
# cell-controller is deliberately EXCLUDED here -- Phase 4's helm upgrade
# already rolled it out fresh moments ago (a real chart release, not a no-op),
# so it already holds a live connection against the freshly-migrated schema.
# Restarting it again is not just redundant: cell-controller takes a
# singleton DB-backed advisory lock (cell_controller_k8s_singleton) so only
# one instance ever runs Tick() at a time. A second forced restart here spins
# up a new pod that can never acquire that lock while the still-healthy pod
# from Phase 4 holds it, so it crash-loops forever on "fence already held"
# and the rollout deadlocks -- confirmed live on 2026-09-08, recovered with
# `kubectl rollout undo deployment/cell-controller`.
Write-Host "`n== Phase 4b: restart control-plane pods (fresh DB connections) =="
$cpDeployments = @("identity-service", "testable-control-plane-api", "testable-control-plane-admission")
foreach ($d in $cpDeployments) {
    kubectl -n testable-control-plane rollout restart deployment/$d | Out-Null
}
foreach ($d in $cpDeployments) {
    kubectl -n testable-control-plane rollout status deployment/$d --timeout=120s
    if ($LASTEXITCODE -ne 0) { throw "$d did not come back Ready after restart." }
}

# ---------------------------------------------------------------------------
# Phase 5: recreate the default cell
# ---------------------------------------------------------------------------
if (-not $NoCell) {
    Write-Host "`n== Phase 5: recreate cell-001 =="
    & (Join-Path $here "create-cell.ps1")
} else {
    Write-Host "`n== Phase 5: SKIPPED (-NoCell) =="
}

Write-Host "`n== Phase 6: port-forwards =="
& (Join-Path $here "port-forward.ps1")

Write-Host "`nDone -- local data plane reset." -ForegroundColor Green
if ($NoCell) {
    Write-Host "No cell exists yet -- run .\create-cell.ps1 when ready."
}
