#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [1/4] Встановлення k3s кластера..."
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | sudo sh -s - --write-kubeconfig-mode 644
else
  echo "k3s вже встановлено."
fi

echo "==> [2/4] Налаштування ~/.kube/config для поточного користувача ($USER)..."
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"

if ! grep -q "KUBECONFIG=" "$HOME/.bashrc" 2>/dev/null; then
  echo 'export KUBECONFIG="$HOME/.kube/config"' >> "$HOME/.bashrc"
fi

echo "==> [3/4] Очікування готовності вузла кластера..."
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  sleep 2
done
kubectl get nodes -o wide

echo "==> [4/4] Встановлення Helm, Kyverno та розгортання чарту lab-tenants..."
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | USE_SUDO="false" HELM_INSTALL_DIR="$HOME/.local/bin" bash
fi

helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait --timeout 5m
helm upgrade --install lab-tenants "$SCRIPT_DIR/charts/lab-tenants" -n default --wait

echo ""
echo "==> Поточний список неймспейсів та Kyverno політик:"
kubectl get ns -L role,student
kubectl get clusterpolicy
