# Deploying your frontend app (production-style)

This guide walks you through deploying a **frontend app from its own repository** onto your k3s cluster, with GitOps (ArgoCD) and Cloudflare Tunnel.

## Overview

1. **Frontend repo**: Your app code + Dockerfile + a `deploy/` directory with Kubernetes manifests (Deployment, Service, Ingress).
2. **CI (e.g. GitHub Actions)**: On push to `main`, build the image, push to a container registry (GHCR, Docker Hub, etc.).
3. **Control plane (this repo)**: One ArgoCD Application (`apps/frontend.yaml`) points to your frontend repo and path `deploy/`. ArgoCD syncs that path and deploys the app.
4. **Cloudflare Tunnel**: The Ingress in your app repo uses `ingressClassName: cloudflare-tunnel`, so the controller creates the tunnel route and DNS automatically.

---

## Step 1: Frontend repo layout

Your frontend repository should look like this:

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
          image: ghcr.io/jeammm/my-frontend:main
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

The ingress controller automatically creates the DNS record and tunnel route for the hostname.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: frontend
  namespace: frontend
spec:
  ingressClassName: cloudflare-tunnel
  rules:
    - host: app.yourdomain.com
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

**Namespace:** Rely on ArgoCD's `CreateNamespace=true` (set in `apps/frontend.yaml`). Ensure every resource in `deploy/` has `namespace: frontend`.

---

## Step 4: CI — build and push image

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
- If the repo is private, create a pull secret and add `imagePullSecrets` to the Deployment.

---

## Step 5: Register the app in the control plane (this repo)

**1. Add `apps/frontend.yaml`:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: frontend
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Jeammm/my-frontend.git
    path: deploy
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: frontend
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**2. Commit and push:**

```bash
git add apps/frontend.yaml
git commit -m "Add frontend app"
git push origin main
```

ArgoCD will pick up the new Application and sync it. The ingress controller will automatically create the DNS record and tunnel route for the hostname in your Ingress. No Cloudflare dashboard configuration needed.

---

## Production checklist

| Item | Notes |
|------|--------|
| **Image tag** | Prefer a tag per commit (e.g. `${{ github.sha }}`) or a release tag; update `deploy/deployment.yaml` in CI or use ArgoCD Image Updater. |
| **Secrets** | Never commit secrets. Use Sealed Secrets (see README.md) or an external secret manager. |
| **Resource limits** | Set `resources.requests` and `resources.limits` on all workloads. |
| **Probes** | Use `livenessProbe` and `readinessProbe` so the cluster can restart or stop sending traffic to bad pods. |
| **Replicas** | For HA, increase `replicas` and ensure your app is stateless or uses shared storage where needed. |
| **Registry auth** | If the image is private, create an `imagePullSecret` in the app namespace and reference it in the Deployment. |
