# Deploying your frontend app (production-style)

This guide walks you through deploying a **frontend app from its own repository** onto your k3s cluster, with GitOps (ArgoCD) and Cloudflare Tunnel.

## Overview

1. **Frontend repo**: Your app code + Dockerfile + a `deploy/` directory with Kubernetes manifests (Deployment, Service, Ingress).
2. **CI (e.g. GitHub Actions)**: On push to `main`, build the image, push to a container registry (GHCR, Docker Hub, etc.).
3. **Control plane (this repo)**: One ArgoCD Application (`apps/frontend.yaml`) points to your frontend repo and path `deploy/`. ArgoCD syncs that path and deploys the app.
4. **Cloudflare Tunnel**: The Ingress in your app repo uses `ingressClassName: cloudflare-tunnel`, so the controller creates the tunnel route and DNS (e.g. `app.jeammm.com`) automatically.

---

## Step 1: Frontend repo layout

Your frontend repository should look like this (path names are up to you; we use `deploy/` here):

```
my-frontend/
├── src/                 # Your app (React, Next, Vue, etc.)
├── Dockerfile
├── .github/
│   └── workflows/
│       └── build-push.yaml   # CI: build image, push to registry
└── deploy/              # Kubernetes manifests (ArgoCD will sync this path)
    ├── deployment.yaml
    ├── service.yaml
    └── ingress.yaml
```

---

## Step 2: Dockerfile (production-grade)

Use a multi-stage build and a non-root user when possible. Example for a Node/Next.js app:

```dockerfile
# Build stage
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Run stage
FROM node:20-alpine
WORKDIR /app
RUN addgroup -g 1001 -S app && adduser -u 1001 -S app -G app
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
USER 1001
EXPOSE 3000
ENV NODE_ENV=production
CMD ["node", "server.js"]
```

For a static site (e.g. Vite/React build served by nginx):

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html
RUN chown -R nginx:nginx /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

---

## Step 3: Kubernetes manifests in `deploy/`

**deploy/deployment.yaml**

Use your registry and image tag. Prefer a specific tag (e.g. `sha-abc123`) or `main`; avoid `latest` in production if you want reproducible deploys.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: frontend
  labels:
    app: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: frontend
          image: ghcr.io/jeammm/my-frontend:main   # or your registry + tag
          ports:
            - containerPort: 3000
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "256Mi"
              cpu: "500m"
          livenessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
```

**deploy/service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: frontend
spec:
  selector:
    app: frontend
  ports:
    - port: 80
      targetPort: 3000
      name: http
```

**deploy/ingress.yaml**

Replace `app.jeammm.com` with your desired hostname. The Cloudflare Tunnel controller will create the DNS record.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: frontend
  namespace: frontend
spec:
  ingressClassName: cloudflare-tunnel
  rules:
    - host: app.jeammm.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 80
```

**Namespace:** Either add `deploy/namespace.yaml` with `kind: Namespace` and `metadata.name: frontend`, or rely on ArgoCD’s `CreateNamespace=true` (we set that in `apps/frontend.yaml`). Ensure every resource in `deploy/` has `namespace: frontend`.

---

## Step 4: CI – build and push image

Example GitHub Actions (`.github/workflows/build-push.yaml`) for GitHub Container Registry:

```yaml
name: Build and push

on:
  push:
    branches: [main]

env:
  REGISTRY: ghcr.io

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ github.repository_owner }}/my-frontend:main
            ${{ env.REGISTRY }}/${{ github.repository_owner }}/my-frontend:${{ github.sha }}
```

- Replace `my-frontend` with your image name.
- After push to `main`, the image will be at e.g. `ghcr.io/Jeammm/my-frontend:main`.
- If your cluster pulls from GHCR and the repo is private, create a pull secret (e.g. `kubectl create secret docker-registry ghcr-secret --docker-server=ghcr.io ...`) and add `imagePullSecrets` to the Deployment.

---

## Step 5: Register the app in the control plane (this repo)

1. In **infra-manifest**, edit **`apps/frontend.yaml`**:
   - Set `source.repoURL` to your frontend repo (e.g. `https://github.com/Jeammm/my-frontend.git`).
   - Set `source.path` to the directory that contains the manifests (e.g. `deploy`).
   - Set `source.targetRevision` (e.g. `main`).
   - Set `destination.namespace` to `frontend` (must match the namespace in your manifests).

2. Commit and push:

   ```bash
   git add apps/frontend.yaml
   git commit -m "Add frontend app"
   git push origin main
   ```

3. ArgoCD will pick up the new Application (or refresh the existing one) and sync. Your frontend will deploy; the tunnel controller will create DNS for the hostname in your Ingress (e.g. `app.jeammm.com`).

---

## Step 6: Production checklist

| Item | Notes |
|------|--------|
| **Image tag** | Prefer a tag per commit (e.g. `${{ github.sha }}`) or a release tag; update `deploy/deployment.yaml` in CI or use ArgoCD Image Updater. |
| **Secrets** | Never commit secrets. Use Kubernetes Secrets (e.g. created manually or with Sealed Secrets / SOPS) or an external secret manager. |
| **Resource limits** | Set `resources.requests` and `resources.limits` on all workloads (as in the deployment example). |
| **Probes** | Use `livenessProbe` and `readinessProbe` so the cluster can restart or stop sending traffic to bad pods. |
| **Replicas** | For HA, increase `replicas` and ensure your app is stateless or uses shared storage where needed. |
| **Registry auth** | If the image is private, create an `imagePullSecret` in the app namespace and reference it in the Deployment. |

---

## Summary flow

1. **Frontend repo**: App code + Dockerfile + `deploy/` (Deployment, Service, Ingress with `ingressClassName: cloudflare-tunnel`).
2. **CI**: On push to `main`, build image and push to GHCR (or your registry).
3. **infra-manifest**: Add or edit `apps/frontend.yaml` (repo URL, path `deploy`, namespace `frontend`), push to `main`.
4. ArgoCD syncs the frontend app; Cloudflare Tunnel exposes it at the hostname you set in `deploy/ingress.yaml`.

To add more apps (e.g. API, another frontend): duplicate `apps/frontend.yaml` as `apps/other-app.yaml`, point it at the other repo and path, push—the app-of-apps pattern will create the new Application and sync it.
