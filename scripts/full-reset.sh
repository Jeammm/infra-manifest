#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
step()  { echo -e "\n${BLUE}══════════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════════${NC}\n"; }

echo -e "${RED}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  FULL RESET — this will destroy the entire       ║${NC}"
echo -e "${RED}║  cluster including k3s and all data.             ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
read -rp "Are you sure? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

step "Running teardown"
bash "${SCRIPT_DIR}/teardown.sh" <<< "y"

step "Uninstalling k3s"
if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    /usr/local/bin/k3s-uninstall.sh
    info "k3s uninstalled"
else
    info "k3s uninstall script not found — already removed?"
fi

rm -f "$HOME/.kube/config"

step "Full reset complete"
info "The system is clean. Run install.sh to start fresh."
