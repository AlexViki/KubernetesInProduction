#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf "  [OK]   %-68s -> '%s'\n" "$desc" "$actual"
    PASS=$((PASS + 1))
  else
    printf "  [FAIL] %-68s -> отримано '%s', очікувалось '%s'\n" "$desc" "$actual" "$expected"
    FAIL=$((FAIL + 1))
  fi
}

cleanup() {
  kubectl delete pod test-mesh-student -n student01 --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete pod test-mesh-direct-label -n default --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete pod test-mesh-mentor -n mentor --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete pod test-mesh-default -n default --ignore-not-found=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "======================================================================"
echo " Перевірка Module 04: Istio Service Mesh (Sidecar) + Kyverno Policy"
echo "======================================================================"

cleanup

echo ""
echo "--- 1. Перевірка компонентів Istio Control Plane та ArgoCD Apps ---"
ISTIOD_READY="$(kubectl get deploy istiod -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
assert_eq "istiod контролер запущений у istio-system (readyReplicas=1)" "$ISTIOD_READY" "1"

WEBHOOK_EXISTS="$(kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")"
assert_eq "MutatingWebhookConfiguration 'istio-sidecar-injector' існує" "$WEBHOOK_EXISTS" "istio-sidecar-injector"

REINVOCATION="$(kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o jsonpath='{.webhooks[0].reinvocationPolicy}' 2>/dev/null || echo "")"
assert_eq "istio-sidecar-injector має reinvocationPolicy=IfNeeded" "$REINVOCATION" "IfNeeded"

for app in istio-base istiod; do
  APP_SYNC="$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")"
  APP_HEALTH="$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")"
  assert_eq "ArgoCD Application '$app' має статус Synced" "$APP_SYNC" "Synced"
  assert_eq "ArgoCD Application '$app' має статус Healthy" "$APP_HEALTH" "Healthy"
done

echo ""
echo "--- 2. Перевірка Kyverno ClusterPolicy 'inject-istio-sidecar-for-students' ---"
POL_READY="$(kubectl get clusterpolicy inject-istio-sidecar-for-students -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")"
assert_eq "ClusterPolicy 'inject-istio-sidecar-for-students' має Ready=True" "$POL_READY" "True"

echo ""
echo "--- 3. Тест автоматичної інжекції istio-proxy у поди з person=student ---"
# 3.1. Створення поду в неймспейсі student01 (без жодних лейблів вручну:
#      політика add-person-label ставить person=student,
#      політика inject-istio-sidecar-for-students ставить sidecar.istio.io/inject="true",
#      вебхук Istio інжектить контейнер istio-proxy)
kubectl run test-mesh-student -n student01 --image=nginx:alpine --restart=Never >/dev/null

# 3.2. Створення поду в default із явним лейблом person=student
kubectl run test-mesh-direct-label -n default -l person=student --image=nginx:alpine --restart=Never >/dev/null

# 3.3. Створення поду в неймспейсі mentor (має person=mentor -> БЕЗ istio-proxy)
kubectl run test-mesh-mentor -n mentor --image=nginx:alpine --restart=Never >/dev/null

# 3.4. Створення звичайного поду в default (без лейбла person -> БЕЗ istio-proxy)
kubectl run test-mesh-default -n default --image=nginx:alpine --restart=Never >/dev/null

STUDENT_PERSON_LBL="$(kubectl get pod test-mesh-student -n student01 -o jsonpath='{.metadata.labels.person}')"
STUDENT_INJECT_LBL="$(kubectl get pod test-mesh-student -n student01 -o jsonpath='{.metadata.labels.sidecar\.istio\.io/inject}')"
STUDENT_CONTAINERS="$(kubectl get pod test-mesh-student -n student01 -o jsonpath='{.spec.containers[*].name}')"

assert_eq "Pod у student01 отримав лейбл person=student" "$STUDENT_PERSON_LBL" "student"
assert_eq "Pod у student01 отримав лейбл sidecar.istio.io/inject=true" "$STUDENT_INJECT_LBL" "true"

HAS_ISTIO_STUDENT="no"
[[ "$STUDENT_CONTAINERS" == *"istio-proxy"* ]] && HAS_ISTIO_STUDENT="yes"
assert_eq "Pod у student01 запущено з контейнером istio-proxy ($STUDENT_CONTAINERS)" "$HAS_ISTIO_STUDENT" "yes"

DIRECT_CONTAINERS="$(kubectl get pod test-mesh-direct-label -n default -o jsonpath='{.spec.containers[*].name}')"
HAS_ISTIO_DIRECT="no"
[[ "$DIRECT_CONTAINERS" == *"istio-proxy"* ]] && HAS_ISTIO_DIRECT="yes"
assert_eq "Pod з явним person=student у default має istio-proxy ($DIRECT_CONTAINERS)" "$HAS_ISTIO_DIRECT" "yes"

MENTOR_CONTAINERS="$(kubectl get pod test-mesh-mentor -n mentor -o jsonpath='{.spec.containers[*].name}')"
HAS_ISTIO_MENTOR="no"
[[ "$MENTOR_CONTAINERS" == *"istio-proxy"* ]] && HAS_ISTIO_MENTOR="yes"
assert_eq "Pod у mentor (person=mentor) НЕ має istio-proxy ($MENTOR_CONTAINERS)" "$HAS_ISTIO_MENTOR" "no"

DEFAULT_CONTAINERS="$(kubectl get pod test-mesh-default -n default -o jsonpath='{.spec.containers[*].name}')"
HAS_ISTIO_DEFAULT="no"
[[ "$DEFAULT_CONTAINERS" == *"istio-proxy"* ]] && HAS_ISTIO_DEFAULT="yes"
assert_eq "Pod у default (без person=student) НЕ має istio-proxy ($DEFAULT_CONTAINERS)" "$HAS_ISTIO_DEFAULT" "no"

echo ""
echo "======================================================================"
echo " Результат перевірки Module 04: Успішно: $PASS | Помилок: $FAIL"
echo "======================================================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
