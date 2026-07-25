#!/bin/bash
# snapshot.sh <label> — 擷取當前狀態：版本、issuer/cert 狀態、憑證序號、私鑰雜湊、CR 數
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
LABEL=$1
OUT=/home/user/opensource_labs/cert-manager-upgrade-experiment/results/snap-${LABEL}.txt
{
echo "=== SNAPSHOT $LABEL @ $(date -u +%FT%TZ) (epoch $(date +%s)) ==="
echo "--- helm release ---"
helm ls -n cert-manager -o json 2>/dev/null | jq -r '.[] | "\(.chart) rev=\(.revision) status=\(.status)"'
echo "--- pod images ---"
kubectl -n cert-manager get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null
echo "--- clusterissuers ---"
kubectl get clusterissuer -o jsonpath='{range .items[*]}{.metadata.name}{"\tReady="}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.conditions[?(@.type=="Ready")].message}{"\n"}{end}' 2>/dev/null
echo "--- certificates ---"
for c in cert-legacy cert-pinned cert-canary cert-ctrlsa cert-approle; do
  ready=$(kubectl -n apps get certificate $c -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  msg=$(kubectl -n apps get certificate $c -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null | head -c 120)
  notafter=$(kubectl -n apps get certificate $c -o jsonpath='{.status.notAfter}' 2>/dev/null)
  secret=$(kubectl -n apps get certificate $c -o jsonpath='{.spec.secretName}' 2>/dev/null)
  serial=$(kubectl -n apps get secret $secret -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2)
  nb=$(kubectl -n apps get secret $secret -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -startdate 2>/dev/null | cut -d= -f2)
  keyhash=$(kubectl -n apps get secret $secret -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d 2>/dev/null | sha256sum | cut -c1-12)
  echo "$c Ready=$ready serial=${serial:0:12} notBefore='$nb' keyhash=$keyhash msg='$msg'"
done
echo "--- certificaterequests (count per cert) ---"
kubectl -n apps get certificaterequest -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null | sort | uniq -c
echo "--- crds (renewal field present? = 1.21 schema) ---"
kubectl get crd certificates.cert-manager.io -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.renewal.type}' 2>/dev/null | grep -q object && echo "spec.renewal PRESENT (1.21 CRD)" || echo "spec.renewal absent"
} > $OUT 2>&1
cat $OUT
