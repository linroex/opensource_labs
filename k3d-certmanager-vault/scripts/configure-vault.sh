#!/usr/bin/env bash
# Configure Vault (dev mode) so cert-manager can sign certificates through it:
#   - PKI secrets engine with an internal root CA + a signing role
#   - policy that only allows signing with that role
#   - Kubernetes auth method; role bound to the cert-manager/vault-issuer ServiceAccount
set -euo pipefail

NS="${VAULT_NS:-vault}"
vault() { kubectl -n "$NS" exec -i vault-0 -- env VAULT_TOKEN=root vault "$@"; }

echo ">> PKI secrets engine"
vault secrets list -format=json | grep -q '"pki/"' || vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki
if ! vault read -field=certificate pki/cert/ca >/dev/null 2>&1; then
  vault write -field=certificate pki/root/generate/internal \
    common_name="Lab Root CA" issuer_name=lab-root ttl=87600h >/dev/null
fi
vault write pki/config/urls \
  issuing_certificates="http://vault.${NS}.svc.cluster.local:8200/v1/pki/ca" \
  crl_distribution_points="http://vault.${NS}.svc.cluster.local:8200/v1/pki/crl" >/dev/null
vault write pki/roles/example-dot-com \
  allowed_domains=example.com allow_subdomains=true key_type=any \
  max_ttl=72h >/dev/null

echo ">> policy"
vault policy write cert-manager - >/dev/null <<'POLICY'
path "pki/sign/example-dot-com" { capabilities = ["create", "update"] }
POLICY

echo ">> Kubernetes auth"
vault auth list -format=json | grep -q '"kubernetes/"' || vault auth enable kubernetes
# Vault runs in-cluster: it uses its own ServiceAccount token/CA to call TokenReview.
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443" >/dev/null
vault write auth/kubernetes/role/cert-manager \
  bound_service_account_names=vault-issuer \
  bound_service_account_namespaces=cert-manager \
  audience=vault \
  token_policies=cert-manager \
  token_ttl=10m >/dev/null
echo ">> Vault configured"
