#!/usr/bin/env bash
# Lightweight Kubernetes cluster setup: k3s + Helm + ArgoCD on Ubuntu Server
# Domain: jeammm.com | Ingress: Cloudflare Tunnel (no Traefik)

set -euo pipefail

# --- 1. Install k3s (no Traefik; Cloudflare Tunnel will be ingress) ---
echo "Installing k3s (Traefik disabled)..."
curl -sfL https://get.k3s.io | sh -s - server --disable traefik

# Use k3s kubectl
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="${PATH}:/usr/local/bin"

# --- 2. Install Helm (no Snap) ---
echo "Installing Helm..."
if ! command -v helm &>/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version --short

# --- 3. Install ArgoCD (server-side apply to avoid CRD size / field manager errors) ---
echo "Creating argocd namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "Installing ArgoCD manifests (server-side)..."
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s 2>/dev/null || true

echo "Done. Next steps:"
echo "  1. Install Cloudflare Tunnel Ingress Controller (see cloudflare-tunnel-helm.sh)"
echo "  2. sudo kubectl apply -f argocd-ingress.yaml"
echo "  3. Patch argocd-server for --insecure and apply Ingress (see argocd-ingress.yaml)"
echo "  4. Get initial admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"