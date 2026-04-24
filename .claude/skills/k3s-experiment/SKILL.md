---
name: k3s-experiment
description: Stand up a single-node k3s cluster in this sandboxed VM and run Kubernetes experiments (operators, outage simulations, empirical behavior tests). Use when the user asks to "用 k3s 做實驗" / "run k3s" / "test a K8s operator" / "simulate pod crash" / "verify K8s behavior" in this environment. Contains the oom_score_adj runc wrapper fix that is REQUIRED for pods to start in this sandbox.
---

# k3s Experiment Harness

This sandbox is **not a normal Linux host**. Several things that "just work" elsewhere fail here. This skill captures the minimum viable recipe plus the non-obvious fixes.

## Environment Quirks (verified on Ubuntu 24.04 with `uname -r` 6.18.x)

| Fact | Impact |
|---|---|
| PID 1 is `process_api`, not systemd | `systemctl` does not work. Install k3s with `INSTALL_K3S_SKIP_ENABLE=true INSTALL_K3S_SKIP_START=true` and run `k3s server` via `nohup`. |
| `/lib/modules/$(uname -r)` missing | `modprobe` fails. Run `mkdir -p /lib/modules/$(uname -r)` to silence warnings. Needed kernel features (`br_netfilter`, `overlay`, `nf_conntrack`, bridging) are built-in. |
| `CAP_SYS_RESOURCE` is **not** in our capability set | Cannot write negative `oom_score_adj`. **Every k8s pod fails to start** because kubelet sets `oomScoreAdj=-998` on the pause container. Error looks like `runc create failed: can't get final child's PID from pipe: EOF`. **Fix: install the runc wrapper (below).** |
| Docker daemon is NOT running | Do not try kind/k3d unless you start `dockerd` manually. Use native k3s — it bundles containerd. |
| `ip` binary missing by default | `apt-get install iproute2`. |
| `bridge-nf-call-iptables` already `1` | Nothing to do. |
| Docker Hub and `registry.k8s.io` return transient **HTTP 503s** | Wrap every `crictl pull` / `curl`-of-release-artifact in a retry loop. |
| `$!` in `nohup cmd &` inside Claude Code's Bash tool captures the **wrapper shell**, not the real child | Always recover the real PID with `pgrep -f <pattern> \| head -1`. |
| Bash tool blocks long leading `sleep` | Don't do `sleep 600 && cmd`. Use Monitor with `until` loop, or run the sleeper as a detached `nohup` script, or use `run_in_background: true`. |

## Minimum Viable Cluster (≈5 minutes)

### 1. Prereqs

```bash
mkdir -p /lib/modules/$(uname -r)
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  iproute2 iptables conntrack ebtables socat curl jq unzip ca-certificates

# kubectl (retry — may 503)
for i in 1 2 3 4; do curl -fsSL --retry 3 -o /usr/local/bin/kubectl \
  https://dl.k8s.io/release/v1.30.5/bin/linux/amd64/kubectl && break; sleep $((i*2)); done
chmod +x /usr/local/bin/kubectl

# helm
curl -fsSL --retry 3 https://get.helm.sh/helm-v3.15.4-linux-amd64.tar.gz | tar -xz -C /tmp
install -m0755 /tmp/linux-amd64/helm /usr/local/bin/helm

# k3s binary only
curl -fsSL --retry 3 https://get.k3s.io -o /tmp/k3s-install.sh
INSTALL_K3S_SKIP_ENABLE=true INSTALL_K3S_SKIP_START=true \
  INSTALL_K3S_VERSION=v1.30.5+k3s1 sh /tmp/k3s-install.sh
```

### 2. Install the runc wrapper (CRITICAL — do this BEFORE starting k3s, or immediately after and then force-recreate pods)

```bash
# Find k3s's bundled runc
K3S_RUNC=$(find /var/lib/rancher/k3s/data -name runc -type f | head -1)
[ -z "$K3S_RUNC" ] && { echo "k3s not installed yet"; exit 1; }

mv "$K3S_RUNC" "${K3S_RUNC}.real"
cat > "$K3S_RUNC" <<WRAPPER
#!/bin/bash
# Strip oomScoreAdj from config.json on create/run — sandbox lacks CAP_SYS_RESOURCE
for arg in "\$@"; do
  case "\$arg" in create|run|exec)
    prev=""
    for i in "\$@"; do
      if [ "\$prev" = "--bundle" ] || [ "\$prev" = "-b" ]; then
        if [ -f "\$i/config.json" ]; then
          tmp=\$(mktemp)
          jq 'if .process.oomScoreAdj != null then .process.oomScoreAdj = 0 else . end' \
            "\$i/config.json" > "\$tmp" && mv "\$tmp" "\$i/config.json"
        fi
      fi
      prev="\$i"
    done
    break ;;
  esac
done
exec ${K3S_RUNC}.real "\$@"
WRAPPER
chmod +x "$K3S_RUNC"
```

Without this, `kubectl describe pod` shows `FailedCreatePodSandBox: runc create failed: can't get final child's PID from pipe: EOF`. Root cause: nsexec tries `write "/proc/self/oom_score_adj" = -998` and gets `EPERM`.

### 3. Start k3s

```bash
mkdir -p /var/log/k3s /etc/rancher/k3s
nohup k3s server \
  --disable=traefik --disable=servicelb --disable=metrics-server \
  --disable-network-policy \
  --flannel-backend=host-gw \
  --write-kubeconfig=/etc/rancher/k3s/k3s.yaml --write-kubeconfig-mode=0644 \
  >/var/log/k3s/server.log 2>&1 &

# Capture the REAL k3s PID (not the wrapper shell's $!)
sleep 5
K3S_PID=$(pgrep -f "k3s server" | head -1)
echo $K3S_PID > /var/run/k3s.pid

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Wait for API
for i in $(seq 1 60); do kubectl get --raw=/readyz 2>/dev/null && break; sleep 2; done
```

`--flannel-backend=host-gw` avoids VXLAN kernel module requirements. `--disable-network-policy` avoids kernel `ip6tables` bridge writes that the sandbox may block.

### 4. Pre-pull images with retry (Docker Hub flakes)

```bash
pull_retry() {
  local img="$1"
  for try in 1 2 3 4 5 6 7 8; do
    crictl pull "$img" > /tmp/pull.log 2>&1 && return 0
    grep -oE "503|401|404|no such host|timeout" /tmp/pull.log | head -1
    sleep $((try*3))
  done
  return 1
}

for img in \
  "docker.io/rancher/mirrored-coredns-coredns:1.11.3" \
  "docker.io/rancher/mirrored-pause:3.6" \
  "docker.io/rancher/local-path-provisioner:v0.0.28" \
  # any other images your experiment needs
; do
  pull_retry "$img"
done
```

Then force-recreate stuck pods: `kubectl -n kube-system delete pod --all --force --grace-period=0`.

## Running an Experiment

### Background process PID capture (gotcha)

`nohup cmd >log 2>&1 &; echo $!` gives you Claude Code's **wrapper** PID, not the real process. Always do:

```bash
nohup cmd >log 2>&1 &
sleep 1
REAL_PID=$(pgrep -f "<unique pattern from cmd>" | head -1)
echo "$REAL_PID" > /var/run/cmd.pid
```

### Time-bounded outage pattern (what worked)

Don't try to drive a >30s experiment from a single Bash call — the tool either blocks (long `sleep`) or kills the command. Instead, write a driver script, `nohup` it, and monitor markers:

```bash
cat > /tmp/outage.sh <<'EOF'
#!/bin/bash
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
LOG=/path/to/experiment/logs

echo "$(date -u +%FT%TZ) VSO_DOWN" >> $LOG/markers.log
kubectl -n <ns> scale deploy/<target> --replicas=0
kubectl -n <ns> wait --for=delete pod -l <selector> --timeout=60s

sleep 600   # 10-minute outage window

echo "$(date -u +%FT%TZ) OUTAGE_END" >> $LOG/markers.log
kubectl -n <ns> scale deploy/<target> --replicas=1
EOF
chmod +x /tmp/outage.sh
nohup /tmp/outage.sh >/tmp/outage.log 2>&1 &
```

Then use the **Monitor** tool to emit markers as they appear:

```
Monitor:
  command: |
    LOG=/path/to/logs; prev=""
    while [ $SECONDS -lt 900 ]; do
      cur=$(cat $LOG/markers.log 2>/dev/null)
      diff <(echo "$prev") <(echo "$cur") | grep '^>' | sed 's/^> //'
      prev=$cur
      echo "$cur" | grep -q OUTAGE_END && { echo "DONE"; exit 0; }
      sleep 10
    done
  timeout_ms: 1000000
  persistent: false
```

### Continuous-availability consumer pattern

For "does anything break during the outage?" experiments, deploy a pod that logs a status line every ≤5s:

```yaml
containers:
- name: reader
  image: busybox:1.36
  command: [/bin/sh, -c]
  args:
  - |
    set -eu
    while true; do
      ts=$(date -u +%FT%TZ)
      if [ -r /target/file ]; then
        val=$(cat /target/file)
        hash=$(printf '%s' "$val" | md5sum | cut -c1-8)
        echo "$ts OK value=$val hash=$hash"
      else
        echo "$ts FAIL reason_here"
      fi
      sleep 5
    done
```

Then tail to a file for analysis:
```bash
nohup kubectl -n <ns> logs -f deploy/<name> --tail=0 > logs/consumer.log 2>&1 &
```

### Verification checklist

Three mechanical checks that give a binary pass/fail:

1. **Zero failures**: `grep -c FAIL logs/consumer.log` → `0`
2. **No gaps** (the pod's loop never missed a sample):
   ```bash
   awk '{print $1}' logs/consumer.log | python3 -c '
   import sys, datetime as d
   p=None; mg=0
   for l in sys.stdin:
     t=d.datetime.fromisoformat(l.strip().rstrip("Z"))
     if p and (t-p).total_seconds()>mg: mg=(t-p).total_seconds()
     p=t
   print("max_gap_seconds=", mg)'
   ```
3. **Expected state invariance**: snapshot the resource before and during the outage, diff them:
   ```bash
   kubectl -n <ns> get <resource> -o yaml > logs/before.yaml
   # ... outage ...
   kubectl -n <ns> get <resource> -o yaml > logs/during.yaml
   diff <(grep -A1 '^data:' logs/before.yaml) <(grep -A1 '^data:' logs/during.yaml)
   ```

Also count log lines per time-window to prove continuity:
```bash
awk -v a="$START" -v b="$END" '$1>=a && $1<b{c++} END{print c}' logs/consumer.log
# For 5s loop and 10min window expect ≈120
```

## Cleanup

```bash
kill $(cat /var/run/consumer-logs.pid 2>/dev/null) 2>/dev/null || true
kill $(cat /var/run/<other-bg-pids> 2>/dev/null) 2>/dev/null || true
helm -A list -q | xargs -r -I{} helm uninstall {} -n $(helm -A list --filter "^{}$" -o json | jq -r '.[0].namespace')
kubectl delete ns <your-ns-list> --wait=false || true
kill $(cat /var/run/k3s.pid) 2>/dev/null || true
/usr/local/bin/k3s-killall.sh 2>/dev/null || true
```

Full reset: `/usr/local/bin/k3s-uninstall.sh` removes the binary + `/var/lib/rancher/k3s` + `/etc/rancher/k3s`.

## When Something Fails

| Symptom | Likely cause | Fix |
|---|---|---|
| `FailedCreatePodSandBox: runc create failed: can't get final child's PID from pipe: EOF` | runc wrapper not installed | Install wrapper (section 2), force-recreate pods |
| `Failed to pull image ... 503 Service Unavailable` | Docker Hub / registry.k8s.io flaking | Use `pull_retry` loop (section 4) |
| `kubectl get pods` shows `CrashLoopBackOff` on an operator that talks to Vault | Vault auth method / role not configured yet | `kubectl logs --previous`; configure `vault auth enable`, `vault write auth/<m>/role/...`; `kubectl delete pod` to retry |
| `kubectl port-forward` dies immediately | process_api may kill long-lived connections; respawn under `nohup`, capture real PID with `pgrep` |
| `sleep N && cmd` blocked by Bash tool | Offload long waits to a `nohup` script + Monitor loop |
| Pods stuck `Pending` with `0/1 nodes are available: untolerated taint {node.kubernetes.io/not-ready}` | k3s not fully up yet | `kubectl get --raw=/readyz`; wait for `kube-dns` Ready before continuing |

## Reference: full flow for a typical operator experiment

1. Install prereqs + k3s + runc wrapper (sections 1–3 above)
2. Pre-pull all images the experiment will need
3. `helm install` Vault / cert-manager / whatever backing service
4. Configure backing service (policies, auth, seed data) — usually via `kubectl port-forward` + CLI
5. Install the operator under test via its Helm chart
6. Create the CR the operator reconciles; verify expected k8s resources appear
7. Deploy a continuous-availability consumer pod
8. Start log tailer to a file
9. Record baseline for ~2 min
10. Introduce the fault (`kubectl scale --replicas=0`, `kubectl delete pod`, Vault revoke, etc.) via a `nohup`'d driver script
11. Monitor markers; wait for `OUTAGE_END`
12. Run the 3 verification checks above
13. Cleanup

Commit `manifests/`, `results/{consumer.log,markers.log,*.yaml}` to the repo; gitignore live `logs/`.
