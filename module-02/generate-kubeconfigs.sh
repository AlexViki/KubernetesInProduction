#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_DIR="$SCRIPT_DIR/kubeconfigs"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

mkdir -p "$KUBECONFIG_DIR"

CLUSTER_NAME="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
SERVER_URL="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

echo "==> Пошук неймспейсів ментора та студентів (за лейблами role in (mentor, student))..."
NAMESPACES="$(kubectl get ns -l 'role in (mentor,student)' -o jsonpath='{.items[*].metadata.name}')"

if [[ -z "$NAMESPACES" ]]; then
  echo "Помилка: не знайдено жодного неймспейсу з лейблом role=mentor або role=student" >&2
  exit 1
fi

for NAMESPACE in $NAMESPACES; do
  USER_NAME="$NAMESPACE"
  SECRET_NAME="${USER_NAME}-token"
  OUT_FILE="$KUBECONFIG_DIR/${USER_NAME}.kubeconfig"

  echo "==> Очікування токена для $USER_NAME у неймспейсі $NAMESPACE..."
  TOKEN=""
  for _ in {1..15}; do
    TOKEN_B64="$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null || true)"
    if [[ -n "$TOKEN_B64" ]]; then
      TOKEN="$(echo "$TOKEN_B64" | base64 -d)"
      break
    fi
    sleep 1
  done

  if [[ -z "$TOKEN" ]]; then
    echo "Помилка: не вдалося отримати токен із секрету $SECRET_NAME" >&2
    exit 1
  fi

  cat > "$OUT_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}
  cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${SERVER_URL}
contexts:
- name: ${USER_NAME}@${CLUSTER_NAME}
  context:
    cluster: ${CLUSTER_NAME}
    namespace: ${NAMESPACE}
    user: ${USER_NAME}
current-context: ${USER_NAME}@${CLUSTER_NAME}
users:
- name: ${USER_NAME}
  user:
    token: ${TOKEN}
EOF

  chmod 600 "$OUT_FILE"
  echo "    Згенеровано: $OUT_FILE"
done

echo ""
echo "==> Усі kubeconfig файли успішно створено у $KUBECONFIG_DIR"
