#!/bin/bash
# vault-setup.sh — 啟動 dev Vault（無 proxy 環境）並配置 PKI + kubernetes auth + approle
# dev 模式為 in-memory，重啟後需整份重跑
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# 殺掉舊的（若有）
pkill -f "vault server -dev" 2>/dev/null && sleep 2 || true

# 關鍵：清掉 proxy 環境變數，否則 Vault 對 k3s API 的 TokenReview 會被送進 sandbox proxy 而失敗
env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy \
  nohup vault server -dev -dev-listen-address=0.0.0.0:8200 -dev-root-token-id=root \
  >/var/log/vault-dev.log 2>&1 &
sleep 3
pgrep -f "vault server -dev" | head -1 > /var/run/vault.pid

export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root

# --- PKI ---
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki
vault write -field=certificate pki/root/generate/internal common_name="lab-root-ca" ttl=87600h >/dev/null
vault write pki/roles/cm allow_any_name=true enforce_hostnames=false max_ttl=72h ttl=24h >/dev/null

# --- Kubernetes auth ---
kubectl -n kube-system get sa vault-reviewer >/dev/null 2>&1 || {
  kubectl -n kube-system create serviceaccount vault-reviewer
  kubectl create clusterrolebinding vault-reviewer-auth-delegator \
    --clusterrole=system:auth-delegator --serviceaccount=kube-system:vault-reviewer
}
REVIEWER_JWT=$(kubectl -n kube-system create token vault-reviewer --duration=48h)
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://$NODE_IP:6443" \
  kubernetes_ca_cert=@/var/lib/rancher/k3s/server/tls/server-ca.crt \
  token_reviewer_jwt="$REVIEWER_JWT"
vault policy write cm-sign - <<'EOF'
path "pki/sign/cm" { capabilities = ["create","update"] }
EOF
vault write auth/kubernetes/role/cm-ctrl \
  bound_service_account_names=cert-manager bound_service_account_namespaces=cert-manager \
  policies=cm-sign ttl=10m
vault write auth/kubernetes/role/cm-dedicated \
  bound_service_account_names=vault-issuer bound_service_account_namespaces=cert-manager \
  policies=cm-sign ttl=10m

# --- AppRole ---
vault auth enable approle
vault write auth/approle/role/cm-approle token_policies=cm-sign token_ttl=10m
ROLE_ID=$(vault read -field=role_id auth/approle/role/cm-approle/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/cm-approle/secret-id)
grep -v '^ROLE_ID=\|^SECRET_ID=' /tmp/exp-env 2>/dev/null > /tmp/exp-env.new || true
{ echo "NODE_IP=$NODE_IP"; echo "ROLE_ID=$ROLE_ID"; echo "SECRET_ID=$SECRET_ID"; } >> /tmp/exp-env.new
sort -u /tmp/exp-env.new > /tmp/exp-env
echo VAULT_SETUP_OK
