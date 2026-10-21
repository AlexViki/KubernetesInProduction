#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_DIR="$SCRIPT_DIR/kubeconfigs"

PASS=0
FAIL=0

check_perm() {
  local user="$1"
  local verb="$2"
  local resource="$3"
  local ns="$4"
  local expected="$5" # yes or no

  local kc="$KUBECONFIG_DIR/${user}.kubeconfig"
  local cmd=(kubectl --kubeconfig="$kc" auth can-i "$verb" "$resource")
  if [[ "$ns" == "CLUSTER" ]]; then
    cmd+=(--all-namespaces)
  elif [[ -n "$ns" ]]; then
    cmd+=(-n "$ns")
  fi

  local actual
  actual="$("${cmd[@]}" 2>/dev/null || true)"

  if [[ "$actual" == "$expected" ]]; then
    printf "  [OK]   %-10s | %-6s %-12s | ns: %-10s -> %s\n" "$user" "$verb" "$resource" "${ns:-cluster}" "$actual"
    PASS=$((PASS + 1))
  else
    printf "  [FAIL] %-10s | %-6s %-12s | ns: %-10s -> отримано '%s', очікувалось '%s'\n" "$user" "$verb" "$resource" "${ns:-cluster}" "$actual" "$expected"
    FAIL=$((FAIL + 1))
  fi
}

echo "=================================================================="
echo " Перевірка RBAC політик для Mentor та Students (01, 02, 03)"
echo "=================================================================="

echo ""
echo "--- 1. Перевірка відсутності прав Cluster Admin ---"
for u in mentor student01 student02 student03; do
  check_perm "$u" "*" "*" "CLUSTER" "no"
  check_perm "$u" "create" "namespaces" "" "no"
  check_perm "$u" "get" "nodes" "" "no"
  check_perm "$u" "get" "pods" "kube-system" "no"
done

echo ""
echo "--- 2. Перевірка прав Ментора (RW у mentor, student01, student02, student03; немає доступу до default) ---"
for ns in mentor student01 student02 student03; do
  check_perm "mentor" "get" "pods" "$ns" "yes"
  check_perm "mentor" "create" "deployments" "$ns" "yes"
  check_perm "mentor" "delete" "pods" "$ns" "yes"
done
check_perm "mentor" "get" "pods" "default" "no"
check_perm "mentor" "create" "rolebindings" "student01" "no"

echo ""
echo "--- 3. Перевірка прав Student 01 (RW тільки у student01) ---"
check_perm "student01" "get" "pods" "student01" "yes"
check_perm "student01" "create" "deployments" "student01" "yes"
check_perm "student01" "delete" "services" "student01" "yes"
for ns in mentor student02 student03 default; do
  check_perm "student01" "get" "pods" "$ns" "no"
  check_perm "student01" "create" "pods" "$ns" "no"
done

echo ""
echo "--- 4. Перевірка прав Student 02 (RW у student02, RO у student01 та default) ---"
# RW in student02
check_perm "student02" "get" "pods" "student02" "yes"
check_perm "student02" "create" "deployments" "student02" "yes"
check_perm "student02" "delete" "pods" "student02" "yes"
# RO in student01
check_perm "student02" "get" "pods" "student01" "yes"
check_perm "student02" "list" "deployments" "student01" "yes"
check_perm "student02" "create" "pods" "student01" "no"
check_perm "student02" "delete" "pods" "student01" "no"
# RO in default
check_perm "student02" "get" "pods" "default" "yes"
check_perm "student02" "list" "services" "default" "yes"
check_perm "student02" "create" "pods" "default" "no"
check_perm "student02" "delete" "pods" "default" "no"
# No access to student03 and mentor
for ns in mentor student03; do
  check_perm "student02" "get" "pods" "$ns" "no"
  check_perm "student02" "create" "pods" "$ns" "no"
done

echo ""
echo "--- 5. Перевірка прав Student 03 (RW тільки у student03) ---"
check_perm "student03" "get" "pods" "student03" "yes"
check_perm "student03" "create" "deployments" "student03" "yes"
check_perm "student03" "delete" "services" "student03" "yes"
for ns in mentor student01 student02 default; do
  check_perm "student03" "get" "pods" "$ns" "no"
  check_perm "student03" "create" "pods" "$ns" "no"
done

echo ""
echo "=================================================================="
echo " Результат: Успішно: $PASS | Помилок: $FAIL"
echo "=================================================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
