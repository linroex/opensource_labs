#!/bin/bash
# Test: namespace.yaml WITH 'helm.sh/hook: pre-install' but WITHOUT --create-namespace.
# Hypothesis: the pre-install hook should create the ns before main resources.
# Spoiler: hook never runs. helm dies even earlier than the no-hook case (same line, same error).
set -eu
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Helm version ==="
helm version

# Cleanup
for row in $(helm list -A -o json | jq -r '.[] | "\(.name),\(.namespace)"' 2>/dev/null); do
  helm uninstall "${row%,*}" -n "${row#*,}" >/dev/null 2>&1 || true
done
kubectl delete ns vvv --ignore-not-found --wait=true >/dev/null 2>&1 || true

echo
echo "=== chart/templates/namespace.yaml (has pre-install hook) ==="
cat "$SCRIPT_DIR/chart/templates/namespace.yaml"

echo
echo "=== Test: helm install with hook'd namespace, NO --create-namespace ==="
echo "ns vvv does not exist:"
kubectl get ns vvv 2>&1 | tail -1
echo
echo "--- 1st helm install ---"
helm install --namespace vvv app "$SCRIPT_DIR/chart" 2>&1 | tail -3 || true
echo
echo "--- state: NOTHING was created ---"
kubectl get ns vvv 2>&1 | tail -1
helm list -A
echo
echo "--- 2nd run (same error, no recovery possible) ---"
helm install --namespace vvv app "$SCRIPT_DIR/chart" 2>&1 | tail -3 || true
