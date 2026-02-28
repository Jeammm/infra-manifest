# infra-manifest

Control plane repo for the k3s cluster (ArgoCD GitOps). Domain: **jeammm.com**.

## Repo layout

```
infra-manifest/
├── bootstrap/
│   └── root-app.yaml      # Apply once → ArgoCD syncs this repo
├── manifests/             # What ArgoCD syncs (from path: manifests)
│   ├── argocd-ingress.yaml
│   ├── whoami-namespace.yaml
│   ├── whoami-deployment.yaml
│   ├── whoami-service.yaml
│   └── whoami-ingress.yaml
├── install.sh             # One-time: k3s + Helm + ArgoCD
├── cloudflare-tunnel-helm.sh
├── argocd-ingress.yaml    # Legacy/local ref; ArgoCD uses manifests/argocd-ingress.yaml
├── argocd-redirect-fix.sh
├── teardown.sh
└── README.md
```

## Link this repo to ArgoCD (one-time)

1. Push this repo to GitHub (including `bootstrap/` and `manifests/`).
2. From a machine with `kubectl` and access to the cluster:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/Jeammm/infra-manifest/main/bootstrap/root-app.yaml
   ```

   Or from a local clone:

   ```bash
   kubectl apply -f bootstrap/root-app.yaml
   ```

3. In ArgoCD UI (https://argocd.jeammm.com), the **infra-manifest** application appears and syncs from `https://github.com/Jeammm/infra-manifest` (path: `manifests/`). It will create/update the ArgoCD Ingress and the whoami test app.

## Test: whoami

After sync, the controller creates DNS for **whoami.jeammm.com**. Open https://whoami.jeammm.com to see the whoami response (hostname, headers, etc.).

## Adding more apps

Add YAML under `manifests/` (Namespace, Deployment, Service, Ingress with `ingressClassName: cloudflare-tunnel` for public hostnames). Push to `main`; ArgoCD will sync automatically.
