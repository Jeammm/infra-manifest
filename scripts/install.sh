#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${SCRIPT_DIR}/.env.cloudflare"
SEALED_SECRETS_VERSION="2.18.3"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BLUE}══════════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════════${NC}\n"; }

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) error "Unsupported architecture: $ARCH" ;;
esac

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
    step "Checking prerequisites"
    local missing=()
    for cmd in curl jq openssl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
    fi
    info "All prerequisites satisfied"
}

# ---------------------------------------------------------------------------
# Load environment
# ---------------------------------------------------------------------------
load_env() {
    step "Loading Cloudflare configuration"
    if [[ ! -f "$ENV_FILE" ]]; then
        error "Missing $ENV_FILE — copy .env.cloudflare.example and fill in values"
    fi
    set -a
    source "$ENV_FILE"
    set +a

    local required=(CF_API_TOKEN CF_ACCOUNT_ID CF_TUNNEL_NAME)
    for var in "${required[@]}"; do
        [[ -n "${!var:-}" ]] || error "$var is not set in $ENV_FILE"
    done

    info "Tunnel name: ${CF_TUNNEL_NAME}"
    info "Domain: ${CF_DOMAIN:-<not set>}"
}

# ---------------------------------------------------------------------------
# k3s
# ---------------------------------------------------------------------------
install_k3s() {
    step "Installing k3s"
    if command -v k3s &>/dev/null; then
        info "k3s already installed — skipping"
    else
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -
        info "k3s installed"
    fi

    mkdir -p "$HOME/.kube"
    sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
    sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
    export KUBECONFIG="$HOME/.kube/config"
    info "kubeconfig ready"

    info "Waiting for k3s node to appear..."
    for i in $(seq 1 30); do
        if kubectl get nodes --no-headers 2>/dev/null | grep -q .; then
            break
        fi
        [[ $i -eq 30 ]] && error "Timeout waiting for node to appear"
        sleep 2
    done

    info "Waiting for node to be Ready..."
    kubectl wait --for=condition=Ready node --all --timeout=120s
}

# ---------------------------------------------------------------------------
# Helm
# ---------------------------------------------------------------------------
install_helm() {
    step "Installing Helm"
    if command -v helm &>/dev/null; then
        info "Helm already installed — skipping"
        return
    fi
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    info "Helm installed"
}

# ---------------------------------------------------------------------------
# ArgoCD
# ---------------------------------------------------------------------------
install_argocd() {
    step "Installing ArgoCD"

    if ! kubectl get namespace argocd &>/dev/null; then
        kubectl create namespace argocd
    fi

    # Server-side apply avoids 256KB annotation limit on large CRDs (e.g. applicationsets.argoproj.io)
    kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    info "Waiting for ArgoCD server..."
    kubectl rollout status deployment argocd-server -n argocd --timeout=600s

    info "Configuring ArgoCD for insecure mode (TLS terminated at Cloudflare edge)..."
    if kubectl -n argocd get configmap argocd-cmd-params-cm &>/dev/null; then
        kubectl -n argocd patch configmap argocd-cmd-params-cm \
            --type merge -p '{"data":{"server.insecure":"true"}}'
    else
        kubectl -n argocd create configmap argocd-cmd-params-cm \
            --from-literal=server.insecure=true
    fi

    kubectl -n argocd rollout restart deployment argocd-server
    info "Waiting for ArgoCD server restart (old pod may take a minute to drain)..."
    kubectl rollout status deployment argocd-server -n argocd --timeout=600s
    info "ArgoCD ready"
}

# ---------------------------------------------------------------------------
# Sealed Secrets
# ---------------------------------------------------------------------------
install_sealed_secrets() {
    step "Installing Sealed Secrets"

    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets 2>/dev/null || true
    helm repo update sealed-secrets

    helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
        --namespace kube-system \
        --version "$SEALED_SECRETS_VERSION" \
        --wait --timeout 300s

    info "Waiting for controller..."
    kubectl rollout status deployment sealed-secrets -n kube-system --timeout=300s
    info "Sealed Secrets controller ready"
}

install_kubeseal() {
    step "Installing kubeseal CLI"
    if command -v kubeseal &>/dev/null; then
        info "kubeseal already installed — skipping"
        return
    fi

    local version
    version=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest \
        | jq -r .tag_name | sed 's/^v//')

    local url="https://github.com/bitnami-labs/sealed-secrets/releases/download/v${version}/kubeseal-${version}-linux-${ARCH}.tar.gz"
    info "Downloading kubeseal ${version} (${ARCH})..."

    local tmpdir
    tmpdir=$(mktemp -d)
    curl -sL "$url" | tar xz -C "$tmpdir" kubeseal
    sudo install -m 755 "$tmpdir/kubeseal" /usr/local/bin/kubeseal
    rm -rf "$tmpdir"
    info "kubeseal installed"
}

# ---------------------------------------------------------------------------
# Generate sealed secret for Cloudflare credentials
# ---------------------------------------------------------------------------
generate_sealed_secret() {
    step "Generating sealed secret for Cloudflare credentials"

    kubectl create namespace cloudflare-tunnel --dry-run=client -o yaml | kubectl apply -f -

    info "Sealing Cloudflare API credentials..."
    kubectl create secret generic cloudflare-api \
        --namespace cloudflare-tunnel \
        --from-literal=api-token="${CF_API_TOKEN}" \
        --from-literal=cloudflare-account-id="${CF_ACCOUNT_ID}" \
        --from-literal=cloudflare-tunnel-name="${CF_TUNNEL_NAME}" \
        --dry-run=client -o yaml \
    | kubeseal --format yaml \
        --controller-name sealed-secrets \
        --controller-namespace kube-system \
    > "${REPO_DIR}/manifests/cloudflare-tunnel/sealed-secret.yaml"

    info "Sealed secret written to manifests/cloudflare-tunnel/sealed-secret.yaml"
}

# ---------------------------------------------------------------------------
# Bootstrap ArgoCD root app
# ---------------------------------------------------------------------------
bootstrap_argocd() {
    step "Bootstrapping ArgoCD root application"

    kubectl apply -f "${REPO_DIR}/manifests/cloudflare-tunnel/namespace.yaml"
    kubectl apply -f "${REPO_DIR}/manifests/cloudflare-tunnel/sealed-secret.yaml"

    kubectl apply -f "${REPO_DIR}/bootstrap/root-app.yaml"
    info "Root application applied — ArgoCD will sync all apps"

    info "The ingress controller will automatically:"
    info "  • Create the Cloudflare Tunnel"
    info "  • Register DNS records for each Ingress hostname"
    info "  • Route traffic to the correct services"
}

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
print_summary() {
    step "Installation complete"

    local admin_pass
    admin_pass=$(kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "<not available yet>")

    local domain="${CF_DOMAIN:-yourdomain.com}"

    echo -e "${GREEN}ArgoCD Admin Password:${NC} ${admin_pass}"
    echo ""
    echo -e "${GREEN}Services (once the controller finishes provisioning):${NC}"
    echo -e "  https://argocd.${domain}"
    echo -e "  https://whoami.${domain}"
    echo -e "  https://guestbook.${domain}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Commit the generated sealed secret and push to origin:"
    echo ""
    echo "     git add manifests/cloudflare-tunnel/sealed-secret.yaml"
    echo "     git commit -m 'Add Cloudflare tunnel credentials'"
    echo "     git push origin main"
    echo ""
    echo "  2. The ingress controller will create the tunnel and DNS records"
    echo "     automatically based on the Ingress resources in the repo."
    echo ""
    echo "  3. Access ArgoCD UI at https://argocd.${domain}"
    echo "     Username: admin"
    echo "     Password: ${admin_pass}"
    echo ""
    echo "  4. To add a new service, just create its manifests with an Ingress"
    echo "     resource using ingressClassName: cloudflare-tunnel. The controller"
    echo "     handles DNS and routing automatically."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo -e "${BLUE}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║     Home Lab Control Plane Installer     ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    check_prerequisites
    load_env
    install_k3s
    install_helm
    install_argocd
    install_sealed_secrets
    install_kubeseal
    generate_sealed_secret
    bootstrap_argocd
    print_summary
}

main "$@"
