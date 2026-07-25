#!/bin/bash
# reset-to-1.14.sh — 完整拆除 cert-manager 與所有 CR，重裝乾淨的 1.14.7 + fixtures
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EXP=/home/user/opensource_labs/cert-manager-upgrade-experiment
source /tmp/exp-env

helm uninstall cert-manager -n cert-manager --wait 2>/dev/null || true
# CRD 帶 keep annotation 時 uninstall 不會刪 → 手動刪（連帶 GC 所有 CR）
kubectl delete crd \
  certificates.cert-manager.io certificaterequests.cert-manager.io \
  issuers.cert-manager.io clusterissuers.cert-manager.io \
  orders.acme.cert-manager.io challenges.acme.cert-manager.io --ignore-not-found
kubectl delete ns apps --ignore-not-found --wait=true
kubectl delete ns cert-manager --ignore-not-found --wait=true

helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.14.7 \
  --values $EXP/manifests/values-realistic-1.14.yaml \
  --wait --timeout 10m >/dev/null

VAULT_ADDR_POD="http://${NODE_IP}:8200"
sed -e "s|\${VAULT_ADDR}|$VAULT_ADDR_POD|g" -e "s|\${ROLE_ID}|$ROLE_ID|g" -e "s|\${SECRET_ID}|$SECRET_ID|g" \
  $EXP/manifests/fixtures.yaml | kubectl apply -f - >/dev/null

# 等四張應簽出的憑證 Ready（ctrl-sa 預期 False）
for c in cert-legacy cert-pinned cert-canary cert-approle; do
  kubectl -n apps wait --for=condition=Ready certificate/$c --timeout=180s >/dev/null || echo "WARN: $c not ready"
done
echo RESET_OK
