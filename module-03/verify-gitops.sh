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
    printf "  [OK]   %-65s -> '%s'\n" "$desc" "$actual"
    PASS=$((PASS + 1))
  else
    printf "  [FAIL] %-65s -> отримано '%s', очікувалось '%s'\n" "$desc" "$actual" "$expected"
    FAIL=$((FAIL + 1))
  fi
}

echo "=================================================================="
echo " Перевірка Module 03: ArgoCD GitOps та параметризованого Helm чарту"
echo "=================================================================="

echo ""
echo "--- 1. Перевірка компонентів ArgoCD у кластері ---"
ARGOCD_SERVER_READY="$(kubectl get deploy argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
ARGOCD_REPO_READY="$(kubectl get deploy argocd-repo-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
ARGOCD_APPSET_READY="$(kubectl get deploy argocd-applicationset-controller -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
ARGOCD_CTRL_READY="$(kubectl get sts argocd-application-controller -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"

assert_eq "argocd-server запущений (readyReplicas=1)" "$ARGOCD_SERVER_READY" "1"
assert_eq "argocd-repo-server запущений (readyReplicas=1)" "$ARGOCD_REPO_READY" "1"
assert_eq "argocd-applicationset-controller запущений (readyReplicas=1)" "$ARGOCD_APPSET_READY" "1"
assert_eq "argocd-application-controller запущений (readyReplicas=1)" "$ARGOCD_CTRL_READY" "1"

echo ""
echo "--- 2. Перевірка ArgoCD Applications (App-of-Apps) ---"
for app in platform-root kyverno lab-tenants; do
  APP_EXISTS="$(kubectl get application "$app" -n argocd -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")"
  assert_eq "ArgoCD Application '$app' зареєстровано" "$APP_EXISTS" "$app"
done

KYVERNO_SYNC="$(kubectl get application kyverno -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")"
KYVERNO_HEALTH="$(kubectl get application kyverno -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")"
assert_eq "ArgoCD Application 'kyverno' має статус Synced" "$KYVERNO_SYNC" "Synced"
assert_eq "ArgoCD Application 'kyverno' має статус Healthy" "$KYVERNO_HEALTH" "Healthy"

echo ""
echo "--- 3. Перевірка параметризації Helm чарту політик (helm lint & template) ---"
if helm lint "$SCRIPT_DIR/charts/lab-tenants" >/dev/null 2>&1; then
  LINT_OK="yes"
else
  LINT_OK="no"
fi
assert_eq "Helm lint для charts/lab-tenants проходить без помилок" "$LINT_OK" "yes"

# Перевіряємо, що перевизначення values.yaml коректно змінює поведінку шаблонів політик
CUSTOM_ACTION="$(helm template test-release "$SCRIPT_DIR/charts/lab-tenants" \
  --set kyvernoPolicies.requireReadOnlyRootfs.failureAction=Enforce \
  | grep -A1 "failureAction:" | head -n1 | awk '{print $2}')"
assert_eq "Параметризація failureAction=Enforce через --set працює" "$CUSTOM_ACTION" "Enforce"

CUSTOM_LABEL="$(helm template test-release "$SCRIPT_DIR/charts/lab-tenants" \
  --set kyvernoPolicies.mutatePersonLabel.labelKey=ownerRole \
  | grep 'ownerRole: "mentor"' | wc -l | tr -d ' ')"
assert_eq "Параметризація labelKey=ownerRole через --set працює" "$CUSTOM_LABEL" "1"

echo ""
echo "--- 4. Перевірка розгорнутих політик у кластері ---"
for pol in generate-tenant-rbac require-ro-rootfs add-person-label; do
  POL_READY="$(kubectl get clusterpolicy "$pol" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")"
  POL_CHART="$(kubectl get clusterpolicy "$pol" -o jsonpath='{.metadata.labels.helm\.sh/chart}' 2>/dev/null || echo "")"
  assert_eq "ClusterPolicy '$pol' має стан Ready=True" "$POL_READY" "True"
  assert_eq "ClusterPolicy '$pol' керується чартом lab-tenants-0.2.0" "$POL_CHART" "lab-tenants-0.2.0"
done

echo ""
echo "=================================================================="
echo " Результат перевірки Module 03: Успішно: $PASS | Помилок: $FAIL"
echo "=================================================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
