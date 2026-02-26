# Troubleshooting: argocd.jeammm.com not reachable

Run these on the server (with `microk8s kubectl` or `kubectl`).

## 1. Is the Cloudflare Tunnel pod running?

```bash
kubectl get pods -n cloudflare-tunnel
kubectl logs -n cloudflare-tunnel deployment/cloudflared --tail=50
```

- If the pod is **CrashLoopBackOff** or not running: check logs. Common causes:
  - Missing secret: `kubectl get secret cloudflared-credentials -n cloudflare-tunnel`
  - Wrong tunnel name in config (must match `cloudflared tunnel create <name>`).
- If logs show **"Registered tunnel connection"** or **"Connection registered"**, the tunnel is connected.

## 2. Is the ArgoCD Ingress created?

```bash
kubectl get ingress -n argocd
```

You should see `argocd-server` with host `argocd.jeammm.com`. If not, the `argocd-ingress` Application may not have synced—check ArgoCD UI or:

```bash
kubectl get application -n argocd
kubectl get application argocd-ingress -n argocd -o yaml
```

## 3. Which ingress controller does MicroK8s use?

```bash
kubectl get svc -n ingress
kubectl get svc -n kube-system | grep -E 'traefik|nginx|ingress'
```

- If you see **Traefik** (e.g. `traefik` in `kube-system`): the tunnel must point to that service, and the Ingress must use Traefik’s ingress class.
- If you see **nginx** (e.g. `nginx-ingress-microk8s-controller` in `ingress`): current config is correct.

## 4. Tunnel config must match the ingress controller

The tunnel sends traffic to the **ingress controller service**. If MicroK8s uses **Traefik**:

- In `cluster-config/cloudflare-tunnel/configmap.yaml`, set `service` to:
  `http://traefik.kube-system.svc.cluster.local:80`
- In `cluster-config/argocd-ingress/ingress.yaml`, set `ingressClassName` to `traefik` (or `public` if that’s the default).

Then push and let ArgoCD sync, or apply manually and restart the cloudflared deployment.

## 5. DNS

In Cloudflare DNS, `argocd.jeammm.com` should be:

- Type: **CNAME**
- Target: **`<YOUR_TUNNEL_ID>.cfargotunnel.com`**
- Proxy: **Proxied (orange cloud)**

## 6. Quick test from inside the cluster

```bash
# Replace with your actual ingress controller service if different
kubectl run curl --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}" -H "Host: argocd.jeammm.com" http://nginx-ingress-microk8s-controller.ingress.svc.cluster.local/
```

If you get **200** or **302**, the ingress controller is routing correctly and the problem is likely the tunnel or DNS.
