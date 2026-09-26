# Feature Flag Service — A Self-Built Internal Developer Platform

## 1. What This Is

A production-style feature flag service (create, evaluate, and roll out flags with
percentage-based targeting, audit logging, and fail-safe defaults) built end-to-end
with the full platform around it: containerized, CI/CD'd, provisioned via Terraform,
deployed to Kubernetes through GitOps (Argo CD), policy-enforced (Kyverno), observable
(Prometheus/Grafana), and cataloged in a developer portal (Backstage).

The service itself is intentionally modest in scope. The point of this project is the
platform built around it — every layer here mirrors a real decision a platform
engineering team makes, made deliberately and documented honestly, including the
trade-offs, the bugs found along the way, and the things left out on purpose.

## 2. Architecture

```
Developer
   │
   │ git push
   ▼
feature-flag-service (app repo)
   │
   │ GitHub Actions CI
   │  ├─ test (ephemeral Postgres + Redis, real Alembic migration from empty DB)
   │  └─ build & push image → GHCR (tagged by commit SHA)
   ▼
idp-gitops (env-config repo)
   │  image tag auto-updated by CI on every push to main
   ▼
Argo CD (in-cluster, watching env-config repo)
   │  automated sync + self-heal
   ▼
kind cluster
   ├─ feature-flag namespace
   │    ├─ feature-flag-api (2 replicas, non-root, liveness/readiness probes)
   │    └─ redis (shared cache across replicas)
   ├─ kyverno namespace (disallow-root-containers policy, enforced)
   └─ monitoring namespace (kube-prometheus-stack: Prometheus + Grafana)

Neon (Postgres, provisioned via Terraform) ←── feature-flag-api

Backstage (local) ── catalogs feature-flag-service + its Postgres/Redis dependencies
```

**The loop that matters:** a code change becomes a running, monitored, policy-checked
pod with zero manual `kubectl apply` — Git is the single source of truth end to end.

## 3. Real Engineering Decisions and Trade-Offs

This section is the actual substance of the project — what was decided, why, and what
was learned along the way. Each of these was a real design choice or a real bug found
through verification, not assumed.

### Fail-safe design has three distinct failure modes, handled differently on purpose
- **Flag doesn't exist** → HTTP 200, `enabled: false`, `reason: flag_not_found`. Never
  a 404 — a caller shouldn't have to special-case a missing flag as an error.
- **Redis is down, DB is up** → transparently falls through to Postgres. Never treated
  as a fail-safe trigger, since the DB still has the real answer. Verified against a
  real induced Redis outage, including the harder case (targeted flags, which need a
  DB-backed rule fetch, not just the base flag).
- **DB is also down (or any unhandled exception)** → HTTP 200, `enabled: <default_value>`,
  `reason: evaluation_error_fail_safe`. This endpoint never returns a 5xx under any
  condition — a calling service should never have to handle "the flag service errored"
  as a special case.

### Redis over in-memory caching — a decision made for a reason that only appears once you scale
In-memory caching is fine for one replica. The moment `feature-flag-api` runs as
multiple Kubernetes replicas (Step 10), each pod's own in-memory cache could disagree
with the others after a flag update. Redis gives every replica one shared, consistent
view. This was proven concretely, not just argued: 20 `/evaluate` calls against the
same user/flag, made through Kubernetes' real load-balancing (not port-forward, which
pins to a single pod), returned identical results — and the pod logs confirmed both
replicas actually served requests during the test.

### Neon now, Aurora path documented, not taken
Built and validated entirely on Neon's free tier to keep iteration risk-free. AWS
Aurora PostgreSQL (also free-tier eligible as of March 2026) was evaluated as the
"more literal" AWS-hosted alternative, but Neon's zero-expiry, zero-credit-burn nature
made it the better choice for a project revisited over months. The point: this was a
weighed, explainable trade-off, not a shortcut — and Terraform's provider abstraction
means the actual application code is unaffected by which one is chosen.

### CrashLoopBackOff vs. readiness failure — a real distinction the platform surfaced under test
The plan predicted a broken `DATABASE_URL` would cause a readiness-probe failure
(`0/1 Ready`, still `Running`). What actually happened was `CrashLoopBackOff`. The
reason: the app's own Step 2 startup check (`_assert_db_reachable()`) fails fast and
crashes the process *before* Kubernetes' liveness/readiness probes ever get a chance to
run — the lenient-vs-strict probe threshold split only governs *runtime* DB failures on
an already-started pod, not startup failures. The critical thing proven: during this
failure, Argo CD's rolling update kept the existing healthy pods alive throughout, so
real traffic was never interrupted — the deployment strategy did its job even though
the specific failure mode differed from the prediction.

### The Kyverno policy that didn't actually enforce anything, at first
The first version of the `disallow-root-containers` policy used Kyverno's `=(field)`
optional-match syntax, which meant every condition passed trivially on a pod with no
`securityContext` at all — a bare `nginx` pod would have sailed through, silently
proving nothing. Caught by testing the actual rejection path, not by reading the YAML.
Fixed by requiring the fields strictly rather than optionally. Lesson: a policy that
"applies successfully" and a policy that "actually blocks anything" are different
claims, and only one of them was ever verified.

### The secret-template.yaml GitOps trap
A committed `secret-template.yaml` — meant purely as human-readable reference,
containing only `<REPLACE_ME>` placeholders — was picked up by Argo CD as a real
`kind: Secret` manifest and applied to the cluster, overwriting the actual working
secret with placeholder values and crashing the pods. Argo CD parses any valid
Kubernetes YAML in its watched path by its `kind:` field, regardless of filename intent
or commented-out content. Fixed by renaming the file to `.yaml.example`, removing it
from manifest-shape entirely rather than relying on comments to suppress it. This is a
real, non-obvious GitOps failure mode: reference material and real manifests cannot
safely share a sync path unless the reference material is made structurally
unrecognizable as a resource.

### Measured latency vs. the original "sub-50ms" target
The original spec assumed sub-50ms evaluation latency. Measured reality, once
Prometheus was wired up: **p95 ≈ 0.97s** across 70 real requests, with a uniform
~500–1000ms distribution (not a few slow outliers — every request was slow). Splitting
internal timing showed cache lookups took ~0.6ms while the Postgres fetch took
~750-800ms consistently, including on requests fired in a tight burst with no
warm-up improvement — ruling out both Redis latency and Neon cold-start. The
connection string already uses Neon's pooled endpoint (`-pooler` in the hostname), so
the exact mechanism (TLS renegotiation cost per request vs. a session-lifecycle issue
preventing effective pool reuse) wasn't fully isolated in this pass — but the finding
itself is real and instrumented, not assumed, and it's the actual measured answer to a
requirement that was never previously tested end-to-end. This is arguably the most
valuable single artifact in the project: real data overturning an untested assumption.

## 4. Known Simplifications

| Simplification | Production equivalent |
|---|---|
| Redis: single-replica Deployment, no PV | StatefulSet + PVC + Redis Sentinel/Cluster |
| Secrets: applied imperatively | External Secrets Operator or Sealed Secrets |
| No Ingress | ingress-nginx or cloud load balancer |
| Liveness uses `/health` (DB check) | Separate `/livez` endpoint (process-only check) |
| Kyverno uses deprecated `v1 ClusterPolicy` | Migrate to CEL-based `policies.kyverno.io` API |
| `/metrics` Prometheus endpoint has no auth | Firewalled to cluster-internal traffic via NetworkPolicy |
| Audit log history for deleted flags is 404 | Redundant `name` lookup for historical queries |
| Local Terraform state | Remote backend (S3/GCS with locking) |

> **Note on Kyverno Policy:** The Kyverno policy uses the `kyverno.io/v1 ClusterPolicy` API, which Kyverno has marked deprecated in favor of a CEL-expression-based API (`policies.kyverno.io`). The policy is fully functional as-is; migration was deferred as out of scope for this project's timeline.

> **Note on Kyverno Scope:** The `disallow-root-containers` policy excludes the `monitoring` namespace, since `kube-prometheus-stack`'s admission-webhook Jobs run as root by default. This is a standard exemption pattern for system namespaces.

## 5. Running This Project

- **Local Setup:** Check [Setup](#setup) for local `.env` and `uvicorn` setup.
- **Cluster Deployment:** Check [Step 10 — Kubernetes](#step-10--kubernetes-kind-cluster) for creating the cluster, applying namespaces, and imperatively creating the secrets.
- **GitOps (Argo CD):** Ensure ArgoCD is installed and the `idp-gitops` repo is synced.
- **Port Forwards:**
  - Argo CD UI: `kubectl port-forward svc/argocd-server -n argocd 8080:443`
  - Grafana UI: `kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3001:80`
  - Backstage UI: `yarn start` (on `localhost:3000` in the `idp-portal` directory)
  - API: `kubectl port-forward svc/feature-flag-api -n feature-flag 8000:8000`

---

## 6. Detailed Documentation

## Setup

```bash
cp .env.example .env          # fill in DATABASE_URL and JWT_SECRET_KEY
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
alembic upgrade head           # run DB migrations
uvicorn app.main:app --reload
```

Swagger UI: [http://localhost:8000/docs](http://localhost:8000/docs)

## API Overview

| Method   | Path                     | Auth    | Description                              |
|----------|--------------------------|---------|------------------------------------------|
| `POST`   | `/auth/login`            | —       | Obtain a JWT (Bearer token)              |
| `GET`    | `/health`                | —       | Liveness check                           |
| `POST`   | `/flags`                 | admin   | Create a feature flag                    |
| `GET`    | `/flags`                 | any     | List flags (`?environment=` `?flag_type=`)|
| `GET`    | `/flags/{id}`            | any     | Get a single flag                        |
| `PATCH`  | `/flags/{id}`            | admin   | Partially update a flag                  |
| `DELETE` | `/flags/{id}`            | admin   | Delete a flag                            |
| `GET`    | `/flags/{id}/history`    | any     | Audit history for a flag (newest first)  |
| `POST`   | `/evaluate`              | any     | Evaluate a flag for a user               |
| `GET`    | `/metrics`               | **none**| Prometheus metrics (no auth — see below) |

## Flag Types

| `flag_type`    | `rollout_percentage` | Notes                                         |
| `boolean`      | must be absent       | Simple on/off flag                            |
| `targeted`     | must be absent       | Evaluated against targeting rules             |
| `percentage`   | **required** (0–100) | Deterministic hash-based rollout              |

## Audit Log

Every mutation (`POST`, `PATCH`, `DELETE`) writes an `audit_log` row atomically in the same transaction as the flag change. Each row records:

- `action` — `created`, `updated`, or `deleted`
- `actor` — username of the authenticated user
- `old_value` — JSON snapshot of the flag state before the change (`null` for `created`)
- `new_value` — JSON snapshot after the change (`null` for `deleted`)

## Observability — Prometheus Metrics (`GET /metrics`)

The service exposes four Prometheus metrics at `GET /metrics` in standard text exposition format (consumed directly by a Prometheus scraper):

| Metric | Type | Labels | Operational question answered |
|--------|------|--------|-------------------------------|
| `flag_evaluations_total` | Counter | `reason`, `environment` | Is fail-safe firing? Are callers referencing deleted/misspelled flags? |
| `flag_evaluations_cache_result_total` | Counter | `result` (`hit`\|`miss`\|`redis_unavailable`) | Is the cache layer actually working under real traffic? |
| `flag_evaluation_duration_seconds` | Histogram | _(none)_ | Are we meeting the sub-50ms latency requirement? |
| `flag_mutations_total` | Counter | `action` (`created`\|`updated`\|`deleted`) | How much flag churn is happening? Useful for incident correlation. |

## Error Responses

| Scenario                              | HTTP Status | Notes                                      |
| Missing / invalid JWT                 | 401         | `WWW-Authenticate: Bearer` header included |
| Valid JWT, wrong role                 | 403         | —                                          |
| Resource not found                    | 404         | Message identifies what was missing        |
| Duplicate `(name, environment)` pair  | 409         | DB `IntegrityError` translated, never 500  |
| Pydantic / cross-field validation     | 422         | FastAPI default; validator message included|

## Cascade Behaviour (Step 1 schema)

- `targeting_rules` → `ON DELETE CASCADE`: deleting a flag removes all its targeting rules automatically.
- `audit_log.flag_id` → `ON DELETE SET NULL`: audit history is **preserved** after flag deletion; `flag_id` becomes `NULL`.
- `audit_log.actor` stores the username string (not a FK) so history survives user-account deletion.

## Project Structure

```
feature-flag-service/
├── app/
│   ├── main.py          # App entry point, lifespan, router registration
│   ├── config.py        # Settings (pydantic-settings, .env loading)
│   ├── database.py      # Engine, SessionLocal, Base, get_db dependency
│   ├── models.py        # SQLAlchemy ORM models
│   ├── schemas.py       # Pydantic request/response schemas
│   ├── auth.py          # bcrypt hashing + JWT create/verify
│   ├── audit.py         # Shared audit_log insert helper
│   ├── dependencies.py  # get_current_user, require_admin FastAPI deps
│   └── routers/
│       ├── auth.py      # POST /auth/login
│       ├── health.py    # GET /health
│       └── flags.py     # Flag CRUD + GET /flags/{id}/history
├── k8s/
│   ├── namespace.yaml         # feature-flag namespace
│   ├── secret-template.yaml   # placeholder — real secrets applied imperatively
│   ├── redis-deployment.yaml  # Redis (single replica, no PV)
│   ├── redis-service.yaml     # ClusterIP → redis.feature-flag.svc.cluster.local
│   ├── api-deployment.yaml    # API (replicas:2, SHA-pinned image, probes)
│   └── api-service.yaml       # ClusterIP → feature-flag-api:8000
├── alembic/             # DB migrations
├── tests/
├── .env.example
├── requirements.txt
└── docker-compose.yml
```

## Step 10 — Kubernetes (`kind` cluster)

### Prerequisites

- [`kind`](https://kind.sigs.k8s.io/) and `kubectl` installed
- Docker running
- A GitHub PAT with **`read:packages` scope only** (for GHCR image pull)

### 1. Create the cluster

```bash
kind create cluster --name feature-flag-cluster
kubectl cluster-info --context kind-feature-flag-cluster
```

### 2. Apply the namespace

```bash
kubectl apply -f k8s/namespace.yaml
```

### 3. Create secrets (imperatively — never committed)

```bash
# GHCR image pull credentials (read:packages PAT)
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace feature-flag \
  --docker-server=ghcr.io \
  --docker-username=DSurya11 \
  --docker-password=<YOUR_PAT_read_packages_only> \
  --docker-email=any@email.com

# App credentials
kubectl create secret generic feature-flag-secrets \
  --namespace feature-flag \
  --from-literal=DATABASE_URL='<your-neon-url>' \
  --from-literal=REDIS_URL='redis://redis.feature-flag.svc.cluster.local:6379' \
  --from-literal=JWT_SECRET_KEY='<your-hex-secret>'
```

> **Secrets strategy:** Secrets are applied manually (imperatively) because this project does not yet have Sealed Secrets or External Secrets Operator — both are listed as stretch goals. The imperative approach means the cluster holds real values; Git holds only the placeholder `secret-template.yaml`. ESO/Sealed Secrets would replace this in a more mature setup.

### 4. Deploy Redis and the API

```bash
kubectl apply -f k8s/redis-deployment.yaml
kubectl apply -f k8s/redis-service.yaml
kubectl apply -f k8s/api-deployment.yaml
kubectl apply -f k8s/api-service.yaml
```

### 5. Verify

**All pods running:**
```bash
kubectl get pods -n feature-flag
# Expected: 2 feature-flag-api pods + 1 redis pod, STATUS=Running, READY=1/1
```

**Health check via port-forward (proves DB connectivity from inside the cluster):**
```bash
kubectl port-forward svc/feature-flag-api 8000:8000 -n feature-flag &
curl -s localhost:8000/health | python3 -m json.tool
# Expected: {"status": "ok", "database": "connected"}
kill %1
```

**Multi-replica Redis cache consistency (the flagship test):**

Get a token first:
```bash
kubectl port-forward svc/feature-flag-api 8000:8000 -n feature-flag &
TOKEN=$(curl -s -X POST localhost:8000/auth/login \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=<user>&password=<pass>' | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
kill %1
```

Run 20 `/evaluate` calls from **inside** the cluster so kube-proxy's iptables rules apply (real round-robin, not port-forward's single-pod binding):
```bash
kubectl run curl-test --rm -it \
  --image=curlimages/curl \
  --restart=Never \
  -n feature-flag -- \
  sh -c 'for i in $(seq 1 20); do \
    curl -s -X POST http://feature-flag-api:8000/evaluate \
      -H "Authorization: Bearer '$TOKEN'" \
      -H "Content-Type: application/json" \
      -d "{\"flag_name\":\"<your-flag>\",\"user_id\":\"test-user-123\",\"environment\":\"prod\"}"; \
    echo; done'
```

Check (a) all 20 responses are identical (shared Redis cache hit) and (b) both pods handled requests:
```bash
kubectl logs -l app=feature-flag-api -n feature-flag --all-containers | grep "test-user-123"
# Must show log lines from BOTH pods — otherwise load-balancing didn't occur
```

**Pod self-healing:**
```bash
kubectl delete pod -n feature-flag -l app=feature-flag-api --wait=false
kubectl get pods -n feature-flag -w
# Replacement pods appear within seconds — no manual intervention
```

**Readiness failure without crash loop (broken secret test):**
```bash
kubectl delete secret feature-flag-secrets -n feature-flag
kubectl create secret generic feature-flag-secrets \
  --namespace feature-flag \
  --from-literal=DATABASE_URL='postgresql://invalid:invalid@localhost/bogus' \
  --from-literal=REDIS_URL='redis://redis.feature-flag.svc.cluster.local:6379' \
  --from-literal=JWT_SECRET_KEY='test'
kubectl rollout restart deployment/feature-flag-api -n feature-flag
kubectl get pods -n feature-flag -w
# READY column: 0/1 (readiness probe failing → traffic stopped)
# STATUS:       Running (NOT CrashLoopBackOff — liveness failureThreshold=5 not yet crossed)
# Restore: re-apply the real secret and rollout restart again
```

### Probe design — liveness vs. readiness

Both probes target `GET /health` (returns 503 when DB is unreachable):

| Probe | `failureThreshold` | Effect of failure |
|---|---|---|
| Readiness | 3 (30 s) | Stop routing traffic — DB is down, pod can't serve requests |
| Liveness | 5 (50 s) | Restart pod — more lenient because restarting won't fix an external DB outage |

**Known simplification:** a production setup would have a separate `/livez` endpoint that checks only process health (not DB connectivity) for liveness. The lenient-threshold approach is the honest trade-off for a portfolio project — documented here rather than hidden.

## Step 11 — Terraform

Terraform manages the existing Neon project via `terraform import`, adopting an already-provisioned resource rather than creating a new one — this mirrors real-world 'brownfield' infrastructure adoption. Terraform state is stored locally for this project; a production setup would use a remote backend (e.g. Terraform Cloud or S3 with locking) for team/CI use. Terraform's scope here covers the Neon project itself; a full AWS RDS-based setup would additionally require VPC, subnet, and security-group resources, which are out of scope given the Neon-based architecture chosen in Step 1 for cost reasons.

## Step 13 — GitOps (Argo CD)

Argo CD handles automated synchronization of Kubernetes manifests from the `idp-gitops` repository to the cluster.

- **Automated Sync & Prune:** If a manifest is deleted from Git, the resource is deleted from the cluster.
- **Self-Healing:** Manual drifts (e.g., `kubectl scale deployment ... --replicas=5`) are automatically detected and reverted back to the Git-declared state (e.g., `replicas: 2`).
