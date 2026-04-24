#!/bin/bash
# Reproduces Helm 3.17.1 --create-namespace + Namespace-template first-install bug.
# Shows BOTH error-message variants from the same root cause.
# Requires: a running k8s cluster and helm 3.17.1 in PATH.
set -eu
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Helm version ==="
helm version

### Full cleanup
for row in $(helm list -A -o json | jq -r '.[] | "\(.name),\(.namespace)"' 2>/dev/null); do
  helm uninstall "${row%,*}" -n "${row#*,}" >/dev/null 2>&1 || true
done
for ns in zzz ttt; do kubectl delete ns "$ns" --ignore-not-found --wait=true >/dev/null 2>&1 || true; done
kubectl delete clusterrole app-reader --ignore-not-found >/dev/null 2>&1 || true

echo
echo "##################################################"
echo "# Manifestation A: chart has only Namespace + ConfigMap"
echo "##################################################"
echo "--- 1st helm install: fails with 'namespaces already exists' ---"
helm install --create-namespace --namespace zzz app "$SCRIPT_DIR/chart3" || true
echo "--- helm list -A (release recorded as 'failed'):"
helm list -A | grep -E "NAME|zzz" || true
echo "--- ns zzz exists without helm ownership labels:"
kubectl get ns zzz -o jsonpath='{.metadata.labels}{"\n"}'
echo "--- 2nd run with 'helm upgrade --install' succeeds (goes through upgrade path):"
helm upgrade --install --create-namespace --namespace zzz app "$SCRIPT_DIR/chart3" | tail -5
helm list -A | grep -E "NAME|zzz" || true

### Cleanup for Manifestation B
helm uninstall app -n zzz >/dev/null 2>&1 || true
kubectl delete ns zzz --ignore-not-found --wait=true >/dev/null 2>&1 || true

echo
echo "##################################################"
echo "# Manifestation B: chart also has a cluster-scoped resource (ClusterRole)"
echo "# that already exists in cluster with helm ownership labels (leftover state)"
echo "##################################################"
echo "--- Pre-create ClusterRole with helm ownership labels ---"
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: app-reader
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: app
    meta.helm.sh/release-namespace: ttt
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get"]
EOF
echo "--- 1st helm install: fails with the user's exact error ---"
helm install --create-namespace --namespace ttt app "$SCRIPT_DIR/chart4" || true
echo "--- state: ns ttt was still created ---"
kubectl get ns ttt | tail -1
helm list -A | grep -E "NAME|ttt" || true
