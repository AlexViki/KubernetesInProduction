#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "==> [1/4] Додавання Helm репозиторію ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "==> [2/4] Встановлення ArgoCD у неймспейс argocd..."
helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  --create-namespace \
  -f "$SCRIPT_DIR/argocd/values-argocd.yaml" \
  --wait \
  --timeout 5m

echo "==> [3/4] Перевірка статусу подів ArgoCD..."
kubectl get pods -n argocd

echo "==> [4/4] Застосування GitOps маніфестів ArgoCD (App-of-Apps)..."
kubectl apply -f "$SCRIPT_DIR/argocd/apps/kyverno.yaml"
kubectl apply -f "$SCRIPT_DIR/argocd/apps/lab-tenants.yaml"
kubectl apply -f "$SCRIPT_DIR/argocd/root-app.yaml"

echo ""
ADMIN_PASS="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '<вже видалено>')"
echo "==> ArgoCD успішно встановлено!"
echo "    Логін: admin"
echo "    Початковий пароль: ${ADMIN_PASS}"
echo "    Для доступу до UI: kubectl port-forward svc/argocd-server -n argocd 8080:80"
