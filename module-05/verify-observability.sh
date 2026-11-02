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
  kubectl delete pod test-ro-audit-pod -n student01 --ignore-not-found=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "======================================================================"
echo " Перевірка Module 05: VictoriaMetrics + Loki + Grafana + Alerts"
echo "======================================================================"

cleanup

echo ""
echo "--- 1. Перевірка компонентів моніторингу та логування у monitoring ---"
for deploy in vmstack-grafana vmstack-kube-state-metrics vmstack-victoria-metrics-operator; do
  READY="$(kubectl get deploy "$deploy" -n monitoring -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  assert_eq "Deployment '$deploy' запущений (readyReplicas=1)" "$READY" "1"
done

VMSINGLE_READY="$(kubectl get pod -n monitoring -l app.kubernetes.io/name=vmsingle -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
assert_eq "VictoriaMetrics Single (vmsingle) Ready=true" "$VMSINGLE_READY" "true"

VMAGENT_READY="$(kubectl get pod -n monitoring -l app.kubernetes.io/name=vmagent -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
assert_eq "VictoriaMetrics Agent (vmagent) Ready=true" "$VMAGENT_READY" "true"

VMALERT_READY="$(kubectl get pod -n monitoring -l app.kubernetes.io/name=vmalert -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
assert_eq "VictoriaMetrics Alert (vmalert) Ready=true" "$VMALERT_READY" "true"

LOKI_READY="$(kubectl get pod loki-0 -n monitoring -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
assert_eq "Grafana Loki (loki-0) Ready=true" "$LOKI_READY" "true"

PROMTAIL_READY="$(kubectl get pod -n monitoring -l app.kubernetes.io/name=promtail -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
assert_eq "Promtail log collector Ready=true" "$PROMTAIL_READY" "true"

echo ""
echo "--- 2. Перевірка ArgoCD Applications (GitOps Sync & Health) ---"
for app in vm-k8s-stack loki-stack observability-config; do
  APP_SYNC="$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")"
  APP_HEALTH="$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")"
  assert_eq "ArgoCD Application '$app' має статус Synced" "$APP_SYNC" "Synced"
  assert_eq "ArgoCD Application '$app' має статус Healthy" "$APP_HEALTH" "Healthy"
done

echo ""
echo "--- 3. Перевірка дашбордів та алярмів через Grafana HTTP API ---"
GRAFANA_IP="$(kubectl get svc vmstack-grafana -n monitoring -o jsonpath='{.spec.clusterIP}')"
LOKI_IP="$(kubectl get svc loki -n monitoring -o jsonpath='{.spec.clusterIP}')"
VMSINGLE_IP="$(kubectl get svc -n monitoring -l app.kubernetes.io/name=vmsingle -o jsonpath='{.items[0].spec.clusterIP}')"

DASH_STUDENTS="$(curl -s "http://admin:admin@${GRAFANA_IP}/api/dashboards/uid/student-namespaces-node-load" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("dashboard",{}).get("uid",""))' 2>/dev/null || echo "")"
assert_eq "Дашборд навантаження студентських неймспейсів у Grafana" "$DASH_STUDENTS" "student-namespaces-node-load"

DASH_AUDIT="$(curl -s "http://admin:admin@${GRAFANA_IP}/api/dashboards/uid/kyverno-ro-rootfs-audit-logs" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("dashboard",{}).get("uid",""))' 2>/dev/null || echo "")"
assert_eq "Дашборд аудиту Read-Only RootFS логів у Grafana" "$DASH_AUDIT" "kyverno-ro-rootfs-audit-logs"

ALERT_UID="$(curl -s "http://admin:admin@${GRAFANA_IP}/api/v1/provisioning/alert-rules/ro-rootfs-audit-log-alert" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("uid",""))' 2>/dev/null || echo "")"
assert_eq "Алярм 'ro-rootfs-audit-log-alert' зареєстровано у Grafana" "$ALERT_UID" "ro-rootfs-audit-log-alert"

VMRULE_EXISTS="$(kubectl get vmrule kyverno-ro-rootfs-audit-violation -n monitoring -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")"
assert_eq "VMRule 'kyverno-ro-rootfs-audit-violation' існує у кластері" "$VMRULE_EXISTS" "kyverno-ro-rootfs-audit-violation"

echo ""
echo "--- 4. End-to-End тест: метрики студентів та алярм по логах RO RootFS ---"
kubectl run test-ro-audit-pod -n student01 --image=nginx:alpine --restart=Never >/dev/null
sleep 6

# Перевіряємо наявність запису в Loki про непроходження аудиту require-ro-rootfs для створеного пода
LOKI_MATCH="no"
for _ in {1..10}; do
  LOKI_RESP="$(curl -sG "http://${LOKI_IP}:3100/loki/api/v1/query_range" \
    --data-urlencode 'query={namespace="kyverno"} |= "require-ro-rootfs" |= "readOnlyRootFilesystem" |= "validation error"' \
    --data-urlencode 'limit=20' || true)"
  if [[ "$LOKI_RESP" == *"test-ro-audit-pod"* ]]; then
    LOKI_MATCH="yes"
    break
  fi
  sleep 2
done
assert_eq "Loki містить лог про непроходження RO RootFS для test-ro-audit-pod" "$LOKI_MATCH" "yes"

# Перевіряємо, що VictoriaMetrics віддає метрики по студентських неймспейсах
VM_METRIC_OK="$(curl -sG "http://${VMSINGLE_IP}:8428/api/v1/query" \
  --data-urlencode 'query=count(kube_namespace_created{namespace=~"student.*"})' \
  | python3 -c 'import sys,json; r=json.load(sys.stdin).get("data",{}).get("result",[]); print("yes" if r and int(r[0]["value"][1])>=3 else "no")' 2>/dev/null || echo "no")"
assert_eq "VictoriaMetrics збирає метрики студентських неймспейсів (>=3)" "$VM_METRIC_OK" "yes"

echo ""
echo "======================================================================"
echo " Результат перевірки Module 05: Успішно: $PASS | Помилок: $FAIL"
echo "======================================================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
