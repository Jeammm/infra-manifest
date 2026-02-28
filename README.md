# infra-manifest

Control plane repo for the k3s cluster (ArgoCD GitOps). Domain: **jeammm.com**.

## Repo layout

```
infra-manifest/
├── bootstrap/
│   └── root-app.yaml           # Apply once → app-of-apps (syncs apps/)
├── apps/                       # ArgoCD Application definitions (each app = one YAML)
│   ├── cluster.yaml            # Cluster config: ArgoCD Ingress
│   ├── whoami.yaml             # Test app: whoami.jeammm.com
│   └── frontend.yaml           # Your frontend app (edit repo URL and path)
├── manifests/
│   ├── infra/                  # Synced by cluster app
│   │   └── argocd-ingress.yaml
│   └── apps/
│       └── whoami/             # Synced by whoami app
│           ├── namespace.yaml
│           ├── deployment.yaml
│           ├── service.yaml
│           └── ingress.yaml
├── scripts/
│   ├── install.sh
│   ├── cloudflare-tunnel-helm.sh
│   ├── argocd-redirect-fix.sh
│   └── teardown.sh
├── docs/
│   └── DEPLOY-FRONTEND.md      # Production guide: deploy your frontend from its own repo
├── .env.cloudflare.example
├── .gitignore
└── README.md
```

## One-time cluster setup

From the server (or a machine with cluster access):

1. **Install k3s, Helm, ArgoCD**  
   `sudo bash scripts/install.sh`

2. **Cloudflare Tunnel controller** (from repo root; requires `.env.cloudflare`)  
   `sudo bash scripts/cloudflare-tunnel-helm.sh`

3. **ArgoCD behind tunnel (no redirect loop)**  
   `sudo bash scripts/argocd-redirect-fix.sh`

4. **Register this repo as control plane**  
   `kubectl apply -f bootstrap/root-app.yaml`

5. **Admin password**  
   `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`

Then open **https://argocd.jeammm.com**. The **apps** application will sync and create **cluster**, **whoami**, and **frontend** (frontend will error until you add your repo; see below).

---

## Deploying your frontend app (production-style)

You keep your **frontend in its own repo**. This repo only declares an ArgoCD Application that points at your frontend repo.

**Steps:**

1. **In your frontend repo:** add a `deploy/` directory with Kubernetes manifests (Deployment, Service, Ingress). Use `ingressClassName: cloudflare-tunnel` so the tunnel controller creates DNS. Add a Dockerfile and CI (e.g. GitHub Actions) to build and push the image to a registry (GHCR, Docker Hub, etc.).

2. **In this repo:** edit **`apps/frontend.yaml`** — set `source.repoURL` to your frontend repo URL and `source.path` to the directory that contains the manifests (e.g. `deploy`). Commit and push.

3. ArgoCD will sync the **frontend** app and deploy your app; the Cloudflare Tunnel controller will create the hostname you set in your Ingress (e.g. `app.jeammm.com`).

**Full production guide:** [docs/DEPLOY-FRONTEND.md](docs/DEPLOY-FRONTEND.md) — Dockerfile examples, manifest examples, CI workflow, resource limits, probes, and checklist.

---

## Adding more apps

- **App in this repo:** add a directory under `manifests/apps/<name>/` and a new file `apps/<name>.yaml` (Application pointing at this repo, path `manifests/apps/<name>`).
- **App in another repo:** add `apps/<name>.yaml` with `source.repoURL` and `source.path` pointing at that repo. Put Deployment/Service/Ingress in the app repo (e.g. in a `deploy/` or `k8s/` directory).

---

## Teardown (re-run from scratch)

`sudo bash scripts/teardown.sh` — removes ArgoCD and the Cloudflare Tunnel controller (keeps k3s). Then run the setup steps again.
