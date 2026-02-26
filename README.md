# Control plane repo (GitOps)

This repo is the **control plane** for a MicroK8s cluster: ArgoCD Applications (app-of-apps) and cluster config (Cloudflare Tunnel, ingress). Domain: **jeammm.com**.

## Repo layout

```
infra-manifest/
├── bootstrap/
│   └── root-app.yaml       # Apply once to bootstrap app-of-apps
├── apps/                   # ArgoCD Application manifests (children)
│   ├── argocd-ingress.yaml
│   ├── cloudflare-tunnel.yaml
│   └── whoami.yaml
├── cluster-config/
│   ├── argocd-ingress/     # Ingress for ArgoCD UI
│   ├── cloudflare-tunnel/  # Tunnel Deployment + ConfigMap
│   └── sample-apps/
│       └── whoami/         # Example app (same repo)
└── README.md
```

---

## 1. What to install on the server

| Component | Purpose |
|-----------|---------|
| **MicroK8s** | Kubernetes cluster: `sudo snap install microk8s --classic` |
| **cloudflared** | **One-time**: generate tunnel credentials. Install e.g. `sudo snap install cloudflared`. After creating the tunnel and storing the JSON in a K8s Secret, the tunnel runs in-cluster; you can uninstall cloudflared from the host if you want. |

Optional: `kubectl` (MicroK8s provides `microk8s kubectl`).

---

## 2. Server setup (MicroK8s)

```bash
# Install and access
sudo snap install microk8s --classic
sudo usermod -a -G microk8s $USER
# Log out and back in (or: newgrp microk8s)

# Addons
microk8s enable dns
microk8s enable ingress
microk8s enable hostpath-storage

# Use kubectl
microk8s kubectl get nodes
# Or: microk8s config > ~/.kube/config  then use kubectl
```

---

## 3. One-time Cloudflare Tunnel credentials

Run on the server (or any machine with browser for Cloudflare login):

```bash
# Install
sudo snap install cloudflared

# Login (opens browser)
cloudflared tunnel login

# Create tunnel (name must match config: jeammm-cluster)
cloudflared tunnel create jeammm-cluster

# Credentials file: ~/.cloudflared/<TUNNEL_ID>.json
# Optional: route DNS
cloudflared tunnel route dns jeammm-cluster argocd.jeammm.com
cloudflared tunnel route dns jeammm-cluster whoami.jeammm.com
```

Create the Kubernetes Secret (replace `<TUNNEL_ID>` with the actual ID from the filename):

```bash
microk8s kubectl create namespace cloudflare-tunnel
microk8s kubectl create secret generic cloudflared-credentials -n cloudflare-tunnel \
  --from-file=credentials.json=$HOME/.cloudflared/<TUNNEL_ID>.json
```

In Cloudflare DNS, ensure `argocd.jeammm.com` and `whoami.jeammm.com` are CNAME to `<TUNNEL_ID>.cfargotunnel.com` (proxy on).

---

## 4. ArgoCD install and bootstrap

**Option A – one script (run on server with sudo):**

```bash
cd /path/to/infra-manifest
sudo bash scripts/bootstrap-server.sh
```

**Option B – manual steps:**

```bash
# Install ArgoCD (server-side apply avoids ApplicationSet CRD "annotations too long" error)
microk8s kubectl create namespace argocd
microk8s kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait until argocd-server is ready
microk8s kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=300s

# Bootstrap app-of-apps (from this repo)
microk8s kubectl apply -f https://raw.githubusercontent.com/Jeammm/infra-manifest/main/bootstrap/root-app.yaml
# Or from a local clone:
# microk8s kubectl apply -f bootstrap/root-app.yaml
```

Get initial admin password:

```bash
microk8s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

ArgoCD will sync the root app and then all apps in `apps/`. Open https://argocd.jeammm.com (after tunnel is running).

---

## 5. Git setup for this repo (control plane)

- **Remote**: `https://github.com/Jeammm/infra-manifest.git` (already set in `.git/config`).
- **Workflow**: Edit locally, push to `main`; ArgoCD syncs from `main`.

```bash
cd /path/to/infra-manifest
git add .
git commit -m "Control plane: bootstrap, apps, cloudflare-tunnel, whoami"
git push origin main
```

To add a new app: add a YAML under `apps/` (e.g. `apps/my-app.yaml`) pointing to a path in this repo or to another repo, then push.

---

## 6. Git setup for a separate application repo (example)

To deploy an app from a **different repo** (e.g. `my-app-deploy`):

**6.1 Create the application repo**

```bash
mkdir my-app-deploy && cd my-app-deploy
git init
```

Layout example:

```
my-app-deploy/
├── base/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
└── kustomization.yaml   # or plain YAML in base/
```

**6.2 Add an Application in the control plane repo**

Create `infra-manifest/apps/my-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Jeammm/my-app-deploy.git
    path: base
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Push the control plane repo; ArgoCD will create the `my-app` Application and sync `my-app-deploy`. Add a hostname in `cluster-config/cloudflare-tunnel/configmap.yaml` and in Cloudflare DNS if the app should be public.

---

## 7. Tunnel config

- **Config**: `cluster-config/cloudflare-tunnel/configmap.yaml`. Edit `ingress` to add/change hostnames; keep `tunnel: jeammm-cluster` and `credentials-file` path as-is.
- **Secret**: Created manually (step 3). Credentials are mounted with `subPath: credentials.json` so the config directory is not overwritten.

---

## 8. Troubleshooting

- **Error 1033**: Tunnel not connected. Check pod logs: `microk8s kubectl logs -n cloudflare-tunnel deployment/cloudflared`. Ensure Secret exists and tunnel name in config matches `cloudflared tunnel create` name.
- **Kubelet certificate / TLS on logs**: If node IP changed, you may see certificate errors when fetching logs. Run the logs command on the node, or regenerate the kubelet certificate (MicroK8s docs).
- **ArgoCD sync**: In UI, check Application sync status and events. Ensure repo URL and path are correct and the destination namespace exists (or is created by the app manifests).
