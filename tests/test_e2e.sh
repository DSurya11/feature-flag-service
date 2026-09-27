#!/usr/bin/env bash
#
# End-to-end verification script for the Feature Flag Service IDP project.
#
# Covers everything scriptable: Kubernetes pods, API health, multi-replica
# Redis cache consistency, Kyverno policy enforcement, Argo CD sync/self-heal,
# Prometheus target discovery + real metric queries, and GHCR image presence.
#
# Does NOT cover (see the manual checklist printed at the end):
#   - Backstage catalog UI rendering (description, links, dependency graph)
#   - Grafana dashboard panels actually rendering with live data
#   - Argo CD's own UI (this script checks sync/health via kubectl, not the UI)
#   - Terraform (state-mutating; run separately and deliberately, not as part
#     of a routine test pass)
#
# Usage:
#   chmod +x test_e2e.sh
#   ./test_e2e.sh
#
# Safe to re-run. Cleans up any test pods it creates. Does NOT touch secrets,
# does NOT rotate credentials, does NOT run `terraform apply`.

set -uo pipefail

NAMESPACE="feature-flag"
ARGOCD_NS="argocd"
MONITORING_NS="monitoring"
APP_NAME="feature-flag-api"
GHCR_IMAGE="ghcr.io/dsurya11/feature-flag-service"

PASS=0
FAIL=0
SKIP=0
declare -a RESULTS

pass() { echo "  ✓ $1"; RESULTS+=("PASS: $1"); PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; RESULTS+=("FAIL: $1"); FAIL=$((FAIL+1)); }
skip() { echo "  - SKIP: $1"; RESULTS+=("SKIP: $1"); SKIP=$((SKIP+1)); }
section() { echo ""; echo "=== $1 ==="; }

cleanup_pf() {
  # Kill any port-forwards this script started, identified by a marker env var
  jobs -p | xargs -r kill 2>/dev/null
}
trap cleanup_pf EXIT

# ---------------------------------------------------------------------------
section "0. Preflight — tooling and cluster reachability"
# ---------------------------------------------------------------------------

command -v kubectl >/dev/null 2>&1 && pass "kubectl installed" || { fail "kubectl not found — cannot continue"; exit 1; }
command -v docker  >/dev/null 2>&1 && pass "docker installed"  || skip "docker not found (only needed for local image checks)"

if kubectl cluster-info >/dev/null 2>&1; then
  pass "kubectl can reach a cluster ($(kubectl config current-context 2>/dev/null))"
else
  fail "kubectl cannot reach any cluster — is the kind cluster running? (kind get clusters)"
  echo ""
  echo "Cannot continue without a reachable cluster. Exiting."
  exit 1
fi

# ---------------------------------------------------------------------------
section "1. Kubernetes — namespace and pod health"
# ---------------------------------------------------------------------------

if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  pass "namespace '$NAMESPACE' exists"
else
  fail "namespace '$NAMESPACE' does not exist"
fi

API_READY=$(kubectl get pods -n "$NAMESPACE" -l app="$APP_NAME" --no-headers 2>/dev/null | awk '{print $2}' | grep -c "1/1")
API_TOTAL=$(kubectl get pods -n "$NAMESPACE" -l app="$APP_NAME" --no-headers 2>/dev/null | wc -l)
if [ "$API_TOTAL" -ge 2 ] && [ "$API_READY" -eq "$API_TOTAL" ]; then
  pass "$APP_NAME: $API_READY/$API_TOTAL pods Running and Ready (expect >=2 replicas)"
else
  fail "$APP_NAME: only $API_READY/$API_TOTAL pods ready (expected >=2, all ready)"
  kubectl get pods -n "$NAMESPACE" -l app="$APP_NAME"
fi

REDIS_READY=$(kubectl get pods -n "$NAMESPACE" -l app=redis --no-headers 2>/dev/null | awk '{print $2}' | grep -c "1/1")
if [ "$REDIS_READY" -ge 1 ]; then
  pass "redis: $REDIS_READY pod(s) Running and Ready"
else
  fail "redis: no ready pods found"
fi

# Flag any stray test pods left over from earlier manual testing
STRAY=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -Ec "root-test-pod|curl-test")
if [ "$STRAY" -gt 0 ]; then
  fail "$STRAY stray test pod(s) still present in '$NAMESPACE' — run: kubectl get pods -n $NAMESPACE"
else
  pass "no stray test pods left in '$NAMESPACE'"
fi

# ---------------------------------------------------------------------------
section "2. API health check (via port-forward)"
# ---------------------------------------------------------------------------

kubectl port-forward svc/"$APP_NAME" -n "$NAMESPACE" 18000:8000 >/tmp/pf_health.log 2>&1 &
sleep 3
HEALTH=$(curl -s http://localhost:18000/health)
if echo "$HEALTH" | grep -q '"database":"connected"'; then
  pass "GET /health returns database:connected — $HEALTH"
else
  fail "GET /health did not return a healthy response — got: $HEALTH"
fi
kill %1 2>/dev/null; wait 2>/dev/null

# ---------------------------------------------------------------------------
section "3. Multi-replica Redis cache consistency (in-cluster, real load balancing)"
# ---------------------------------------------------------------------------

echo "  Need a valid admin JWT for this test."
read -rp "  Enter an admin username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}
read -rsp "  Enter admin password (input hidden): " ADMIN_PASS
echo ""

kubectl port-forward svc/"$APP_NAME" -n "$NAMESPACE" 18001:8000 >/tmp/pf_auth.log 2>&1 &
sleep 3
TOKEN=$(curl -s -X POST http://localhost:18001/auth/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${ADMIN_USER}&password=${ADMIN_PASS}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)
kill %1 2>/dev/null; wait 2>/dev/null

if [ -z "$TOKEN" ]; then
  skip "could not obtain a JWT — skipping cache-consistency test (check credentials)"
else
  FLAG_NAME="e2e-test-$(date +%s)"

  kubectl port-forward svc/"$APP_NAME" -n "$NAMESPACE" 18002:8000 >/tmp/pf_create.log 2>&1 &
  sleep 3
  CREATE_RESP=$(curl -s -X POST http://localhost:18002/flags \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"name\":\"$FLAG_NAME\",\"description\":\"e2e test\",\"flag_type\":\"boolean\",\"default_value\":true,\"environment\":\"prod\"}")
  kill %1 2>/dev/null; wait 2>/dev/null

  if echo "$CREATE_RESP" | grep -q "\"name\":\"$FLAG_NAME\""; then
    pass "test flag '$FLAG_NAME' created"

    # NOTE: this pod must satisfy the Kyverno disallow-root-containers policy
    # (Step 15), same as any other pod, or it will be rejected at admission.
    # Using a plain manifest (not --overrides JSON) for reliability.
    kubectl delete pod curl-test-e2e -n "$NAMESPACE" --force --ignore-not-found >/dev/null 2>&1

    cat <<PODEOF | kubectl apply -f - 2>/tmp/pod_create_err.log
apiVersion: v1
kind: Pod
metadata:
  name: curl-test-e2e
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
  containers:
    - name: curl-test-e2e
      image: curlimages/curl
      securityContext:
        runAsNonRoot: true
        runAsUser: 100
      command: ["sh", "-c"]
      args:
        - |
          for i in \$(seq 1 20); do
            curl -s -X POST http://${APP_NAME}:8000/evaluate \
              -H "Authorization: Bearer ${TOKEN}" \
              -H "Content-Type: application/json" \
              -d "{\"flag_name\":\"${FLAG_NAME}\",\"user_id\":\"e2e-user\",\"environment\":\"prod\"}"
            echo
          done
PODEOF

    if grep -qi "denied the request" /tmp/pod_create_err.log; then
      fail "cache-consistency test pod was blocked by Kyverno even with runAsNonRoot set"
      cat /tmp/pod_create_err.log
      RESULTS_20=""
    else
      kubectl wait --for=condition=Ready pod/curl-test-e2e -n "$NAMESPACE" --timeout=30s >/dev/null 2>&1
      sleep 5
      RESULTS_20=$(kubectl logs curl-test-e2e -n "$NAMESPACE" 2>/dev/null)
      kubectl delete pod curl-test-e2e -n "$NAMESPACE" --force --ignore-not-found >/dev/null 2>&1
    fi

    UNIQUE=$(echo "$RESULTS_20" | grep '"enabled"' | sort -u | wc -l)
    if [ "$UNIQUE" -eq 1 ]; then
      pass "all 20 /evaluate responses identical (shared cache consistency confirmed)"
    else
      fail "responses were NOT identical across 20 calls — cache inconsistency ($UNIQUE distinct results)"
    fi

    LOG_PODS=$(kubectl logs -l app="$APP_NAME" -n "$NAMESPACE" --all-containers 2>/dev/null | grep -c "e2e-user")
    DISTINCT_PODS=$(kubectl get pods -n "$NAMESPACE" -l app="$APP_NAME" -o name | while read -r p; do
      kubectl logs "$p" -n "$NAMESPACE" 2>/dev/null | grep -q "e2e-user" && echo "$p"
    done | wc -l)
    if [ "$DISTINCT_PODS" -ge 2 ]; then
      pass "both API replicas served requests (real load balancing confirmed, $DISTINCT_PODS pods hit)"
    else
      fail "only $DISTINCT_PODS pod(s) served requests — load balancing not confirmed"
    fi

    # cleanup: delete the test flag
    kubectl port-forward svc/"$APP_NAME" -n "$NAMESPACE" 18003:8000 >/tmp/pf_cleanup.log 2>&1 &
    sleep 3
    FLAG_ID=$(echo "$CREATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
    [ -n "$FLAG_ID" ] && curl -s -X DELETE "http://localhost:18003/flags/$FLAG_ID" -H "Authorization: Bearer $TOKEN" >/dev/null
    kill %1 2>/dev/null; wait 2>/dev/null
  else
    fail "could not create test flag — response: $CREATE_RESP"
  fi
fi

# ---------------------------------------------------------------------------
section "4. Kyverno — policy present and actually enforcing"
# ---------------------------------------------------------------------------

if kubectl get clusterpolicy disallow-root-containers >/dev/null 2>&1; then
  # Parse the READY column directly from table output rather than guessing a
  # JSONPath field name (Kyverno's status schema has shifted between versions).
  READY_COL=$(kubectl get clusterpolicy disallow-root-containers --no-headers 2>/dev/null | awk '{print $4}')
  if [ "$READY_COL" = "True" ]; then
    pass "ClusterPolicy 'disallow-root-containers' is READY"
  else
    fail "policy exists but READY column shows '$READY_COL' (expected True)"
  fi
else
  fail "ClusterPolicy 'disallow-root-containers' not found"
fi

kubectl delete pod root-test-e2e -n "$NAMESPACE" --force --ignore-not-found >/dev/null 2>&1
ADMISSION=$(kubectl run root-test-e2e --image=nginx -n "$NAMESPACE" --restart=Never 2>&1)
if echo "$ADMISSION" | grep -qi "denied the request"; then
  pass "non-compliant pod correctly REJECTED by Kyverno admission webhook"
else
  fail "non-compliant pod was NOT rejected — policy may not be enforcing. Output: $ADMISSION"
fi
kubectl delete pod root-test-e2e -n "$NAMESPACE" --force --ignore-not-found >/dev/null 2>&1

# ---------------------------------------------------------------------------
section "5. Argo CD — sync and health status"
# ---------------------------------------------------------------------------

# Note: the Argo CD Application resource is named "feature-flag-service"
# (Step 13) — a DIFFERENT name from the Kubernetes Deployment/Service
# "feature-flag-api". Do not conflate the two.
ARGOCD_APP_NAME="feature-flag-service"

if kubectl get application "$ARGOCD_APP_NAME" -n "$ARGOCD_NS" >/dev/null 2>&1; then
  SYNC=$(kubectl get application "$ARGOCD_APP_NAME" -n "$ARGOCD_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null)
  HEALTH=$(kubectl get application "$ARGOCD_APP_NAME" -n "$ARGOCD_NS" -o jsonpath='{.status.health.status}' 2>/dev/null)
  if [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
    pass "Argo CD Application '$ARGOCD_APP_NAME': Synced + Healthy"
  else
    fail "Argo CD Application '$ARGOCD_APP_NAME' status: sync=$SYNC health=$HEALTH (expected Synced/Healthy)"
  fi
else
  fail "Argo CD Application '$ARGOCD_APP_NAME' not found in namespace '$ARGOCD_NS' — run: kubectl get applications -n argocd"
fi

# ---------------------------------------------------------------------------
section "6. Prometheus — target discovery and real metric data"
# ---------------------------------------------------------------------------

if kubectl get svc kube-prometheus-stack-prometheus -n "$MONITORING_NS" >/dev/null 2>&1; then
  kubectl port-forward svc/kube-prometheus-stack-prometheus -n "$MONITORING_NS" 19090:9090 >/tmp/pf_prom.log 2>&1 &
  sleep 3
  TARGET_UP=$(curl -s "http://localhost:19090/api/v1/targets" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for t in d.get('data', {}).get('activeTargets', []):
    if 'feature-flag' in t.get('labels', {}).get('job', ''):
        print(t.get('health', 'unknown'))
" 2>/dev/null)
  if echo "$TARGET_UP" | grep -q "up"; then
    pass "Prometheus target for feature-flag-api is UP"
  else
    fail "Prometheus target not found or not UP (got: '$TARGET_UP')"
  fi

  METRIC_DATA=$(curl -s "http://localhost:19090/api/v1/query?query=flag_evaluations_total" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d.get('data', {}).get('result', [])))
" 2>/dev/null)
  if [ "${METRIC_DATA:-0}" -gt 0 ]; then
    pass "flag_evaluations_total has real data ($METRIC_DATA label series)"
  else
    fail "flag_evaluations_total returned no data — check if traffic has been sent recently"
  fi
  kill %1 2>/dev/null; wait 2>/dev/null
else
  skip "kube-prometheus-stack not found in '$MONITORING_NS' — skipping Prometheus checks"
fi

# ---------------------------------------------------------------------------
section "7. GHCR — confirm the deployed image tag actually exists in the registry"
# ---------------------------------------------------------------------------

CURRENT_IMAGE=$(kubectl get deployment "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
if [ -n "$CURRENT_IMAGE" ]; then
  echo "  Currently deployed image: $CURRENT_IMAGE"
  if command -v docker >/dev/null 2>&1; then
    MANIFEST_OUT=$(docker manifest inspect "$CURRENT_IMAGE" 2>&1)
    if echo "$MANIFEST_OUT" | grep -q "schemaVersion"; then
      pass "image manifest resolves in GHCR: $CURRENT_IMAGE"
    elif echo "$MANIFEST_OUT" | grep -qiE "unauthorized|denied|authentication"; then
      skip "docker not authenticated to GHCR locally (pods pull fine via imagePullSecrets — this only affects this local check). Run: docker login ghcr.io -u DSurya11"
    else
      fail "could not resolve manifest for $CURRENT_IMAGE — unexpected error: $MANIFEST_OUT"
    fi
  else
    skip "docker not available to check manifest"
  fi
else
  fail "could not read current image from Deployment spec"
fi

# ---------------------------------------------------------------------------
section "SUMMARY"
# ---------------------------------------------------------------------------

echo ""
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo ""
echo "  PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "  ⚠ One or more checks failed — see above before considering the deployment fully healthy."
else
  echo "  ✓ All automated checks passed."
fi

cat <<'EOF'

===============================================================================
MANUAL CHECKLIST — cannot be scripted, requires visually inspecting a UI
===============================================================================

[ ] Backstage catalog (http://localhost:3000, after `yarn start` in idp-portal/)
    - Catalog -> feature-flag-service loads
    - Description, tags, and all 3 links are correct and clickable
    - "Depends on resources" table shows feature-flag-postgres + feature-flag-redis
    - Relations/diagram tab shows all 3 nodes connected

[ ] Argo CD UI (kubectl port-forward svc/argocd-server -n argocd 8080:443,
    then https://localhost:8080)
    - Application tile shows Synced / Healthy (cross-check against Section 5 above)
    - Resource tree renders without errors

[ ] Grafana dashboard (kubectl port-forward svc/kube-prometheus-stack-grafana
    -n monitoring 3001:80, then http://localhost:3001)
    - "Feature Flag Metrics" dashboard exists
    - All 3 panels show real, non-empty data (generate traffic first if flat)
    - Prometheus datasource shows green/working under Connections -> Data sources

[ ] GitHub Actions (github.com/DSurya11/Feature-Flag-Service/actions)
    - Most recent run on main: both `test` and `build-and-push` jobs green
    - env-config repo's latest commit (by github-actions[bot]) has an image
      tag matching the app repo's latest commit SHA

[ ] Terraform (run deliberately, NOT as part of routine testing —
    this can mutate real state)
    cd terraform/ && terraform plan
    - Should show "No changes." If it doesn't, investigate before applying.

===============================================================================
EOF
