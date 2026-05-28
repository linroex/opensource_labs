# hello-world-k3s

Minimal "Hello, World" HTML page served by nginx on a single-node k3s cluster.

## What it deploys

- `Namespace` **hello**
- `ConfigMap` **hello-html** — holds `index.html`
- `Deployment` **hello-web** — 2 nginx replicas, mounts the ConfigMap at `/usr/share/nginx/html`
- `Service` **hello-web** — `NodePort` on `30080`

## Apply

Assumes a k3s cluster is running and `KUBECONFIG` points at it (e.g.
`/etc/rancher/k3s/k3s.yaml`). To bootstrap a single-node cluster from
scratch, use `scripts/k3s-init.sh` at the repo root:

```bash
sudo ../scripts/k3s-init.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

```bash
kubectl apply -f manifests/hello-world.yaml
kubectl -n hello rollout status deploy/hello-web
curl http://127.0.0.1:30080/
```

## Verification

```text
$ curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:30080/
200
```

## Tear down

```bash
kubectl delete -f manifests/hello-world.yaml
```
