#!/bin/bash
# Reproduce the Helm 3.17.1 namespace pre-install hook bug.
# Requires: a running k8s cluster and helm 3.17.1 in PATH.
set -eu
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Helm version ==="
helm version

echo
echo "=== Clean previous run ==="
kubectl delete ns xxx yyy --ignore-not-found --wait=true >/dev/null 2>&1 || true

echo
echo "=== Case A: namespace.yaml WITH helm.sh/hook: pre-install ==="
helm upgrade --install --create-namespace --namespace xxx app "$SCRIPT_DIR/chart"
echo "helm list -A:"
helm list -A
echo "secrets in xxx:"
kubectl -n xxx get secrets
echo

echo "=== Case B: control - no namespace.yaml, just --create-namespace ==="
helm upgrade --install --create-namespace --namespace yyy app "$SCRIPT_DIR/chart2"
echo "helm list -A:"
helm list -A
echo "secrets in yyy:"
kubectl -n yyy get secrets

echo
echo "=== Expected (Helm 3.17.1 bug) ==="
echo "Case A: 'STATUS: deployed' shown, but helm list empty, no sh.helm.release secret"
echo "Case B: release properly recorded, sh.helm.release.v1.app.v1 secret exists"
