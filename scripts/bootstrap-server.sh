#!/usr/bin/env bash
# Run on the MicroK8s server with: sudo bash scripts/bootstrap-server.sh
# Requires: sudo, network. After this, do the one-time cloudflared steps (see README).
set -e

echo "== Installing MicroK8s..."
snap install microk8s --classic

echo "== Adding current user to microk8s group..."
SUDO_USER=${SUDO_USER:-$USER}
usermod -a -G microk8s "$SUDO_USER" 2>/dev/null || true

echo "== Enabling addons (dns, ingress, hostpath-storage)..."
microk8s enable dns
microk8s enable ingress
microk8s enable hostpath-storage

echo "== Waiting for node ready..."
microk8s kubectl wait --for=condition=Ready nodes --all --timeout=300s 2>/dev/null || true

echo "== Installing ArgoCD (server-side apply to avoid CRD annotation size limit)..."
microk8s kubectl create namespace argocd --dry-run=client -o yaml | microk8s kubectl apply -f -
microk8s kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "== Waiting for ArgoCD server..."
microk8s kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=300s

echo "== Bootstrapping root app (app-of-apps)..."
microk8s kubectl apply -f - <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-apps
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/Jeammm/infra-manifest.git
    path: apps
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
YAML

echo ""
echo "=== Bootstrap done ==="
echo "1. Get ArgoCD admin password:"
echo "   microk8s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
echo ""
echo "2. One-time Cloudflare Tunnel: install cloudflared, run 'cloudflared tunnel login' and 'cloudflared tunnel create jeammm-cluster', then:"
echo "   microk8s kubectl create namespace cloudflare-tunnel"
echo "   microk8s kubectl create secret generic cloudflared-credentials -n cloudflare-tunnel --from-file=credentials.json=\$HOME/.cloudflared/<TUNNEL_ID>.json"
echo ""
echo "3. Log out and back in (or run 'newgrp microk8s') so 'microk8s' works without sudo."
