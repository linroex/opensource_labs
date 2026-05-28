# EFK on k3s

Single-node EFK (Elasticsearch + Fluentd + Kibana) stack running on a k3s cluster
inside the Claude Code on the web sandbox.

## Layout

```
efk-k3s/
├── manifests/                  # All k8s YAML, applied in numeric order
│   ├── 00-namespace.yaml       # `logging` namespace
│   ├── 10-elasticsearch.yaml   # ES 7.17 single-node StatefulSet (5Gi PVC)
│   ├── 20-kibana.yaml          # Kibana 7.17 + NodePort 30561
│   ├── 30-fluentd-rbac.yaml    # ServiceAccount + ClusterRole(Binding)
│   ├── 31-fluentd-config.yaml  # fluent.conf (CRI parser → ES output)
│   └── 32-fluentd-daemonset.yaml
├── scripts/
│   ├── bootstrap.sh            # k3s + runc-wrapper + manifests in one shot
│   ├── verify.sh               # ES health + per-namespace doc counts
│   └── kibana-port-forward.sh  # tunnel Kibana to localhost:5601
└── results/                    # Captured outputs from the live run
```

## Quick start (in this sandbox)

```bash
./scripts/bootstrap.sh    # ~2 minutes
./scripts/verify.sh       # confirms logs are indexed
```

Open Kibana with either:

```bash
./scripts/kibana-port-forward.sh   # http://localhost:5601
# or hit NodePort directly on the node IP:
kubectl -n logging get svc kibana  # port 30561
```

On first login, create an index pattern `k8s-*` with `@timestamp` as the time field.

## What gets deployed

| Component | Image | Notes |
|---|---|---|
| Elasticsearch | `docker.elastic.co/elasticsearch/elasticsearch:7.17.24` | single-node, security disabled, 1Gi heap, 5Gi PVC on `local-path` |
| Kibana | `docker.elastic.co/kibana/kibana:7.17.24` | NodePort 30561 |
| Fluentd | `fluent/fluentd-kubernetes-daemonset:v1.17.1-debian-elasticsearch7-1.1` | tails `/var/log/containers/*.log` with the **CRI parser** (k3s uses containerd, not docker), enriches with `kubernetes_metadata_filter`, writes to `k8s-YYYY.MM.DD` indices |

The Fluentd ConfigMap (`manifests/31-fluentd-config.yaml`) is the canonical
pipeline definition — env vars passed to the DaemonSet are kept as a backup,
but the mounted `fluent.conf` is what actually runs.

## Sandbox-specific bits

The `bootstrap.sh` script handles two things that don't matter on a normal host:

1. **runc oomScoreAdj wrapper** — this sandbox doesn't grant `CAP_SYS_RESOURCE`,
   so kubelet's `-998` oom adjustment for the pause container makes every pod
   fail to start with `runc create failed: can't get final child's PID from
   pipe: EOF`. The wrapper strips `oomScoreAdj` from `config.json` before
   invoking the real runc.
2. **No systemd** — k3s is launched directly via `nohup` instead of
   `systemctl start k3s`.

## Verified results (see `results/`)

- `pods.txt` — all three pods `Running` and `Ready`
- `es-cluster-health.json` — `status: yellow` (expected for single-node with the
  default replica=1 setting on system indices)
- `es-indices.json` — `k8s-2026.05.28` index created automatically by Fluentd
- `docs-by-namespace.json` — logs from `logging` and `kube-system` both indexed
- `sample-doc.json` — one document showing the full enriched schema
  (`@timestamp`, `message`, `stream`, full `kubernetes.*` block with pod, namespace, labels)

## Cleanup

```bash
kubectl delete -f manifests/ --wait=false
# Or wipe the whole cluster:
/usr/local/bin/k3s-killall.sh
/usr/local/bin/k3s-uninstall.sh
```
