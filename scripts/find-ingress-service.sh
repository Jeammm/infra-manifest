#!/usr/bin/env bash
# Run on the MicroK8s server. Finds the ingress controller service for the tunnel config.
# Usage: bash scripts/find-ingress-service.sh
set -e

echo "=== MicroK8s addons (check if ingress is enabled) ==="
microk8s status 2>/dev/null || true

echo ""
echo "=== All services (look for ingress/nginx/traefik) ==="
microk8s kubectl get svc -A 2>/dev/null | grep -E 'ingress|nginx|traefik|NAMESPACE' || microk8s kubectl get svc -A

echo ""
echo "=== All pods (look for ingress controller) ==="
microk8s kubectl get pods -A 2>/dev/null | grep -E 'ingress|nginx|traefik' || echo "No matching pods"

echo ""
echo "If no Service appears above but the nginx pod exists: this repo adds a ClusterIP Service"
echo "via the ingress-controller-service app. Sync that app, then the tunnel can reach:"
echo "  http://nginx-ingress-microk8s-controller.ingress.svc.cluster.local:80"
