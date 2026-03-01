#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.cloudflare"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "\n${BLUE}══════════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════════${NC}\n"; }

export KUBECONFIG="${HOME}/.kube/config"

cf_api() {
    local method="$1" endpoint="$2"
    shift 2
    curl -sf -X "$method" \
        "https://api.cloudflare.com/client/v4${endpoint}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "$@"
}

cleanup_cloudflare() {
    if [[ ! -f "$ENV_FILE" ]]; then
        warn "No .env.cloudflare found — skipping Cloudflare cleanup"
        return
    fi

    set -a; source "$ENV_FILE"; set +a

    if [[ -z "${CF_API_TOKEN:-}" || -z "${CF_ACCOUNT_ID:-}" || -z "${CF_TUNNEL_NAME:-}" ]]; then
        warn "Cloudflare env vars incomplete — skipping Cloudflare cleanup"
        return
    fi

    step "Cleaning up Cloudflare resources"

    local existing
    existing=$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${CF_TUNNEL_NAME}&is_deleted=false" 2>/dev/null || echo '{"result":[]}')
    local count
    count=$(echo "$existing" | jq '.result | length')

    if [[ "$count" -gt 0 ]]; then
        local tunnel_id
        tunnel_id=$(echo "$existing" | jq -r '.result[0].id')
        info "Found tunnel: ${CF_TUNNEL_NAME} (${tunnel_id})"

        if [[ -n "${CF_ZONE_ID:-}" ]]; then
            info "Searching for DNS records pointing to this tunnel..."
            local records
            records=$(cf_api GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&content=${tunnel_id}.cfargotunnel.com" 2>/dev/null || echo '{"result":[]}')
            local rec_count
            rec_count=$(echo "$records" | jq '.result | length')

            if [[ "$rec_count" -gt 0 ]]; then
                echo "$records" | jq -r '.result[].name' | while read -r fqdn; do
                    local rec_id
                    rec_id=$(echo "$records" | jq -r --arg n "$fqdn" '.result[] | select(.name == $n) | .id')
                    cf_api DELETE "/zones/${CF_ZONE_ID}/dns_records/${rec_id}" > /dev/null 2>&1 || true
                    info "Deleted DNS: ${fqdn}"
                done
            else
                info "No DNS records found for this tunnel"
            fi
        fi

        info "Cleaning up tunnel connections..."
        cf_api DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/connections" > /dev/null 2>&1 || true

        info "Deleting tunnel: ${CF_TUNNEL_NAME}..."
        cf_api DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}" > /dev/null 2>&1 || true
        info "Tunnel deleted"
    else
        info "No tunnel found — nothing to delete"
    fi
}

cleanup_kubernetes() {
    step "Removing ArgoCD and managed resources"

    info "Deleting root application (cascading delete)..."
    kubectl delete application root -n argocd --cascade=foreground --timeout=120s 2>/dev/null || true

    info "Waiting for applications to terminate..."
    sleep 10

    local remaining
    remaining=$(kubectl get applications -n argocd -o name 2>/dev/null || true)
    if [[ -n "$remaining" ]]; then
        warn "Removing remaining applications..."
        kubectl delete applications --all -n argocd --timeout=60s 2>/dev/null || true
    fi

    info "Removing ArgoCD..."
    kubectl delete namespace argocd --timeout=120s 2>/dev/null || true

    info "Removing app namespaces..."
    for ns in cloudflare-tunnel whoami guestbook; do
        kubectl delete namespace "$ns" --timeout=60s 2>/dev/null || true
    done

    info "Removing Sealed Secrets..."
    helm uninstall sealed-secrets -n kube-system 2>/dev/null || true

    info "Removing CRDs..."
    kubectl get crd -o name 2>/dev/null | grep argoproj | xargs -r kubectl delete 2>/dev/null || true
    kubectl get crd -o name 2>/dev/null | grep bitnami | xargs -r kubectl delete 2>/dev/null || true

    info "Removing cluster-scoped RBAC..."
    kubectl delete clusterrole cloudflare-tunnel-controller 2>/dev/null || true
    kubectl delete clusterrolebinding cloudflare-tunnel-controller 2>/dev/null || true
    kubectl delete ingressclass cloudflare-tunnel 2>/dev/null || true
}

main() {
    echo -e "${YELLOW}This will remove all managed workloads, ArgoCD, and Cloudflare resources.${NC}"
    echo -e "${YELLOW}k3s will remain installed.${NC}"
    read -rp "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0

    cleanup_kubernetes
    cleanup_cloudflare

    step "Teardown complete"
    info "k3s is still running. Use full-reset.sh to also uninstall k3s."
}

main "$@"
