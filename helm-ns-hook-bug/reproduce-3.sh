#!/bin/bash
# Test the workaround: drop --create-namespace, let chart's namespace.yaml manage it.
# Spoiler: this also fails on Helm 3.17.1 — even worse, you can't recover by retrying.
set -eu
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Helm version ==="
helm version

# Cleanup
for row in $(helm list -A -o json | jq -r '.[] | "\(.name),\(.namespace)"' 2>/dev/null); do
  helm uninstall "${row%,*}" -n "${row#*,}" >/dev/null 2>&1 || true
done
kubectl delete ns uuu --ignore-not-found --wait=true >/dev/null 2>&1 || true

echo
echo "##################################################"
echo "# Workaround attempt: drop --create-namespace, chart owns the ns"
echo "##################################################"
echo "ns uuu does not exist:"
kubectl get ns uuu 2>&1 | tail -1
echo "--- 1st helm install ---"
helm install --namespace uuu app "$SCRIPT_DIR/chart3" 2>&1 | tail -3 || true
echo "--- state: NOTHING was created ---"
kubectl get ns uuu 2>&1 | tail -1
helm list -A
echo "--- 2nd helm install (also fails the same way — no recovery possible) ---"
helm install --namespace uuu app "$SCRIPT_DIR/chart3" 2>&1 | tail -3 || true

echo
echo "##################################################"
echo "# Failed escape attempt 1: manually 'kubectl create ns uuu' first"
echo "##################################################"
kubectl create namespace uuu
helm install --namespace uuu app "$SCRIPT_DIR/chart3" 2>&1 | tail -3 || true

echo
echo "##################################################"
echo "# Working workaround A: --take-ownership flag"
echo "##################################################"
helm install --namespace uuu app "$SCRIPT_DIR/chart3" --take-ownership 2>&1 | tail -5
helm list -A | grep -E "NAME|uuu"
echo

# Cleanup for next test
helm uninstall app -n uuu >/dev/null 2>&1 || true
kubectl delete ns uuu --ignore-not-found --wait=true >/dev/null 2>&1 || true

echo "##################################################"
echo "# Working workaround B: pre-create ns WITH helm ownership labels"
echo "##################################################"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: uuu
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: app
    meta.helm.sh/release-namespace: uuu
EOF
helm install --namespace uuu app "$SCRIPT_DIR/chart3" 2>&1 | tail -5
helm list -A | grep -E "NAME|uuu"
