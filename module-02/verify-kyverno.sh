#!/usr/bin/env bash
set -euo pipefail

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

cleanup() {
  kubectl delete pod test-pod-student -n student01 --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete pod test-pod-ro -n student01 --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete pod test-pod-mentor -n mentor --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete pod test-pod-default -n default --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete ns student99 --ignore-not-found=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=================================================================="
echo " Перевірка Kyverno Policies (Mutate, Validate Audit, Generate RBAC)"
echo "=================================================================="

cleanup

echo ""
echo "--- 1. Тест Mutate Policy (add-person-label): лейбл 'person' ---"
kubectl run test-pod-student -n student01 --image=nginx:alpine --restart=Never >/dev/null
kubectl run test-pod-mentor -n mentor --image=nginx:alpine --restart=Never >/dev/null
kubectl run test-pod-default -n default --image=nginx:alpine --restart=Never >/dev/null

LABEL_STUDENT="$(kubectl get pod test-pod-student -n student01 -o jsonpath='{.metadata.labels.person}')"
LABEL_MENTOR="$(kubectl get pod test-pod-mentor -n mentor -o jsonpath='{.metadata.labels.person}')"
LABEL_DEFAULT="$(kubectl get pod test-pod-default -n default -o jsonpath='{.metadata.labels.person}')"

assert_eq "Pod у student01 має person=student" "$LABEL_STUDENT" "student"
assert_eq "Pod у mentor має person=mentor" "$LABEL_MENTOR" "mentor"
assert_eq "Pod у default НЕ має лейбла person" "$LABEL_DEFAULT" ""

echo ""
echo "--- 2. Тест Validate Policy (require-ro-rootfs): Audit режим ---"
# Тестовий под із readOnlyRootFilesystem: true
cat <<EOF | kubectl apply -n student01 -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-ro
spec:
  containers:
    - name: app
      image: nginx:alpine
      securityContext:
        readOnlyRootFilesystem: true
EOF

# Поди створені успішно (оскільки режим Audit, а не Enforce)
POD_EXISTS="$(kubectl get pod test-pod-student -n student01 -o jsonpath='{.metadata.name}')"
assert_eq "Pod без readOnlyRootFilesystem не заблоковано (Audit mode)" "$POD_EXISTS" "test-pod-student"

echo "    Очікування генерації PolicyReport у student01..."
REPORT_FAIL=""
REPORT_PASS=""
for _ in {1..20}; do
  REPORT_FAIL="$(kubectl get policyreport -n student01 -o jsonpath='{.items[*].results[?(@.policy=="require-ro-rootfs")].result}' 2>/dev/null || true)"
  if [[ "$REPORT_FAIL" == *"fail"* && "$REPORT_FAIL" == *"pass"* ]]; then
    break
  fi
  sleep 2
done

HAS_FAIL="no"
HAS_PASS="no"
[[ "$REPORT_FAIL" == *"fail"* ]] && HAS_FAIL="yes"
[[ "$REPORT_FAIL" == *"pass"* ]] && HAS_PASS="yes"
assert_eq "PolicyReport фіксує 'fail' для test-pod-student (без RO rootfs)" "$HAS_FAIL" "yes"
assert_eq "PolicyReport фіксує 'pass' для test-pod-ro (з RO rootfs)" "$HAS_PASS" "yes"

echo ""
echo "--- 3. Тест Generate Policy (generate-tenant-rbac): динамічний студент student99 ---"
kubectl create ns student99 >/dev/null
kubectl label ns student99 role=student student=student99 >/dev/null

SA_CREATED="no"
RB_STUDENT="no"
RB_MENTOR="no"
for _ in {1..15}; do
  if kubectl get sa student99 -n student99 >/dev/null 2>&1 && \
     kubectl get rolebinding student99-rw-in-student99 -n student99 >/dev/null 2>&1 && \
     kubectl get rolebinding mentor-rw-in-student99 -n student99 >/dev/null 2>&1; then
    SA_CREATED="yes"
    RB_STUDENT="yes"
    RB_MENTOR="yes"
    break
  fi
  sleep 1
done

assert_eq "Kyverno автоматично створив SA student99 у новому ns student99" "$SA_CREATED" "yes"
assert_eq "Kyverno автоматично створив RW RoleBinding для student99" "$RB_STUDENT" "yes"
assert_eq "Kyverno автоматично створив RW RoleBinding для mentor у student99" "$RB_MENTOR" "yes"

echo ""
echo "=================================================================="
echo " Результат Kyverno тестів: Успішно: $PASS | Помилок: $FAIL"
echo "=================================================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
