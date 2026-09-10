# Local kind Cluster — Session Log

**Purpose:** running record of what's been done on the `testable-local` kind cluster
(replicating the `ai-testable-platform` prod/dev-eks architecture locally), so we can
pick the thread back up without re-deriving context. Update this file at the end of
each session rather than starting a new one.

**Repo:** `D:\Full-flow-testing\ai-testable-platform`
**Cluster scaffold:** `D:\Full-flow-testing\k8s-local` (NOT inside the git repo — kind
config, Helm values overrides, install scripts, and this log all live here on purpose)
**Standing rule:** Claude does **not** commit or push anything in the app repo. All
git writes are done by the user. Everything below marked "uncommitted" is still sitting
as working-tree changes waiting on the user to review/commit.

> **⚠️ Branch changed since the previous version of this log.** Local work moved from
> `dev` (19 local commits, now stale/behind) to a fresh branch **`dev-latest`**, created
> via `git checkout -b dev-latest origin/dev` — i.e. `origin/dev` taken as-is, no rebase,
> `dev` left completely untouched and recoverable. Section 10 below is the old log,
> kept for historical reference only; everything above it describes the *current*
> `dev-latest` session.

---

## 1. What this cluster is

A 3-node `kind` cluster (`testable-local`, Docker Desktop) running the real Helm charts
from the repo, currently checked out at `dev-latest`:
- `deploy/control-plane/helm` → release `testable-cp` (namespace `testable-control-plane`):
  identity-service, admin-console, web-console, cell-controller, admission-controller,
  global-postgres, control-plane-api.
- `deploy/whitebox/helm` → one release now:
  - `cell-cell-001` (namespace `whitebox-cell-001`) — cell `cell-001`, provisioned
    **end-to-end by cell-controller** via the real `POST /api/v1/cells` flow. This is
    the cell actually in use, and the only one that exists.
  - (`testable-wb`, the old manually-applied `local-dev` cell that was never
    registered in `cell_registry` and caused the original `Backend: LOCAL_DOCKER`
    bug, was torn down on 2026-09-06 with `helm uninstall testable-wb -n
    testable-whitebox-local` -- confirmed the shared fixtures in that same
    namespace, listed below, were untouched.)
- Shared fabric fixtures (`k8s-local/fabric-local.yaml`): `global-postgres`,
  `cell-postgres` (shared "RDS" stand-in, superuser `svc_runtime_supply`), `valkey`,
  `rabbitmq`, `temporal`, `minio` (S3 stand-in), `oci-registry` (plain `registry:2`,
  used as the runtime-image publish target).

**Current status: the full pipeline works end-to-end** — Create Cell → cell READY →
GitHub OAuth connect → repo sync → mirror upload → runtime image publish (real
BuildKit builds) → admission → task execution → real analyzer results. Verified with
a live run: 85 tasks completed, 3 failed (pre-existing eslint-config version mismatch,
unrelated to anything fixed this session), 5 skipped.

---

## 2. Access

```
kubectl config use-context kind-testable-local
```

Port-forwards (all die on pod restart — kubectl port-forward targets a specific pod IP,
not the Service; restart with `pkill -9 -f "port-forward svc/<name>"` then re-run):
```
kubectl port-forward -n testable-control-plane svc/identity-service 8000:8000
kubectl port-forward -n testable-control-plane svc/admin-console 3001:3000
kubectl port-forward -n testable-control-plane svc/web-console 3002:3000
kubectl port-forward -n whitebox-cell-001 svc/cell-001-ingestion-api 8001:8001
```

- **Admin console:** http://localhost:3001
- **Web console:** http://localhost:3002
- **Login:** `platform.admin@testable.cloud` / `LocalAdmin!2026` (platform_admin,
  bootstrapped via `POST /v1/internal/platform-operators`)
- **Control-plane-api (Go, cell lifecycle):** `kubectl port-forward svc/testable-control-plane-api 8021:8021`,
  bearer token = `CONTROL_PLANE_ADMIN_TOKEN` = `local-placeholder-admin-bootstrap-token`
  (break-glass header, `Authorization: Bearer ...`)
- **Stripe test key/webhook:** see §3 below — reused from the user's own dev-eks Stripe
  account, not `.env.docker`'s.
- **GitHub OAuth App (SCM/repo-import, kind-only):** client id `Ov23lixwjcyqUiKPwxfz`,
  callback `http://localhost:8001/api/v1/scm/callback/github` — separate from the
  compose stack's App so neither setup's callback breaks the other's.

---

## 3. What was fixed this session, in order

### 3.1 Stripe checkout — wrong Stripe account
`STRIPE_SECRET_KEY` was reused from `.env.docker`, but the seeded "Base" commercial
plan's `stripe_test_price_ref` (`price_1UA7GIGTvKP0mJW5fT5tTQWj`) belongs to a
**different** Stripe test account (confirmed via a direct `GET /v1/prices/<id>` —
404 under the old key, 200 under the user's real key). Swapped `devPlainSecrets.stripeSecretKey`
to the user-supplied key (`sk_test_51U9Kyd...`), confirmed against the same price.
Webhook: `stripe listen --api-key <key> --forward-to http://localhost:8000/v1/billing/webhooks/stripe`;
`devPlainSecrets.stripeWebhookSecret` updated to match the live session's `whsec_...`
(this value only stays valid while that `stripe listen` process is running — get a new
one and re-patch if it's restarted).

### 3.2 GitHub OAuth ("Connect GitHub" / SCM repo-import)
- `return_origin is not an allowed web origin` — `ingestion-api`'s `FRONTEND_URL` was
  never wired into the control-plane chart at all (only `identityBaseUrl` existed).
  Added `values.yaml` `frontendUrl` + `configmap.yaml` `FRONTEND_URL`; set to
  `http://localhost:3002` (matches the web-console port-forward). One-time Secret patch
  needed on `cell-001` since it predates the fix (`kubectl patch secret testable-whitebox-cell`).
- `SCM provider 'github' is not configured` — same class of gap: `SCM_GITHUB_CLIENT_ID/SECRET`,
  `SCM_TOKEN_SECRET`, `SCM_CALLBACK_BASE_URL` were only ever wired into the *whitebox*
  chart (for the old manual `testable-wb` release), never into the *control-plane*
  chart where `cell-controller` actually runs and would need to propagate them into
  every future cell's Secret. Added `cellController.scm.*` values + env wiring
  (`global-workloads.yaml`), populated in `k8s-local/values-control-plane.kind.yaml`.
- The existing GitHub OAuth App's one registered callback
  (`http://localhost:3001/ingestion-api`, matching the docker-compose stack's Next.js
  dev-server proxy path) can't work here — nothing in this kind cluster serves that
  path. **Created a second, kind-only OAuth App** (client id `Ov23lixwjcyqUiKPwxfz`,
  callback `http://localhost:8001/api/v1/scm/callback/github`, matching
  `kubectl port-forward svc/cell-001-ingestion-api 8001:8001`) instead of touching the
  shared App's callback (which would've broken the compose stack).

### 3.3 Cell-controller wiring gaps (control-plane chart never had these)
All of these follow the same shape: `cell-controller`'s Go code
(`k8sactuator/reconcile.go`'s `cellSecretData()`/`applyFabric()`) already knew how to
copy a value into every provisioned cell's Secret/Helm-values — it just was never given
the value in the first place, because the **control-plane chart** (where cell-controller
itself runs) never wired the corresponding env var. Fixed by adding
`cellController.<x>` values + `global-workloads.yaml` env entries for each, then
one-time-patching `cell-001`'s already-existing Secret (`testable-whitebox-cell`) since
it predates each fix, plus restarting whichever pod actually consumes it:

| Missing value | Symptom | Consuming pod |
|---|---|---|
| `ADMISSION_HOST` (defaulted to unresolvable bare `"admission-controller"`) | `Admission delayed: admission-controller unreachable; safe-mode DELAY` | `ingestion-api` (not runtime-api — easy to restart the wrong pod here) |
| `CELL_PG_USER` (only `CELL_PG_PASSWORD` was ever wired) | `Admission delayed: internal_error` / `admission.cell_pool_open_failed` | `admission-controller` itself (control-plane namespace) |
| `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (boto3 default-chain names) | `wb-orchestrator` mirror-bundle upload: `NoCredentialsError` | `wb-orchestrator` |
| `S3_ACCESS_KEY`/`S3_SECRET_KEY` (**different** names — `render_worker_fabric.py`'s own `s3_static_access_key()` check, not boto3's chain) | every task: `workspace_download_failed:NoCredentialsError` | runtime **worker** pods, via a *separate* reconciler-managed Secret (`whitebox-runtime-credentials`, not `testable-whitebox-cell`) |

Go changes: `types.go` (new `Config` fields `AdmissionHost`, `BuildkitRootless` — see
§3.5 — plus reusing existing `AWSAccessKeyID`/`AWSSecretAccessKey` under the new
`S3_ACCESS_KEY`/`S3_SECRET_KEY` map keys), `main.go` (env reads), `reconcile.go`
(`cellSecretData()`/`applyFabric()` additions). Rebuilt+reloaded `testable-cell-controller:local`
after every Go change (chart is baked into its image via `COPY deploy/whitebox/helm /charts/whitebox`,
so a *chart-only* change also needs an image rebuild, not just a `helm upgrade`).

### 3.4 NetworkPolicy — six real gaps found by actually exercising traffic patterns
`deploy/whitebox/helm/templates/networkpolicy.yaml` only ever covered the traffic
patterns previously exercised by the old manually-applied `local-dev` cell. Every one
of these is a genuine chart bug that would hit *any* cell-controller-provisioned cell,
anywhere — not a local-only workaround:

1. **pgbouncer ingress (port 5432)** — never opened; the old manual cell bypassed
   pgbouncer entirely (pointed `PGBOUNCER_HOST` straight at `cell-postgres`), so this
   was never exercised before. Every service's own DB connect sat in `SYN_SENT`
   forever (Calico default-drop, no RST) with zero application-level error.
2. **Same-cell pod-to-pod HTTP egress (8001/8002/8003/8010)** — the *ingress* rule for
   these ports already existed, but nothing allowed the *egress* side (wb-orchestrator
   → ingestion-api's `branch-tips-from-refs`, etc.). Added a same-podSelector egress
   rule mirroring the ingress one.
3. **MinIO (port 9000)** and **admission-controller (port 50051)** and **buildkitd
   (port 1234)** and **oci-registry (port 5000)** — all cross-namespace/in-cluster
   destinations that were simply never in any port list.
4. **Plain HTTP (port 80)** — only 443 was ever unrestricted-egress. Debian's default
   apt mirrors are HTTP, needed for every `apt-get` inside the runtime-image builds.
5. **Kubernetes API server via its real port (6443)** — `kubernetes.default.svc:443`
   gets DNAT'd by kube-proxy to the real apiserver address *before* Calico's filter
   ever sees the packet (`kubectl get endpoints kubernetes` showed `172.20.0.3:6443`,
   a node IP outside the pod subnet, on port 6443 not 443). Calico matches the
   *post-NAT* port, so the existing "443 anywhere" rule never covered this — any
   in-pod Kubernetes API client (`kubectl`, the k8s client library) hung on a silent
   connect timeout. This is the **same class of DNAT-before-Calico gotcha** already
   documented for RDS/ElastiCache-style CIDR rules, just hitting a new destination.

All of these are permanent chart fixes (`networkpolicy.yaml`), plus a rebuild of
`testable-cell-controller:local` (chart baked into its image) so future cells get them
automatically — not one-off `kubectl patch` workarounds, though a live patch was
applied first each time to unblock immediately.

### 3.5 Runtime-image publishing — the real fix chain (BuildKit)
The user explicitly asked for this to actually work, not be deferred. In order:

1. **Rootless BuildKit is fundamentally incompatible with kind+Calico.** A rootless
   `buildkitd` wraps its own process in rootlesskit's virtualized network stack
   (slirp4netns), separate from the pod's real network namespace — on this cluster
   that inner network has no route out *at all*, regardless of NetworkPolicy or DNS.
   **Fix:** added `runtimeReconciler.buildkitRootless` (default `true`, preserves real
   EKS behavior). Set `false` for local kind: `buildkitd` runs non-rootless/privileged,
   sharing the pod's real network directly (`network:host` confirmed in its own logs).
   Hit a genuine **Helm gotcha** along the way: `$rr.buildkitRootless | default true`
   silently ignores an explicit `false` (Sprig's `default()` treats `false` as "unset,"
   same as `nil`/`""`/`0`) — fixed with an explicit `hasKey` check instead.
2. **Debian apt mirrors return IPv6 addresses this cluster can't route.** Fixed by
   forcing IPv4 for apt in `docker/runtime/Dockerfile.base` (harmless everywhere else,
   inherited by every family image since they all `FROM` this one).
3. **NetworkPolicy port 80** — see §3.4.4.
4. **buildkitd needs its own daemon-level insecure-registry config**, separate from
   buildctl's `registry.insecure=true` output flag (which only covers the *push*
   target, not `FROM` base-image pulls that buildkitd itself resolves). Added a
   `buildkitd.toml` ConfigMap (`[registry."<host>"] http = true`) mounted in, gated on
   the registry not looking like a real ECR host (`*.amazonaws.com`) — a no-op for
   real EKS.
5. **The reconciler's own image needs to survive `imagePullPolicy: Always`** (correct,
   deliberate production behavior — a real ECR digest is always resolvable; our
   containerd-only digest aliases are not, since `Always` always re-verifies against a
   real registry rather than trusting local cache). Fixed by pushing
   `testable-runtime-reconciler:local` to the local `oci-registry` fixture for real,
   instead of the containerd-alias trick used for every other image. Push had to go
   through a kind **node's own containerd** (`docker exec <node> ctr images push
   --plain-http <clusterIP>:5000/...`) — pushing from the Windows Docker Desktop client
   through a `kubectl port-forward` tunnel repeatedly failed with mysterious
   "connection refused" (never diagnosed further, node-side push just works).
   Also had to use the registry's **ClusterIP**, not its `*.svc.cluster.local` DNS
   name — image pulls happen in the **node's own containerd**, outside any pod's
   network namespace, using the node's host DNS resolver; CoreDNS names are simply
   unresolvable there. A Service ClusterIP is still node-routable (kube-proxy programs
   it at the node level) without needing DNS at all.
   Kind's containerd also needed a one-time `certs.d`/`hosts.toml` insecure-registry
   config added + `systemctl restart containerd` on all 3 nodes (this cluster's
   containerd had no `config_path` set for this at all).
6. **A one-time Postgres deadlock** on `tool_version` during the reconciler's startup
   registry-projection step silently killed its *entire* build-planning cycle for that
   pod's lifetime (only lighter periodic tasks kept running afterward, no crash/restart
   to signal it). A plain pod restart resolved it — deadlocks are inherently transient,
   Postgres kills one side to break the cycle.
7. **Stuck `runtime_environment` rows** (`VERIFYING`/`BUILDING` with no `image_digest`)
   after a reconciler pod restart mid-build — the resume-probe logic requires an
   existing digest to resume from, which a row stuck mid-cycle never got. `UPDATE
   runtime_environment SET status='BUILD_REQUIRED' WHERE ... AND status IN
   ('VERIFYING','BUILDING')` + a pod restart (the watch loop only does its full
   build-planning pass once per pod lifetime, not continuously) cleared each one.
   BuildKit's own layer cache made every retry fast (the actual `docker build`-
   equivalent work was usually already done, just never recorded).

**End state:** all 9 real runtime environments (python 3.10/3.11/3.12, jvm 17/21,
dotnet 8, node 20/22, native) are `READY` with a real pushed digest, and every
`runtime-<family>` worker Deployment is healthy.

### 3.6 Cell reset / recreate flow (validated against docs/deployment/kubernetes/04-create-cell.md)
Confirmed the documented sanctioned flow works for real: `POST /api/v1/cells/{key}/decommission`
(namespace + database + Helm release all torn down cleanly by cell-controller) →
`POST /api/v1/cells` (fresh `REQUESTED` → cell-controller ticks it through
`PROVISIONING` → `VALIDATING` → `READY` on its own, no manual intervention needed once
all the wiring gaps above were fixed). Used this to validate fixes land correctly for
a **freshly created** cell, not just a patched-after-the-fact one.

### 3.7 Bootstrap platform-admin account
`POST /v1/internal/platform-operators` (bearer = `CONTROL_PLANE_ADMIN_TOKEN`, itself
needed the same "never wired into the control-plane chart" fix as everything in §3.3)
— idempotent upsert, always `ROLE_PLATFORM_ADMIN`, no tenant. Account:
`platform.admin@testable.cloud` / `LocalAdmin!2026`. A migration (`cp0068`) also
auto-seeds a default platform_admin on every fresh install — this is why the bootstrap
call returns `created: false` even against a freshly-reset database; it's resetting
the seeded account's password, not creating a new one.

### 3.8 Next.js standalone-server `HOSTNAME` bind bug (real bug, chart-level fix)
`web-console`/`admin-console` reported healthy ("✓ Ready") but were completely
unreachable — Kubernetes auto-injects `HOSTNAME=<pod-name>` into every container, and
Next.js 16's standalone `server.js` binds *literally* to that string (resolves to the
pod's own IP), not `0.0.0.0`. Fixed with an explicit `HOSTNAME: "0.0.0.0"` env override
in `global-workloads.yaml`, scoped to exclude `identityService` (not Next.js-based,
doesn't need it).

---

## 4. Known open items

- **Empty scorecard/summary projections after a completed run.** A real run
  (`3420f064-...`) completed with 85/93 tasks succeeding, but `scorecard_projections`,
  `run_summary_projections`, and `tool_result_projections` are all empty for it — no
  errors logged anywhere around the "projecting" phase. **Not yet determined** whether
  this is a real publish-step bug or correct behavior for a repo whose analyzers found
  zero scoreable findings. **Next step when picking this back up.**
- **3 task failures** in the completed run are a pre-existing `eslint.config.js` /
  `--eslintrc` CLI flag mismatch (eslint 9 removed the flag the tool wrapper still
  passes) — unrelated to anything fixed this session, not investigated further.
- A handful of duplicate `runtime_environment` rows (`worker-node-20-1`,
  `worker-python-3-12-1`, `worker-python-3-12-2`) exist as `FAILED`/`BUILD_REQUIRED`
  alongside their now-`READY` primary rows — harmless (admission only needs *one*
  ready row per family), not cleaned up.
- `SCM_CALLBACK_BASE_URL`/GitHub App choice only covers `ingestion-api` on
  `cell-001`/port 8001. If the cell is ever recreated under a different port-forward
  or `cell_key`, the callback URL (and the registered GitHub App setting) needs
  revisiting.

---

## 5. Uncommitted files right now (working tree, `dev-latest`)

Everything below is real, tested, working-tree state — **nothing has been committed by
Claude**, per standing instruction.

```
 M backend/go-control-plane/cmd/cell-controller/main.go
 M backend/go-control-plane/go.mod
 M backend/go-control-plane/go.sum
 M backend/go-control-plane/internal/k8sactuator/helm_cluster.go
 M backend/go-control-plane/internal/k8sactuator/reconcile.go
 M backend/go-control-plane/internal/k8sactuator/types.go
 M backend/ingestion-worker/main.py
 M backend/runtime-reconciler/runtime_reconciler/build_buildkit.py
 M backend/wb-orchestrator/main.py
 M deploy/control-plane/helm/templates/admission-controller.yaml
 M deploy/control-plane/helm/templates/configmap.yaml
 M deploy/control-plane/helm/templates/global-workloads.yaml
 M deploy/control-plane/helm/templates/serviceaccount.yaml
 M deploy/control-plane/helm/values.yaml
 M deploy/whitebox/helm/templates/_helpers.tpl
 M deploy/whitebox/helm/templates/buildkitd.yaml
 M deploy/whitebox/helm/templates/cell-workloads.yaml
 M deploy/whitebox/helm/templates/networkpolicy.yaml
 M deploy/whitebox/helm/templates/runtime-builder-rbac.yaml
 M deploy/whitebox/helm/templates/runtime-reconciler.yaml
 M deploy/whitebox/helm/values.yaml
 M docker/go-control-plane/Dockerfile.admission
 M docker/go-control-plane/Dockerfile.cell-controller
 M docker/go-control-plane/Dockerfile.control-plane
 M docker/go-control-plane/Dockerfile.provisioner
 M docker/runtime/Dockerfile.base
 M shared/temporal/connect.py
?? backend/go-control-plane/internal/k8sactuator/values_merge.go
?? backend/go-control-plane/internal/k8sactuator/values_merge_test.go
?? deploy/whitebox/helm/templates/configmap.yaml
```

Local-only overlay files (outside the git repo, never committed by design):
`k8s-local/values-control-plane.kind.yaml`, `k8s-local/values-whitebox.kind.yaml`,
`k8s-local/runtime-capacity-rbac.yaml` (cluster-wide `nodes: get,list` ClusterRole —
also deliberately out-of-band on real infra, per `runtime-builder-rbac.yaml`'s own
comment; applied directly via `kubectl apply`, not part of any chart), plus the full
bring-up/bring-down script set from §7: `install-fabric.ps1`, `build-images.ps1`,
`install-charts.ps1` (rewritten), `create-cell.ps1`, `port-forward.ps1`, `up.ps1`,
`down.ps1`, and two generated/state files `values-generated.kind.yaml` /
`.oci-registry-clusterip` (both regenerated fresh by `build-images.ps1`/
`install-fabric.ps1` — never hand-edit, safe to delete and re-run).

---

## 6. Where to pick this back up

1. Investigate the empty-projections gap (§4) — is it a real bug or expected for a
   clean-findings run?
2. Once satisfied, the user's own git workflow: review/commit the working-tree changes
   above at their own pace (Claude does not commit/push).
3. If creating more cells for testing: the whole `POST /api/v1/cells` → `READY` flow
   now works cleanly with zero manual intervention (§3.6) — no more per-cell patching
   needed, all fixes are baked into the `testable-cell-controller:local` image and the
   `dev-latest` chart working tree.

---

## 7. Scripted bring-up/bring-down, validated end-to-end (2026-09-06 evening)

The manual runbook in §2/§3 was turned into real scripts (`install-fabric.ps1`,
`build-images.ps1`, `install-charts.ps1`, `create-cell.ps1`, `port-forward.ps1`,
`up.ps1`, `down.ps1` — all new except `install-cluster.ps1`/`uninstall-cluster.ps1`,
which were already correct). Rather than trust them unverified, they were run
end-to-end against a **second, disposable kind cluster** (`testable-local-test`,
never touching the live `testable-local` cluster) — zero to a real `READY` cell,
then torn down. This caught **7 real, independent bugs**, none of them hit before
because the live cluster's history papered over every one of them (leftover
ServiceAccounts/Secrets from early manual setup, already-warm image caches,
already-registered digest aliases). A genuinely fresh cluster is the only way any
of these would ever surface — which is the whole reason this validation pass was
worth doing before trusting the scripts.

1. **PowerShell 5.1: redirecting native stderr — even to `$null` — throws.**
   `kubectl get namespace $ns 2>$null` doesn't silently discard the "not found"
   error the way it looks like it should; PS 5.1 wraps *any* redirected native
   stderr into a terminating ErrorRecord under `$ErrorActionPreference = "Stop"`,
   regardless of exit code or redirect target. Fixed throughout by using
   `--ignore-not-found -o name` (empty output, not an error) instead of
   redirecting, matching the pattern `install-cluster.ps1` already used for its
   own namespace-wait — I just hadn't applied it consistently everywhere.
2. **Calico readiness race in `install-cluster.ps1`.** `kubectl wait
   --for=condition=Available tigerastatus/calico` errors immediately with
   NotFound if the resource doesn't exist yet — it does not poll for creation.
   The operator can take a while after `custom-resources.yaml` is applied before
   it writes these objects; the old script's wait raced ahead, and because that
   error is unredirected stderr (not fatal per PS 5.1's rules, see #1), the
   script sailed on as if Calico were ready. Fixed with a wait-for-existence loop
   before the condition wait (`Wait-ForTigeraStatusReady`), mirroring the
   namespace-appear wait already used elsewhere in the same script.
3. **`docker cp` is unreliable on this Docker Desktop + WSL2 setup.** It can
   report exit 0 while silently not writing the file, and separately report a
   false "file not found" reading back a file `docker exec` had just proven
   exists. Confirmed by hashing a full 0-255 byte range round-tripped through
   it. Replaced everywhere (the containerd registry-config patch, the
   runtime-reconciler tar push) with `docker exec -i ... sh -c "cat > path"` fed
   via `cmd.exe`'s `<` file redirection — byte-exact, verified against the same
   full byte range, and doesn't go through `docker cp`'s code path at all.
4. **This containerd version ships no `[plugins."io.containerd.grpc.v1.cri".registry]`
   section in `config.toml` at all.** The original patch script assumed the
   section existed and tried to `sed` a `config_path` line into it — the pattern
   silently matched nothing, so it looked like it worked while doing nothing.
   Confirmed by dumping the node's actual `config.toml`. Fixed by appending the
   whole section fresh (TOML allows a table to be defined anywhere in the file),
   guarded by an existence check for idempotency.
5. **Helm hook-ordering: the control-plane chart's ServiceAccount was a plain
   (non-hook) resource**, but `global-migrate` (a pre-install hook at weight
   -10) runs its pod under that ServiceAccount. Non-hook resources only apply in
   Helm's main phase, strictly *after* every hook — so on a genuinely fresh
   install, the Job's pod creation fails outright with "serviceaccount ... not
   found," retried by the job-controller until Helm's hook-wait times out. This
   never surfaced on the live cluster because its ServiceAccount already existed
   from an earlier partial install attempt. Fixed by making the ServiceAccount a
   hook too (weight -30, earlier than the ConfigMap's -20 and the Job's -10) —
   same class of fix already applied to the ConfigMap earlier this session, just
   not carried over to this resource too.
6. **A placeholder `testable-control-plane` Secret was created manually on day
   one of this whole local-kind effort (2026-09-04), never captured in any
   script.** `existingSecret: testable-control-plane`'s `envFrom` requires the
   Secret to exist (not `optional: true`) even though every real local value
   comes from the ConfigMap's `devPlainSecrets` block instead — the Secret's
   content is never actually read. Without it, every control-plane pod sits in
   `CreateContainerConfigError: secret "testable-control-plane" not found`.
   Fixed by creating it idempotently in `install-fabric.ps1`
   (`_placeholder: local-kind-testing-only`).
7. **A `testable` Postgres role, also created manually on day one, was never
   scripted either.** Migration `cp0079_security_definer_privileges` runs
   `ALTER FUNCTION ... OWNER TO testable` unconditionally (unlike
   `apply_global_service_roles.sql`'s own grants to the same role, which guard
   on `pg_roles` first) — on real dev-eks this role is presumably provisioned
   out-of-band (Terraform/RDS bootstrap), never by the migration itself. Fixed
   by creating it (`NOLOGIN`, idempotent) in `install-fabric.ps1` right after
   global-postgres is confirmed Ready.
8. **Wrong Docker build context for 4 of the 19 images**
   (`web-console`, `admin-console`, `control-plane-api`, `admission-controller`).
   All four Dockerfiles use bare, context-root-relative `COPY` paths (`COPY
   package.json ./`, `COPY go.mod go.sum ./`) that only resolve against a
   subdirectory (`frontend/web-console`, `frontend/admin-console`,
   `backend/go-control-plane` respectively), not the repo root every other
   image uses. **This was initially misdiagnosed as Docker Desktop/WSL2
   build-context flakiness** (issue #3 primed that assumption) and "fixed" with
   a retry loop — which is why it took 3 identical failures across 3 attempts
   to notice it wasn't transient at all. Actual contexts confirmed against
   `scripts/eks/build-arm64-images.sh` and each service's own
   `.github/workflows/*-dev.yml` (`BUILD_CONTEXT`). Fixed via a per-image
   `Context` override in `build-images.ps1`; the retry loop stayed (a real,
   if smaller, safety net) now that a wrong-context bug can no longer hide
   behind it silently reusing a stale cached image.
9. **`kind load docker-image` only registers an image under its `:local` TAG
   name in each node's containerd — never under its digest as its own name.**
   containerd's CRI image lookup matches by exact reference *string*, not by
   content hash, so a pod referencing bare `name@sha256:digest` (what
   cell-controller's Go code always emits) found no local match and fell
   through to a real network pull attempt against a repository that doesn't
   exist (`pull access denied ... insufficient_scope`) — even though the
   identical content was already sitting right there under the `:local` tag.
   This never surfaced on the live cluster because an earlier, undocumented
   manual step had already registered every image under both names there
   (confirmed by comparing `ctr images ls` output between the two clusters).
   Fixed by explicitly `ctr images tag`-ing every digest-pinned image under its
   own digest name, on every node, right after `kind load`.

Also fixed along the way, smaller but worth keeping in mind:
- `install-charts.ps1` and `Build-Image`/`Load-Image` never checked exit codes
  at all — a failed `helm upgrade --install` or `docker build` used to be
  silently swallowed, letting the script confidently proceed as if everything
  had worked. All the real bugs above were only *visible* at all because this
  got fixed first.
- `create-cell.ps1`'s poll loop didn't treat `FAILED` as terminal (cell-controller
  never auto-retries a FAILED cell — only REQUESTED/PROVISIONING/VALIDATING/
  DECOMMISSIONING get ticked) — it just polled the same status until the full
  timeout. Fixed to stop immediately on FAILED, and to auto-call the real
  `POST .../retry` lifecycle action first if the cell already exists in that
  state, since a plain `createCell` call just returns an existing
  non-decommissioned cell unchanged.
- Hit the documented cell-controller singleton-fence rolling-update deadlock
  (§ "Postgres advisory-lock singleton fence" in the technical notes elsewhere
  in this project) during the chart upgrade that picked up corrected image
  digests — same known fix, `kubectl scale rs <old-rs> --replicas=0`.

**End state:** `testable-local-test` reached `cell-001` status `READY` from a
genuinely empty cluster, fully through the scripts (one manual RS-scale
intervention for the known singleton-fence deadlock, and one manual API retry
call now automated into `create-cell.ps1`). Deleted immediately after
(`uninstall-cluster.ps1 -ClusterName testable-local-test`) — confirmed the live
`testable-local` cluster was completely unaffected throughout (separate cluster,
separate state files for `install-fabric.ps1`/`build-images.ps1`'s generated
output the whole time). All 9 fixes above are real, permanent script/chart fixes,
not local-only workarounds — items 1-4 and 9 are pure `k8s-local/*.ps1` script
fixes (never touch the git repo); items 5-7 are real chart/migration bugs in
`ai-testable-platform` itself (`serviceaccount.yaml`'s hook annotation is a
working-tree change alongside everything in §5); item 8 is purely a
`k8s-local/build-images.ps1` fix (the Dockerfiles and CI workflows were already
correct — my script's assumed context was the only thing wrong).

### 7.1 Design refinement: cell creation is manual, port-forwards split by dependency

After the validation pass above, `up.ps1` called `create-cell.ps1` automatically
as its last step. Changed on request: cell creation is a real, meaningful action
(provisions a namespace, a database, a whole Helm release) that shouldn't happen
silently as a side effect of "start the cluster" — it's now always a separate,
manual `.\create-cell.ps1` call.

That raised the natural follow-up: does `port-forward.ps1` have to be manual too,
since it was being deferred until after cell creation? No — only **one of its
four forwards** (`<cell>-ingestion-api`, which lives in the cell's own
`whitebox-<key>` namespace) actually depends on a cell existing. The other three
(`identity-service`, `admin-console`, `web-console`) are control-plane chart
resources, up the moment `install-charts.ps1` succeeds, with zero cell
dependency — there was no real reason to gate all four behind a manual step.

Fixed by having `port-forward.ps1` check whether the cell's Service actually
exists (`kubectl get svc ... --ignore-not-found`, not `2>$null` — the PS 5.1
stderr-redirect gotcha from #1 applies here too) before attempting that one
forward, skipping it with a clear message instead of either failing or requiring
the caller to already know not to run it yet. `up.ps1` now ends with an automatic
`port-forward.ps1` call (5 steps total: cluster, fabric, images, chart install,
port-forwards) and prints `create-cell.ps1` as the one remaining manual step,
with a reminder to re-run `port-forward.ps1` afterward to pick up the cell's
ingestion-api once it exists.

Verified against the **live** `testable-local` cluster directly (cell-001 already
exists there): correctly stopped every prior forward — including one unrelated
leftover Temporal port-forward from earlier ad hoc debugging, harmlessly caught
by the same kill-all-`kubectl port-forward`-processes match — then restarted all
four fresh and confirmed each one actually responds (`identity-service` 200,
`admin-console` 200, `web-console` 307 redirect — its normal behavior,
`ingestion-api` 200).

Follow-up consistency pass across the other scripts' own usage comments:
- `install-charts.ps1`'s end-of-run hint used to only mention `create-cell.ps1`
  next; updated to also mention `port-forward.ps1` for whoever runs these
  scripts individually rather than through `up.ps1` (three of its four
  forwards work immediately after this script, no cell needed).
- `create-cell.ps1`'s own docstring now explicitly states it's deliberately
  excluded from `up.ps1`, matching the reasoning now duplicated in `up.ps1`'s
  and `install-charts.ps1`'s comments.
- `down.ps1` referenced "SESSION_LOG.md section 6 (Bring-down)" -- a section
  that was never actually written into this file (only ever explained in
  chat) and, after §7's insertion, would have pointed at the wrong section
  number regardless. Removed the specific reference; the comment was already
  fully self-contained without it.
- Also caught while here: §8's internal subsection labels (`### 7.1`-`### 7.4`)
  were still numbered as if they were under the old §7 -- a leftover from
  renumbering the historical section to §8 to make room for this one.
  Renumbered to `### 8.1`-`### 8.4`.

---

## 8. `oci-registry` ephemeral storage — runtime-reconciler dead for 19h (2026-09-07)

**Symptom reported by user:** ran an "execute" and it produced nothing; admin
console's Workers page showed a "STALE projection" banner.

**Root cause found:** `runtime-reconciler` (`whitebox-cell-001`) was `0/1
ImagePullBackOff`, continuously, since the moment it was created — never once
Ready. Its Deployment correctly uses `imagePullPolicy: Always` (§7's own
comment explains why: an ECR-style digest needs independent verification on
every pull, a bare containerd digest alias doesn't). But `oci-registry`
(the in-cluster `registry:2` pod push target for this one image — see §7's
"Group 2" in `build-images.ps1`) was defined in `fabric-local.yaml` with
**no volume at all** — `registry:2`'s default storage lived directly in the
container's own writable layer. Every container restart (kubelet
crash-restart, or a Docker Desktop restart — the pod had already restarted 15
times over its 2d12h life) silently wiped every pushed image. `imagePullPolicy:
Always` then means every subsequent pull hits an empty registry
(`{"repositories":[]}` confirmed via `/v2/_catalog`) and fails outright —
`docker cp`/`kind load`-cached copies in node containerd don't help, since
`Always` never falls back to a local cache on a failed remote pull.

This traces directly to the failed execute: `wb-orchestrator` logs show the
run (`31659d65-...`) terminating at `error_code: no_results`, all 22 tasks
`skipped`, `reason: "no task produced evidence to score"` — consistent with
no usable runtime being reconciled/available.

**Fix (two parts):**
1. Immediate recovery: rebuilt nothing (the already-built local
   `testable-runtime-reconciler:local` image was current), just re-ran the
   registry push in isolation — `.\build-images.ps1 -Only runtime-reconciler
   -SkipBuild -OutFile <scratch>` (the `-OutFile` override kept this from
   clobbering the real `values-generated.kind.yaml`'s full digest map, since
   `-Only` means `$digestMap` would otherwise only contain this one key).
   Deleted the stuck pod to force an immediate re-pull; came up clean.
2. Durable fix: added an `emptyDir` volume to `oci-registry`'s pod spec in
   `fabric-local.yaml`, mounted at `/var/lib/registry` (the image's default
   storage path). `emptyDir` survives container restarts within the same pod
   (only pod *deletion* wipes it) — verified by `kill 1`-ing the registry
   container directly and confirming `/v2/_catalog` still listed the image
   afterward. Since it's a bare `Pod` (not a Deployment), the volume change
   required delete+recreate, not `kubectl apply` in place — re-pushed
   `runtime-reconciler` once more afterward since the delete itself wiped the
   pre-fix content one last time.

**Note found along the way (not fixed, not the cause of this bug):** the
`.oci-registry-clusterip` state file was missing from disk (most likely swept
up during §7's disposable-test-cluster cleanup, since `.oci-registry-clusterip.test`
was explicitly deleted there and this may have gone with it). Recreated by hand
from the live Service's ClusterIP (`kubectl get svc oci-registry -o
jsonpath='{.spec.clusterIP}'`) plus the `:5000` port `install-fabric.ps1`
always appends — if it goes missing again, that's the fix, no need to re-run
the whole fabric install.

**Unrelated, logged but not investigated:** a `worker.poller.describe_failed`
/ `RPCError: operation was canceled` warning appeared in `wb-orchestrator`
logs at 06:00:40, right around this session's own pod deletions — almost
certainly transient noise from Calico re-establishing routes after
`oci-registry`/`runtime-reconciler` pod churn, not a new independent bug.
Watch for recurrence outside of active pod-deletion testing before treating
it as real.

---

## 9. Platform findings surfaced by testing a second cell (2026-09-07)

A second cell was created and torn down while working through capacity/Plan
sizing for 10 tenants. The cell itself is gone (full teardown wipes it — same
as any cell, recreate on demand via `POST /api/v1/cells` if needed again).
What's worth keeping is what only became visible *because* two cells existed
at once — these are facts about the platform, not about that cell.

### 9.1 SCM OAuth callback was hardcoded to one cell — real fix, applies to every future cell

`SCM_CALLBACK_BASE_URL` was a raw single-cell URL (`http://localhost:8001`)
baked in three places: `k8s-local/values-control-plane.kind.yaml`
(cell-controller's own env var, stamped into every cell it provisions),
each cell's whitebox ConfigMap, and — the one that actually won at runtime —
each cell's `testable-whitebox-cell` Secret, written directly by
cell-controller's Go code (not Helm-templated), which sits later in
`envFrom` and silently overrides the ConfigMap's value.

Fix: point it at web-console's own stable proxy path instead of a raw cell
port — `http://localhost:3002/ingestion-api`. This makes
`redirect_uri=http://localhost:3002/ingestion-api/api/v1/scm/callback/{provider}`,
identical for every cell, forever. GitHub redirects to that one fixed
address; `web-console/src/proxy.ts` + `lib/proxy/cell-upstream.ts`'s
`resolveCellKey()` (session cookie → `GET /api/v1/me/route`) dynamically
forwards server-side to whichever cell the tenant is actually on. No
per-cell port-forward, no per-cell GitHub App registration.

Fixed for good in `values-control-plane.kind.yaml` (cell-controller's own
source — every future cell inherits the correct value automatically, no
per-cell action needed ever again).

External caveat, not fixable from here: GitHub OAuth Apps validate
`redirect_uri` against what's registered in the App's own Developer
Settings. If only the old `localhost:8001` callback is registered there,
GitHub rejects with `redirect_uri_mismatch` regardless of what our code
sends — add the new callback URL there if that happens.

### 9.2 `cell-controller` never re-touches an already-`READY` cell

Traced `Tick()` (`k8sactuator/reconcile.go:256-287`): it only calls
`Reconcile()` for cells in `Requested`/`Provisioning`/`Validating`/
`Decommissioning` status. Anything else — including `READY` — hits
`default: return nil`, a no-op, every tick, forever. **No config change on
cell-controller (env vars, chart defaults) ever retroactively applies to an
already-READY cell.** Confirmed directly: fixing §9.1's env var required
manually `helm upgrade`-ing each existing cell's whitebox release *and*
manually patching its Secret — the running cell never picked it up on its
own. Same shape as §8's `set_cell_capacity` gap: this codebase never
proactively pushes Global config changes into steady-state cells, only
applies them fresh at creation or explicit re-provision.

### 9.3 Platform placement-mode change has a real auto-reconciliation trigger (unlike `set_cell_capacity`)

`set_platform_placement_policy()` (SQL, `cp0077_plan_placement_reconciliation_outbox.py:224`)
enqueues `request_plan_placement_reconciliation()` for every active Plan
**whenever the mode itself changes** (`DEFAULT_CELL` ↔ `PLAN_BASED`) — this
actually re-evaluates and can re-home already-placed tenants. Confirmed
live: a tenant stuck with `GUARANTEE_PACKING_EXCEEDED` got automatically
re-homed and unblocked purely from this mode switch, no manual DB touch
needed. Worth remembering as the one config change in this system that
*does* self-propagate — contrast with §8 and §9.2, where nothing does.

### 9.4 Local kind cluster's real memory ceiling

Two cells' full runtime pools running simultaneously (13 environments each)
on this cluster's 2 shared eligible nodes — themselves one shared Docker
Desktop VM, not two real machines (see the capacity-observation audit
earlier this session) — genuinely exhausted memory: a runtime pod sat
`Pending` for 2+ hours (`FailedScheduling: 2 Insufficient memory`), and
later a plain Deployment restart stuck on `1 old replicas pending
termination` until the old pod was deleted by hand to free room for the
surge pod. Not a config problem — it's the real ceiling of this laptop.
Running more than one cell's full pool at once here will hit this again.

### 9.5 Open, not fixed: probe Job missing resource limits

`build_buildkit.py:352-390`'s `probe()` function creates a Kubernetes Job
(`runtime-probe-*`, container `probe`) with no `resources` block at all —
every runtime image verification (routine, happens on every build) briefly
flips the owning cell's capacity status to `UNSAFE`
(`UNBOUNDED_PLATFORM_POD` in `capacity_observe.py`) for the few seconds the
Job runs. Self-resolving (`ttlSecondsAfterFinished: 600`), cosmetic, but
real and structural — will recur on any cell, indefinitely, until
`resources.requests`/`resources.limits` are added to that container spec.
Offered this session, not requested — still open.

---

## 10. Historical log (old `dev` branch, superseded — kept for reference only)

<details>
<summary>Click to expand the pre-<code>dev-latest</code> session log</summary>

### 10.1 What this cluster was (on `dev`, 19 local commits ahead)

Same 3-node kind cluster, but running local `dev` (branch since abandoned in favor of
`dev-latest` — see the banner at the top of this file). Two whitebox releases:
`testable-wb` (manual) and `cell-cell-001` (cell-controller-provisioned) existed then
too, but against much older chart/Go code.

### 10.2 State as of that session

- Cluster, both Helm releases installed cleanly via the merged-values-file path.
- PgBouncer added as a real Deployment+Service (SCRAM auth).
- NetworkPolicy opened for 8001/8002/8003/8010 (later fully redone on `dev-latest`,
  see §3.4 above).
- admin-console/web-console reachable, platform_admin bootstrap login fixed.
- cell-controller provisioned `cell-001` to READY.
- `worker-python-3-12` reached READY once, manually.
- Temporal DNS-race crash-loops fixed via backoff retry.
- runtime-reconciler RBAC fixed for K8s API access (CronJob mode).
- Stripe/SCM env wired via `devPlainSecrets` (redone more completely on `dev-latest`,
  see §3.1–3.3 above).

### 10.3 Fixes made on `dev` (summarized; full detail was in the pre-`dev-latest` version of this file)

- **Helm `--set` array-corruption bug** — `ApplyRelease` rewritten to merge a full
  values file instead of many `--set` flags (`mergeDotPath` helper + tests). This fix
  carried forward into `dev-latest` and is still in place.
- **PgBouncer real deployment** — added `pgbouncer.yaml`, SCRAM auth.
- **Platform-admin login bug** — `shared/auth/dependencies.py` required a
  `tenant_members` row unconditionally; platform admins have none by design. Fixed to
  degrade gracefully. (This was an upstream-shaped fix; verify it's still needed / still
  present on `dev-latest`, since `dev-latest` may already include the real upstream fix.)
- **admin-console/web-console proxy + `readOnlyRootFilesystem`** — sentinel
  env-var substitution pattern extended, entrypoint scripts rewritten to copy
  `.next-src` → writable `.next` at container start.
- **Temporal DNS race** — `connect_temporal_with_backoff()` added to
  `shared/temporal/connect.py`, wired into `ingestion-worker`/`wb-orchestrator`. This
  fix carried forward into `dev-latest` and is still in place (§ uncommitted files
  above).
- **runtime-reconciler RBAC** (CronJob mode) — dedicated ServiceAccount/Role/RoleBinding
  instead of the shared `whitebox.podScheduling` helper. Superseded on `dev-latest` by
  a more complete fix (§3.4 above, `runtime-builder-rbac.yaml` gate removed entirely
  rather than replaced).
- **`ROLLOUT_FAILED` AttributeError** — log-only stopgap in
  `shared/persistence/runtime_environment.py`, pending the real upstream commit
  (`6f3fa56e3`). Status on `dev-latest`: **not re-verified** — check whether
  `dev-latest` already has the real upstream fix before re-applying this stopgap.
- **`git fetch origin dev` (read-only)** confirmed local `dev` was ~139 commits behind
  `origin/dev` with 19 true local-only commits. This divergence is *why* `dev-latest`
  was created fresh from `origin/dev` rather than rebasing — a full rebase produced 76
  conflicts on the very first commit (CI workflow files). `dev` and its 19 commits are
  preserved, untouched, and still available if any of them turn out to be needed.

### 10.4 Deliberately not fixed (on `dev`)

- `backend/wb-cpu-worker/` missing from the old `docker/runtime-reconciler/Dockerfile`'s
  build context — moot on `dev-latest`, that Dockerfile now correctly includes it
  (confirmed working in §3.5 above).
- `error: no objects passed to scale` — matched upstream `fbb2252c8`. **Status on
  `dev-latest`: not yet hit again** — the whole runtime-reconciler/worker-fabric flow
  was rebuilt from a much more current `dev-latest` checkout that may already include
  this fix. Watch for it if scaling issues show up.
- Full BuildKit-based in-cluster publisher (`b62588bdf`) — **this exists and is fully
  working on `dev-latest`** (§3.5 above). No longer an open item.

</details>
