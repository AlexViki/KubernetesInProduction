#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "==> [1/3] Застосування ArgoCD Applications для Istio (istio-base та istiod)..."
kubectl apply -f "$REPO_ROOT/module-03/argocd/apps/istio-base.yaml"
kubectl apply -f "$REPO_ROOT/module-03/argocd/apps/istiod.yaml"

echo "==> [2/3] Очікування розгортання istiod у неймспейсі istio-system..."
for _ in {1..60}; do
  if kubectl get deploy istiod -n istio-system >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl rollout status deploy/istiod -n istio-system --timeout=180s

echo "==> [3/3] Оновлення чарту lab-tenants (v0.3.0) з політикою inject-istio-sidecar-for-students..."
helm upgrade --install lab-tenants "$SCRIPT_DIR/charts/lab-tenants" -n default --wait

echo ""
echo "==> Статус подів Istio та політик Kyverno:"
kubectl get pods -n istio-system
kubectl get clusterpolicy
