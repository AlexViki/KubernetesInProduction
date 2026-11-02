#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "==> [1/3] Застосування ArgoCD Applications для VictoriaMetrics, Loki та Observability Config..."
kubectl apply -f "$REPO_ROOT/module-03/argocd/apps/vm-k8s-stack.yaml"
kubectl apply -f "$REPO_ROOT/module-03/argocd/apps/loki-stack.yaml"
kubectl apply -f "$REPO_ROOT/module-03/argocd/apps/observability-config.yaml"
kubectl apply -f "$REPO_ROOT/module-03/argocd/root-app.yaml"

echo "==> [2/3] Очікування готовності подів у неймспейсі monitoring..."
for deploy in vmstack-grafana vmstack-kube-state-metrics vmstack-victoria-metrics-operator; do
  kubectl rollout status "deploy/$deploy" -n monitoring --timeout=180s
done
kubectl wait --for=condition=Ready pod -l app=loki -n monitoring --timeout=180s

echo "==> [3/3] Статус подів у monitoring та ArgoCD Applications:"
kubectl get pods -n monitoring
kubectl get applications -n argocd -o wide

echo ""
echo "==> Доступ до Grafana UI:"
echo "    Команда: kubectl port-forward svc/vmstack-grafana -n monitoring 3000:80"
echo "    URL:     http://localhost:3000"
echo "    Логін:   admin"
echo "    Пароль:  admin"
