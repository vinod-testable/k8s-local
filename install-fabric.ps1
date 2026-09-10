<#
Applies the shared local "fabric" fixtures (global-postgres, cell-postgres,
valkey, rabbitmq, kafka, temporal, minio, oci-registry) that stand in for
real RDS/ElastiCache/MSK/Temporal Cloud/S3/ECR, and configures every kind
node's containerd to treat oci-registry as an insecure (plain-HTTP) registry
-- kind's own documented local-registry pattern, not a real-infra step.

Must run AFTER install-cluster.ps1 and BEFORE install-charts.ps1:
global-migrate runs as a pre-upgrade Helm hook against global-postgres, so
that fixture has to exist before the control-plane chart's first install.

Safe to re-run: kubectl apply is idempotent, and the containerd config step
checks before it edits anything.
#>
param(
    [string]$ClusterName = "testable-local",
    # Override for testing against a second, disposable cluster -- keeps a
    # throwaway run from clobbering the real cluster's saved registry IP.
    [string]$StateFile = (Join-Path $PSScriptRoot ".oci-registry-clusterip")
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Assert-Cmd($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name not found on PATH. Install it before running this script."
    }
}
Assert-Cmd kubectl
Assert-Cmd docker
Assert-Cmd kind

$expectedCtx = "kind-$ClusterName"
# No stderr redirect here -- see install-cluster.ps1's comment on the same
# gotcha: in PS 5.1, redirecting a native command's stderr (even to $null)
# wraps it in a terminating ErrorRecord under $ErrorActionPreference = "Stop",
# regardless of exit code. Unredirected stderr text is just normal output.
$currentCtx = kubectl config current-context
if ($LASTEXITCODE -ne 0) { $currentCtx = "" }
if ($currentCtx.Trim() -ne $expectedCtx) {
    throw "kubectl context is '$($currentCtx.Trim())', expected '$expectedCtx'. Run install-cluster.ps1 first."
}

Write-Host "Ensuring namespaces exist..."
foreach ($ns in @("testable-control-plane", "testable-whitebox-local")) {
    # --ignore-not-found returns empty output (not an error) when missing --
    # same pattern install-cluster.ps1 uses for its own namespace-appear wait.
    # A bare `2>$null` here throws instead of suppressing (PS 5.1 wraps any
    # redirected native stderr into a terminating ErrorRecord regardless of
    # where it's redirected to).
    $existing = kubectl get namespace $ns --ignore-not-found -o name
    if (-not $existing) {
        kubectl create namespace $ns | Out-Null
        Write-Host "  created $ns"
    } else {
        Write-Host "  $ns already exists"
    }
}

# values.yaml's `existingSecret: testable-control-plane` is the real-infra
# path (staging/prod populate it externally, e.g. via ExternalSecrets/Vault)
# -- every control-plane pod's envFrom requires it to exist (not `optional:
# true`), even though local dev's actual values all come from the ConfigMap's
# devPlainSecrets block instead. Without this, every pod referencing it
# (global-migrate first, since it runs earliest as a hook) sits in
# CreateContainerConfigError: secret "testable-control-plane" not found.
# Content is never read locally -- the key just needs to exist.
Write-Host "Ensuring placeholder control-plane Secret exists..."
kubectl create secret generic testable-control-plane -n testable-control-plane `
    --from-literal=_placeholder=local-kind-testing-only `
    --dry-run=client -o yaml | kubectl apply -f - | Out-Null

Write-Host "`nApplying fabric-local.yaml..."
kubectl apply -f (Join-Path $here "fabric-local.yaml")

Write-Host "`nWaiting for fixture pods to be Ready (first pull can take a minute)..."
$fixtures = @(
    @{ Ns = "testable-control-plane";   Pod = "global-postgres" },
    @{ Ns = "testable-whitebox-local";  Pod = "cell-postgres" },
    @{ Ns = "testable-whitebox-local";  Pod = "rabbitmq" },
    @{ Ns = "testable-whitebox-local";  Pod = "kafka" },
    @{ Ns = "testable-whitebox-local";  Pod = "temporal-postgres" },
    @{ Ns = "testable-whitebox-local";  Pod = "temporal" },
    @{ Ns = "testable-whitebox-local";  Pod = "minio" },
    @{ Ns = "testable-whitebox-local";  Pod = "oci-registry" }
)
foreach ($f in $fixtures) {
    Write-Host "  waiting on $($f.Ns)/$($f.Pod)..."
    kubectl -n $f.Ns wait --for=condition=Ready "pod/$($f.Pod)" --timeout=180s
}

# On real dev-eks, DB_USER for migrations is `testable_admin`, not `testable`
# -- `testable` is a separate, LOGIN-less ownership role that several
# privileged SECURITY DEFINER functions get ALTERed to (both in
# scripts/db-roles/apply_global_service_roles.sql, which guards on it
# conditionally, and in later Alembic migrations like
# cp0079_security_definer_privileges, which does NOT guard and just fails
# outright: `role "testable" does not exist`). On real infra this role is
# presumably created out-of-band (Terraform/RDS bootstrap), never by the
# migration itself. This fixture's Postgres has no equivalent bootstrap, so
# create it here, idempotently, before global-migrate's hook can run.
Write-Host "Ensuring the 'testable' ownership role exists in global-postgres..."
$roleSql = 'DO $do$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=''testable'') THEN CREATE ROLE testable NOLOGIN; END IF; END $do$;'
$roleSql | kubectl exec -i -n testable-control-plane global-postgres -- psql -U svc_control_plane -d testable_global
if ($LASTEXITCODE -ne 0) { throw "Failed to ensure the 'testable' role exists in global-postgres." }

$registryIP = (kubectl -n testable-whitebox-local get svc oci-registry -o jsonpath="{.spec.clusterIP}").Trim()
if (-not $registryIP) { throw "Could not resolve oci-registry's ClusterIP." }
$registryHostPort = "${registryIP}:5000"
Write-Host "`noci-registry ClusterIP: $registryHostPort"

Write-Host "Configuring insecure-registry access on every kind node's containerd..."
$hostsToml = @"
server = "http://$registryHostPort"

[host."http://$registryHostPort"]
  capabilities = ["pull", "resolve", "push"]
"@
$tmpHosts = Join-Path $env:TEMP "oci-registry-hosts.toml"
# ASCII, not utf8 -- PS 5.1's -Encoding utf8 always prepends a BOM, which
# would land as garbage bytes at the top of the file inside the container.
# Content here is plain ASCII, so this is a safe, simpler fix.
Set-Content -Path $tmpHosts -Value $hostsToml -Encoding ascii -NoNewline

# The kind/containerd version in use as of 2026-09 (containerd 2.3.4) ships
# NO [plugins."io.containerd.grpc.v1.cri".registry] section in config.toml at
# all -- confirmed by inspecting a live node's config.toml directly (an
# earlier version of this script assumed the section existed and tried to
# sed a config_path line into it; the sed pattern silently matched nothing,
# so it appeared to succeed while doing nothing). TOML allows a table to be
# defined anywhere in the file, so appending it fresh at the end is safe and
# is kind's own documented approach for a local registry.
$patchScript = @'
#!/bin/sh
set -e
CFG=/etc/containerd/config.toml
if grep -q 'plugins."io.containerd.grpc.v1.cri".registry' "$CFG"; then
  exit 0
fi
cat >> "$CFG" <<'TOML'

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
TOML
'@
$tmpPatch = Join-Path $env:TEMP "patch-containerd-registry.sh"
Set-Content -Path $tmpPatch -Value $patchScript -Encoding ascii -NoNewline

# `docker cp` is unreliable on this Docker Desktop + WSL2 setup -- it exits 0
# without actually writing the file (confirmed by hashing round-tripped
# content: silent no-op on write, and a false "file not found" reading a
# file docker exec itself had just proven exists). `docker exec -i ... cat >`
# fed via cmd.exe's `<` file redirection is byte-exact (verified against a
# full 0-255 byte range including embedded NULs) and doesn't go through
# docker cp's code path at all.
function Send-FileToNode($node, $localPath, $remotePath) {
    cmd /c "docker exec -i $node sh -c ""cat > $remotePath"" < ""$localPath"""
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy $localPath to ${node}:$remotePath" }
}

$nodes = kind get nodes --name $ClusterName
foreach ($node in $nodes) {
    Write-Host "  $node"
    docker exec $node mkdir -p "/etc/containerd/certs.d/$registryHostPort"
    Send-FileToNode $node $tmpHosts "/etc/containerd/certs.d/$registryHostPort/hosts.toml"
    Send-FileToNode $node $tmpPatch "/tmp/patch-containerd-registry.sh"
    docker exec $node sh /tmp/patch-containerd-registry.sh
    if ($LASTEXITCODE -ne 0) { throw "containerd registry patch failed on $node" }
    docker exec $node systemctl restart containerd
}
Remove-Item $tmpHosts, $tmpPatch -ErrorAction SilentlyContinue

# -Encoding utf8 here silently prepends a BOM in PS5.1, which build-images.ps1
# then reads back as part of the registry host:port string -- ascii avoids it.
$registryHostPort | Set-Content -Path $StateFile -Encoding ascii -NoNewline
Write-Host "`nFabric is up. oci-registry reachable in-cluster at $registryHostPort"
Write-Host "(saved to $StateFile -- build-images.ps1 reads it via -RegistryStateFile)"
