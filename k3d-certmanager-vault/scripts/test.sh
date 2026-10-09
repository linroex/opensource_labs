#!/usr/bin/env bash
# Issue a certificate through cert-manager -> Vault and verify it.
set -euo pipefail
cd "$(dirname "$0")/.."

kubectl apply -f manifests/test-certificate.yaml
kubectl -n demo wait --for=condition=Ready certificate/app-example-com --timeout=120s
kubectl -n demo get certificate app-example-com

crt=$(mktemp); trap 'rm -f "$crt"' EXIT
kubectl -n demo get secret app-example-com-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$crt"
openssl x509 -in "$crt" -noout -subject -issuer -dates -ext subjectAltName
echo ">> chain verifies against Vault root CA:"
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root vault read -field=certificate pki/cert/ca > "$crt.ca"
openssl verify -CAfile "$crt.ca" "$crt"; rm -f "$crt.ca"
