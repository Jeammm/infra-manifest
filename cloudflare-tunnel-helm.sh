#!/usr/bin/env bash
# Install Cloudflare Tunnel Ingress Controller (strrl/cloudflare-tunnel-ingress-controller)
# Loads credentials from .env.cloudflare (copy from .env.cloudflare.example).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.cloudflare"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — copy .env.cloudflare.example to .env.cloudflare and set your credentials."
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

for var in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: $var is not set in .env.cloudflare"
    exit 1
  fi
done

CLOUDFLARE_TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-k3s-jeammm}"

# Use k3s kubeconfig when KUBECONFIG is unset (e.g. when running with sudo)
if [[ -z "${KUBECONFIG:-}" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

helm repo add strrl.dev https://helm.strrl.dev
helm repo update

helm upgrade --install --wait --timeout 2m \
  cloudflare-tunnel-ingress-controller \
  strrl.dev/cloudflare-tunnel-ingress-controller \
  --namespace cloudflare-tunnel-ingress-controller --create-namespace \
  --set cloudflare.apiToken="${CLOUDFLARE_API_TOKEN}" \
  --set cloudflare.accountId="${CLOUDFLARE_ACCOUNT_ID}" \
  --set cloudflare.tunnelName="${CLOUDFLARE_TUNNEL_NAME}"

# Verify
kubectl get pods -n cloudflare-tunnel-ingress-controller
