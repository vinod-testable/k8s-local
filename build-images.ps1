<#
Builds every image the local kind cluster needs, loads it into the cluster,
and writes k8s-local/values-generated.kind.yaml -- the digest map
install-charts.ps1 layers on top of values-control-plane.kind.yaml.

Two different delivery mechanisms, matching what cell-controller's actuator
code actually requires:

  - "Chart" images (installed directly by the control-plane Helm chart:
    web-console, admin-console, identity-service, control-plane-api,
    admission-controller, cell-controller, global-migrate) just need a plain
    `:local` tag present on every node -- `kind load docker-image` is enough,
    no digest needed.

  - "Cell" images (baked by cell-controller into every cell it provisions:
    cell-migrate + every CELL_IMAGE_*) MUST be digest references
    (repo@sha256:...) -- cell-controller's Go code only ever emits a digest,
    never a floating tag (see reconcile.go / types.go). `kind load
    docker-image` still loads them, but we then read the resulting digest
    back out of each node's own containerd content store, since there's no
    real registry involved.

  - testable-runtime-reconciler is the one exception inside the "cell images"
    set: its Deployment runs with imagePullPolicy: Always (correct, real-world
    behaviour -- an ECR digest is always independently verifiable, a
    containerd-only digest alias is not), so it has to be pushed to a real
    registry for that policy to resolve it at all. Pushed via a kind node's
    own containerd (docker exec ... ctr images push --plain-http) --
    push straight from Windows Docker Desktop through a port-forward tunnel
    was tried first and unreliable ("connection refused") on this setup.

Rebuild reminder: cell-controller's own image bakes deploy/whitebox/helm into
itself at build time (COPY deploy/whitebox/helm /charts/whitebox in
Dockerfile.cell-controller) -- ANY whitebox chart template edit requires
rebuilding+reloading testable-cell-controller, not just editing the source
tree. This script always rebuilds it unless -Only excludes it.

Usage:
  .\build-images.ps1                          # build + load everything
  .\build-images.ps1 -Only cell-controller     # just one image (comma-separated for several)
  .\build-images.ps1 -SkipBuild                # re-resolve digests only (no rebuild) -- rarely needed
#>
param(
    [string]$RepoPath = (Resolve-Path (Join-Path $PSScriptRoot "..\ai-testable-platform")).Path,
    [string]$ClusterName = "testable-local",
    [string[]]$Only = @(),
    [switch]$SkipBuild,
    # Overrides for testing against a second, disposable cluster -- keeps a
    # throwaway run from clobbering the real cluster's saved registry IP /
    # digest map.
    [string]$RegistryStateFile = (Join-Path $PSScriptRoot ".oci-registry-clusterip"),
    [string]$OutFile = (Join-Path $PSScriptRoot "values-generated.kind.yaml")
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Assert-Cmd($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name not found on PATH. Install it before running this script."
    }
}
Assert-Cmd docker
Assert-Cmd kind
Assert-Cmd kubectl

if (-not (Test-Path $RegistryStateFile)) {
    throw "Missing $RegistryStateFile -- run install-fabric.ps1 first."
}
$registry = (Get-Content $RegistryStateFile -Raw).Trim()
Write-Host "Using oci-registry: $registry`n"

# -- Group 0: control-plane chart's own images, plain :local tag, no digest --
# Context defaults to repo root when unspecified. Four of these need a
# different, non-root context -- confirmed against the canonical mapping in
# scripts/eks/build-arm64-images.sh and each Dockerfile's own COPY paths:
# web-console/admin-console COPY bare `package.json` (no repo has one at
# root -- it's under frontend/<name>/), and the two Go services COPY bare
# `go.mod go.sum` (only present under backend/go-control-plane, not root).
# Using repo root for these four fails deterministically on every attempt
# with "<file>: not found" -- this was originally misdiagnosed as Docker
# Desktop/WSL2 build-context flakiness (see the retry loop in Build-Image
# below); it reproduced 3/3 retries identically, which is what prompted
# re-checking the actual context requirement instead of assuming flakiness.
$group0 = @(
    @{ Name = "testable-global-migrate";      Dockerfile = "docker/database/Dockerfile" },
    @{ Name = "testable-web-console";         Dockerfile = "docker/web-console/Dockerfile";   Context = "frontend/web-console" },
    @{ Name = "testable-admin-console";       Dockerfile = "docker/admin-console/Dockerfile"; Context = "frontend/admin-console" },
    @{ Name = "testable-identity-service";    Dockerfile = "docker/identity-service/Dockerfile" },
    @{ Name = "testable-control-plane-api";   Dockerfile = "docker/go-control-plane/Dockerfile.control-plane"; Context = "backend/go-control-plane" },
    @{ Name = "testable-admission-controller"; Dockerfile = "docker/go-control-plane/Dockerfile.admission";    Context = "backend/go-control-plane" },
    @{ Name = "testable-cell-controller";     Dockerfile = "docker/go-control-plane/Dockerfile.cell-controller" }
)

# -- Group 1: cell-controller-provisioned images, digest-pinned --
$group1 = @(
    @{ Name = "testable-cell-migrate";           Dockerfile = "docker/cell_schema/Dockerfile";       ValueKey = "migrateImage" },
    @{ Name = "testable-ingestion-api";           Dockerfile = "docker/ingestion-api/Dockerfile";       ValueKey = "CELL_IMAGE_INGESTION_API" },
    @{ Name = "testable-runtime-api";             Dockerfile = "docker/runtime-api/Dockerfile";         ValueKey = "CELL_IMAGE_RUNTIME_API" },
    @{ Name = "testable-views-api";               Dockerfile = "docker/views-api/Dockerfile";           ValueKey = "CELL_IMAGE_VIEWS_API" },
    @{ Name = "testable-wb-orchestrator";         Dockerfile = "docker/wb-orchestrator/Dockerfile";     ValueKey = "CELL_IMAGE_WB_ORCHESTRATOR" },
    @{ Name = "testable-ingestion-worker";        Dockerfile = "docker/ingestion-worker/Dockerfile";    ValueKey = "CELL_IMAGE_INGESTION_WORKER" },
    @{ Name = "testable-wb-io-worker";            Dockerfile = "docker/wb-io-worker/Dockerfile";        ValueKey = "CELL_IMAGE_WB_IO_WORKER" },
    @{ Name = "testable-wb-cpu-worker";           Dockerfile = "docker/wb-cpu-worker/Dockerfile";       ValueKey = "CELL_IMAGE_WB_CPU_WORKER" },
    @{ Name = "testable-scoring-worker";          Dockerfile = "docker/scoring-worker/Dockerfile";      ValueKey = "CELL_IMAGE_SCORING_WORKER" },
    @{ Name = "testable-projector-worker";        Dockerfile = "docker/projector-worker/Dockerfile";    ValueKey = "CELL_IMAGE_PROJECTOR_WORKER" },
    @{ Name = "testable-outbox-relay";            Dockerfile = "docker/outbox-relay/Dockerfile";        ValueKey = "CELL_IMAGE_OUTBOX_RELAY" },
    @{ Name = "testable-reconciliation-worker";   Dockerfile = "docker/reconciliation-worker/Dockerfile"; ValueKey = "CELL_IMAGE_RECONCILIATION_WORKER" }
)

# -- Group 2: pushed to the registry as a tag (imagePullPolicy: Always) --
$runtimeReconciler = @{ Name = "testable-runtime-reconciler"; Dockerfile = "docker/runtime-reconciler/Dockerfile"; ValueKey = "CELL_IMAGE_RUNTIME_RECONCILER" }

function Test-Selected($name) {
    if ($Only.Count -eq 0) { return $true }
    foreach ($o in $Only) {
        if ($name -like "*$o*") { return $true }
    }
    return $false
}

function Build-Image($img) {
    if (-not (Test-Selected $img.Name)) { return $false }
    if ($SkipBuild) { return $true }
    Write-Host "== docker build: $($img.Name) =="
    $context = if ($img.Context) { Join-Path $RepoPath $img.Context } else { $RepoPath }
    # Without an exit-code check here, a failed build used to silently fall
    # through to `kind load`, which just reloads whatever STALE image already
    # has that tag from an earlier build -- no error, no indication the image
    # running in the cluster doesn't match current source. The retry loop
    # itself is a leftover from when four of these images' consistent
    # "<file>: not found" failures were misdiagnosed as Docker Desktop/WSL2
    # build-context flakiness -- the real cause was simply the wrong build
    # context (fixed via each image's `Context` entry above, cross-checked
    # against scripts/eks/build-arm64-images.sh and each Dockerfile's own
    # COPY paths). Kept as a real safety net for genuine transient failures,
    # now that a wrong-context bug can't hide behind it silently succeeding
    # on a stale cached image.
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        docker build -t "$($img.Name):local" -f (Join-Path $RepoPath $img.Dockerfile) $context
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($attempt -lt $maxAttempts) {
            Write-Host "  build failed (attempt $attempt/$maxAttempts), retrying..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }
    throw "docker build failed for $($img.Name) after $maxAttempts attempts -- see output above."
}

function Load-Image($name) {
    Write-Host "== kind load: $name =="
    kind load docker-image "${name}:local" --name $ClusterName
    if ($LASTEXITCODE -ne 0) { throw "kind load docker-image failed for ${name}:local" }
}

function Resolve-Digest($node, $imageTag) {
    $lines = docker exec $node ctr -n k8s.io images ls | Select-String -SimpleMatch $imageTag
    foreach ($line in $lines) {
        $m = [regex]::Match($line.ToString(), 'sha256:[0-9a-f]{64}')
        if ($m.Success) { return $m.Value }
    }
    throw "Could not resolve a digest for '$imageTag' on node $node -- did kind load succeed?"
}

# `kind load docker-image` only registers the image under its :local TAG name
# in each node's containerd -- it does NOT also register it under its digest
# as its own name. containerd's CRI image lookup matches by exact reference
# STRING, not by content hash, so a pod referencing bare `name@sha256:digest`
# (no registry host -- what cell-controller's Go code always emits, and what
# every CELL_IMAGE_* value here uses) finds no local match under that name
# and falls through to a REAL network pull attempt against a repository that
# doesn't exist, failing outright with "pull access denied ... insufficient_scope"
# even though the identical content is already sitting right there under the
# :local tag. Confirmed missing here by comparing a broken pod's node against
# the working live cluster, where every image has both names registered.
# Register the digest name explicitly, on every node (a pod can land on any
# of them), pointing at the exact same content.
function Add-DigestAlias($node, $name, $digest) {
    $source = "docker.io/library/${name}:local"
    $target = "docker.io/library/${name}@${digest}"
    docker exec $node ctr -n k8s.io images tag $source $target | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to tag $target on $node" }
}

# --- Group 0 ---
foreach ($img in $group0) {
    if (-not (Test-Selected $img.Name)) { continue }
    Build-Image $img | Out-Null
    Load-Image $img.Name
}

# --- Group 1: build, load, resolve digest ---
$nodes = kind get nodes --name $ClusterName
$firstNode = $nodes[0]
$digestMap = @{}
foreach ($img in $group1) {
    if (-not (Test-Selected $img.Name)) { continue }
    Build-Image $img | Out-Null
    Load-Image $img.Name
    $digest = Resolve-Digest $firstNode "$($img.Name):local"
    Write-Host "  -> $($img.Name)@$digest"
    foreach ($node in $nodes) {
        Add-DigestAlias $node $img.Name $digest
    }
    $digestMap[$img.ValueKey] = "$($img.Name)@$digest"
}

# --- Group 2: runtime-reconciler, pushed to oci-registry as a tag ---
if (Test-Selected $runtimeReconciler.Name) {
    Write-Host "== docker build: $($runtimeReconciler.Name) (pushed to registry, not digest-aliased) =="
    if (-not $SkipBuild) {
        # BuildKit attaches an attestation manifest by default (a sibling entry
        # in the image index, not part of the plain single-platform manifest).
        # `docker save` does not reliably re-serialize that attestation's own
        # content blob, so the save -> ctr import -> ctr push roundtrip below
        # fails on "content digest ... not found" for the attestation's config
        # blob specifically -- confirmed by extracting the saved tar's
        # index.json and finding a manifest annotated
        # `vnd.docker.reference.type: attestation-manifest`. `--provenance=false`
        # / `--sbom=false` did not suppress it on this Docker install, so force
        # the classic (pre-BuildKit) builder instead -- it has no attestation
        # feature at all, so there is nothing to lose in the roundtrip. Every
        # other image in this script goes straight through `kind load
        # docker-image` instead of this save/import/push path, so only this
        # one build needs it disabled.
        $prevBuildkit = $env:DOCKER_BUILDKIT
        $env:DOCKER_BUILDKIT = "0"
        try {
            docker build -t "$($runtimeReconciler.Name):local" -f (Join-Path $RepoPath $runtimeReconciler.Dockerfile) $RepoPath
            if ($LASTEXITCODE -ne 0) { throw "docker build failed for $($runtimeReconciler.Name)" }
        } finally {
            $env:DOCKER_BUILDKIT = $prevBuildkit
        }
    }
    $tmpTar = Join-Path $env:TEMP "runtime-reconciler.tar"
    docker save "$($runtimeReconciler.Name):local" -o $tmpTar
    # `docker cp` is unreliable on this Docker Desktop + WSL2 setup -- it can
    # exit 0 without actually writing the file (see install-fabric.ps1's
    # Send-FileToNode comment for how this was confirmed). cmd.exe's `<` file
    # redirection into `docker exec -i` is byte-exact and doesn't go through
    # docker cp's code path -- verified against a full 0-255 byte range
    # including embedded NULs, so it's safe for this tar too.
    cmd /c "docker exec -i $firstNode sh -c ""cat > /tmp/runtime-reconciler.tar"" < ""$tmpTar"""
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy $tmpTar to ${firstNode}:/tmp/runtime-reconciler.tar" }
    docker exec $firstNode ctr -n k8s.io images import /tmp/runtime-reconciler.tar
    if ($LASTEXITCODE -ne 0) { throw "ctr images import failed on $firstNode" }
    Remove-Item $tmpTar -ErrorAction SilentlyContinue

    # ctr registers the imported ref under whatever name docker embedded in
    # the tar -- normally docker.io/library/<name>:local for an unqualified
    # local tag, but resolve it for real instead of assuming.
    #
    # This match used to be a bare substring (`-SimpleMatch "<name>:local"`),
    # which also matches $pushRef itself (`$registry/<name>:local`) once a
    # PRIOR run has already tagged it once -- `ctr images tag` succeeds and
    # persists even when the `push` right after it fails, so a failed run
    # leaves a stale $pushRef entry pointing at whatever broken content it
    # last tried to push. The next run's substring match could then pick that
    # stale entry over the genuinely-fresh import (ctr images ls order is not
    # guaranteed), silently re-pushing the same broken content forever no
    # matter how many times the import step itself succeeded. Matching the
    # exact unqualified name ctr actually assigns on import avoids that.
    $exactImportedName = "docker.io/library/$($runtimeReconciler.Name):local"
    $lines = docker exec $firstNode ctr -n k8s.io images ls | Select-String -SimpleMatch $exactImportedName
    $importedRef = ($lines | Where-Object { $_.ToString().Split(" ")[0] -eq $exactImportedName } | Select-Object -First 1)
    $importedRef = if ($importedRef) { $importedRef.ToString().Split(" ")[0] } else { $null }
    if (-not $importedRef) { throw "Could not find the just-imported $($runtimeReconciler.Name) image (expected exactly '$exactImportedName') on $firstNode." }

    $pushRef = "$registry/$($runtimeReconciler.Name):local"
    # Belt-and-suspenders: drop any stale $pushRef from a previous failed
    # attempt first, so a bug in the match above can't silently resurrect it.
    # Not checking exit code on purpose -- "not found" (nothing stale to
    # remove) is the expected outcome on a clean run. Not redirecting stderr
    # either -- PS5.1 turns redirected native stderr into a terminating
    # exception under $ErrorActionPreference = "Stop" regardless of exit code
    # (see install-fabric.ps1's history); unredirected it just prints and
    # continues.
    docker exec $firstNode ctr -n k8s.io images rm $pushRef
    docker exec $firstNode ctr -n k8s.io images tag $importedRef $pushRef
    if ($LASTEXITCODE -ne 0) { throw "ctr images tag failed for $pushRef on $firstNode" }
    # ctr's push can print a mid-transfer error (e.g. a missing content blob)
    # and still exit non-zero at the end -- but it does exit non-zero, so this
    # check alone is enough; it was missing before, which is how a real push
    # failure (see the --provenance=false comment above) got reported as a
    # silent "-> pushed" success with nothing actually in the registry.
    docker exec $firstNode ctr -n k8s.io images push --plain-http $pushRef
    if ($LASTEXITCODE -ne 0) { throw "ctr images push failed for $pushRef on $firstNode -- see output above for the real error" }
    Write-Host "  -> pushed $pushRef"
    $digestMap[$runtimeReconciler.ValueKey] = $pushRef
}

# --- Write the generated overlay ---
$outFile = $OutFile
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# GENERATED by build-images.ps1 -- do not hand-edit, it will be overwritten.")
$lines.Add("# Layered on top of values-control-plane.kind.yaml by install-charts.ps1.")
$lines.Add("cellController:")
if ($digestMap.ContainsKey("migrateImage")) {
    $lines.Add("  migrateImage: `"$($digestMap['migrateImage'])`"")
}
$lines.Add("  runtimeRegistry: `"$registry`"")
$lines.Add("  cellImages:")
foreach ($key in $digestMap.Keys) {
    if ($key -eq "migrateImage") { continue }
    $lines.Add("    ${key}: `"$($digestMap[$key])`"")
}
Set-Content -Path $outFile -Value $lines -Encoding utf8

Write-Host "`nWrote $outFile"
Write-Host "Done."
