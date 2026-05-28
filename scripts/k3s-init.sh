#!/usr/bin/env bash
# k3s-init.sh — bootstrap a single-node k3s cluster on a sandboxed VM.
#
# Tested on the Claude Code on the web sandbox (Ubuntu 24.04, kernel 6.18.x,
# PID 1 = process_api). Works on a normal Ubuntu VM too — the sandbox-specific
# fixes (runc wrapper, nohup start) are no-ops elsewhere.
#
# Idempotent: re-running skips steps that are already done.
#
# Usage:
#   sudo ./k3s-init.sh
#   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
#   kubectl get nodes
#
# Override versions via env:
#   K3S_VERSION=v1.30.5+k3s1 KUBECTL_VERSION=v1.30.5 ./k3s-init.sh

set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.30.5+k3s1}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.30.5}"
HELM_VERSION="${HELM_VERSION:-v3.15.4}"
INSTALL_HELM="${INSTALL_HELM:-1}"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

log()  { printf '\033[1;34m[k3s-init]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[k3s-init]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[k3s-init]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

# Retry a command up to N times with exponential backoff (2s, 4s, 8s, ...).
retry() {
  local tries="$1"; shift
  local i=1
  until "$@"; do
    if [ "$i" -ge "$tries" ]; then return 1; fi
    sleep $((i*2)); i=$((i+1))
  done
}

###############################################################################
# 1. Prereqs
###############################################################################
log "installing apt prerequisites"
mkdir -p "/lib/modules/$(uname -r)"   # silence modprobe; needed kernel features are built-in
export DEBIAN_FRONTEND=noninteractive
retry 4 apt-get update -qq
retry 4 apt-get install -y -qq \
  iproute2 iptables conntrack ebtables socat curl jq unzip ca-certificates

###############################################################################
# 2. kubectl
###############################################################################
if ! command -v kubectl >/dev/null 2>&1; then
  log "installing kubectl ${KUBECTL_VERSION}"
  retry 4 curl -fsSL --retry 3 -o /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  chmod +x /usr/local/bin/kubectl
else
  log "kubectl already present: $(kubectl version --client 2>/dev/null | head -1)"
fi

###############################################################################
# 3. Helm (optional)
###############################################################################
if [ "$INSTALL_HELM" = "1" ] && ! command -v helm >/dev/null 2>&1; then
  log "installing helm ${HELM_VERSION}"
  tmpdir=$(mktemp -d)
  retry 4 curl -fsSL --retry 3 -o "${tmpdir}/helm.tgz" \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  tar -xzf "${tmpdir}/helm.tgz" -C "${tmpdir}"
  install -m0755 "${tmpdir}/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "${tmpdir}"
fi

###############################################################################
# 4. k3s binary (no service start — sandbox has no systemd)
###############################################################################
if ! command -v k3s >/dev/null 2>&1; then
  log "installing k3s ${K3S_VERSION} (binary only)"
  retry 4 curl -fsSL --retry 3 -o /tmp/k3s-install.sh https://get.k3s.io
  INSTALL_K3S_SKIP_ENABLE=true \
  INSTALL_K3S_SKIP_START=true \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
    sh /tmp/k3s-install.sh
else
  log "k3s already present: $(k3s --version | head -1)"
fi

###############################################################################
# 5. Trigger k3s data extraction (needed to find the bundled runc)
###############################################################################
if [ -z "$(find /var/lib/rancher/k3s/data -name runc -type f 2>/dev/null | head -1)" ]; then
  log "extracting k3s bundled data"
  k3s ctr version >/dev/null 2>&1 || true   # exits non-zero (no containerd yet) but extracts data
fi

###############################################################################
# 6. runc wrapper — strips oomScoreAdj from config.json
#
# WHY: the sandbox lacks CAP_SYS_RESOURCE, so writing negative oom_score_adj to
# /proc/self/oom_score_adj returns EPERM, and every pod fails to start with:
#   FailedCreatePodSandBox: runc create failed: can't get final child's PID
#   from pipe: EOF
# On a normal VM this wrapper is a no-op (kubelet's oomScoreAdj write succeeds
# anyway), so it's safe to leave installed.
###############################################################################
K3S_RUNC="$(find /var/lib/rancher/k3s/data -name runc -type f ! -name 'runc.real' | head -1 || true)"
[ -n "$K3S_RUNC" ] || die "could not locate bundled runc under /var/lib/rancher/k3s/data"

if [ ! -f "${K3S_RUNC}.real" ]; then
  log "installing runc wrapper at ${K3S_RUNC}"
  mv "$K3S_RUNC" "${K3S_RUNC}.real"
  cat > "$K3S_RUNC" <<WRAPPER
#!/bin/bash
# Strip oomScoreAdj from config.json on create/run/exec — sandbox lacks
# CAP_SYS_RESOURCE so writing negative oom_score_adj would EPERM.
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
else
  log "runc wrapper already installed"
fi

###############################################################################
# 7. Start k3s server (nohup — no systemd in sandbox)
###############################################################################
mkdir -p /var/log/k3s /etc/rancher/k3s /var/run

if pgrep -f "k3s server" >/dev/null 2>&1; then
  log "k3s server already running (pid $(pgrep -f 'k3s server' | head -1))"
else
  log "starting k3s server"
  nohup k3s server \
    --disable=traefik \
    --disable=servicelb \
    --disable=metrics-server \
    --disable-network-policy \
    --flannel-backend=host-gw \
    --write-kubeconfig="${KUBECONFIG_PATH}" \
    --write-kubeconfig-mode=0644 \
    >/var/log/k3s/server.log 2>&1 &

  # Recover the REAL k3s pid (Bash $! captures the wrapper shell, not k3s).
  sleep 5
  K3S_PID="$(pgrep -f 'k3s server' | head -1 || true)"
  [ -n "$K3S_PID" ] || die "k3s failed to start — see /var/log/k3s/server.log"
  echo "$K3S_PID" > /var/run/k3s.pid
  log "k3s pid: ${K3S_PID}"
fi

###############################################################################
# 8. Wait for API readiness
###############################################################################
export KUBECONFIG="${KUBECONFIG_PATH}"
log "waiting for API server to become ready"
for i in $(seq 1 60); do
  if kubectl get --raw=/readyz 2>/dev/null | grep -q ok; then
    log "API ready (after $((i*2))s)"
    break
  fi
  sleep 2
  [ "$i" = 60 ] && die "API did not become ready in 120s — see /var/log/k3s/server.log"
done

kubectl get nodes
log "done. Add the following to your shell:"
echo "    export KUBECONFIG=${KUBECONFIG_PATH}"
