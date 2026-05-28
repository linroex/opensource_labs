#!/bin/bash
# Bring up k3s in this sandbox and deploy EFK.
# Idempotent-ish: safe to re-run after a fresh container start.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> [1/5] Prereqs"
mkdir -p /lib/modules/"$(uname -r)"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  iproute2 iptables conntrack ebtables socat curl jq unzip ca-certificates >/dev/null

if ! command -v kubectl >/dev/null; then
  for i in 1 2 3 4; do
    curl -fsSL --retry 3 -o /usr/local/bin/kubectl \
      https://dl.k8s.io/release/v1.30.5/bin/linux/amd64/kubectl && break
    sleep $((i*2))
  done
  chmod +x /usr/local/bin/kubectl
fi

if ! command -v k3s >/dev/null; then
  curl -fsSL --retry 3 https://get.k3s.io -o /tmp/k3s-install.sh
  INSTALL_K3S_SKIP_ENABLE=true INSTALL_K3S_SKIP_START=true \
    INSTALL_K3S_VERSION=v1.30.5+k3s1 sh /tmp/k3s-install.sh
fi

echo "==> [2/5] Install runc wrapper (sandbox needs oomScoreAdj stripped)"
# Need to start k3s once so the runc binary is extracted.
if [ ! -d /var/lib/rancher/k3s/data ]; then
  mkdir -p /var/log/k3s /etc/rancher/k3s
  nohup k3s server --disable=traefik --disable=servicelb --disable=metrics-server \
    --disable-network-policy --flannel-backend=host-gw \
    --write-kubeconfig=/etc/rancher/k3s/k3s.yaml --write-kubeconfig-mode=0644 \
    >/var/log/k3s/server.log 2>&1 &
  sleep 8
  pgrep -f "k3s server" | head -1 | xargs -r kill || true
  /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
  sleep 2
fi

K3S_RUNC=$(find /var/lib/rancher/k3s/data -name runc -type f | head -1)
if [ ! -f "${K3S_RUNC}.real" ]; then
  mv "$K3S_RUNC" "${K3S_RUNC}.real"
  cat > "$K3S_RUNC" <<WRAPPER
#!/bin/bash
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
fi

echo "==> [3/5] Start k3s"
mkdir -p /var/log/k3s /etc/rancher/k3s
if ! pgrep -f "k3s server" >/dev/null; then
  nohup k3s server --disable=traefik --disable=servicelb --disable=metrics-server \
    --disable-network-policy --flannel-backend=host-gw \
    --write-kubeconfig=/etc/rancher/k3s/k3s.yaml --write-kubeconfig-mode=0644 \
    >/var/log/k3s/server.log 2>&1 &
  sleep 5
  pgrep -f "k3s server" | head -1 > /var/run/k3s.pid
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for i in $(seq 1 60); do kubectl get --raw=/readyz >/dev/null 2>&1 && break; sleep 2; done
kubectl get nodes

echo "==> [4/5] Pre-pull images"
pull_retry() {
  local img="$1"
  for try in 1 2 3 4 5 6 7 8; do
    k3s crictl pull "$img" >/tmp/pull.log 2>&1 && { echo "  OK $img"; return 0; }
    sleep $((try*3))
  done
  echo "  FAIL $img"; return 1
}
for img in \
  "docker.elastic.co/elasticsearch/elasticsearch:7.17.24" \
  "docker.elastic.co/kibana/kibana:7.17.24" \
  "fluent/fluentd-kubernetes-daemonset:v1.17.1-debian-elasticsearch7-1.1" \
  "busybox:1.36" ; do
  pull_retry "$img"
done

echo "==> [5/5] Apply EFK manifests"
kubectl apply -f "$ROOT/manifests/"
kubectl -n logging wait --for=condition=ready pod -l app=elasticsearch --timeout=180s
kubectl -n logging wait --for=condition=ready pod -l app=kibana        --timeout=180s
kubectl -n logging get pods -o wide
echo ""
echo "Done. Kibana NodePort:"
kubectl -n logging get svc kibana
