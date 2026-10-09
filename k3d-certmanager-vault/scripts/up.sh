#!/usr/bin/env bash
# Build the whole lab: k3d (k8s 1.34) + Vault + cert-manager + Vault-backed ClusterIssuer.
# Idempotent - safe to re-run.
#
# Optional env (sandbox / corporate-proxy workarounds):
#   EXTRA_CA_BUNDLE=/path/ca.crt  mount a CA bundle into the k3d nodes so containerd
#                                 trusts a TLS-intercepting egress proxy
#   PATCH_RUNC=1                  wrap runc to reset oomScoreAdj (hosts without CAP_SYS_RESOURCE)
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=cm-vault
CERT_MANAGER_VERSION=v1.20.3
VAULT_CHART_VERSION=0.34.1

if k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  echo ">> k3d cluster $CLUSTER already exists"
else
  args=(--config k3d-config.yaml)
  [ -n "${EXTRA_CA_BUNDLE:-}" ] && args+=(--volume "${EXTRA_CA_BUNDLE}:/etc/ssl/certs/ca-certificates.crt@all")
  k3d cluster create "${args[@]}"
fi
kubectl config use-context "k3d-$CLUSTER" >/dev/null
[ "${PATCH_RUNC:-0}" = 1 ] && scripts/patch-runc.sh "$CLUSTER"

kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl -n kube-system rollout status deploy/coredns --timeout=180s

helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update >/dev/null

echo ">> cert-manager $CERT_MANAGER_VERSION"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "$CERT_MANAGER_VERSION" -f values/cert-manager.yaml --wait --timeout 5m

echo ">> Vault (chart $VAULT_CHART_VERSION)"
helm upgrade --install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --version "$VAULT_CHART_VERSION" -f values/vault.yaml
kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=5m

scripts/configure-vault.sh

echo ">> ClusterIssuer"
kubectl apply -f manifests/cert-manager-vault-auth.yaml
kubectl apply -f manifests/clusterissuer-vault.yaml
kubectl wait --for=condition=Ready clusterissuer/vault-issuer --timeout=120s
echo ">> Done. Run scripts/test.sh to issue a test certificate."
