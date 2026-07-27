#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BASE=/home/user/opensource_labs/cert-manager-duplicate-experiment
RESULTS=$BASE/results
C2=$RESULTS/05-case2
mkdir -p "$C2"
MARK=$RESULTS/markers.log

echo "$(date -u +%FT%TZ) CASE2_START" >> "$MARK"
kubectl -n kube-system get lease -o yaml > "$C2/leases-case2-before.yaml"

# create demo-cert3 right after CASE2_START to measure reconciliation gap
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: demo-cert3
  namespace: demo
spec:
  secretName: demo-cert3-tls
  commonName: demo-cert3.demo.example
  dnsNames:
    - demo-cert3.demo.example
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
    group: cert-manager.io
EOF
echo "$(date -u +%FT%TZ) DEMO_CERT3_CREATED" >> "$MARK"

# Step b: webhook configs of cm-a FIRST (safe order)
kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/instance=cm-a
echo "$(date -u +%FT%TZ) CASE2_CM_A_WEBHOOKCONFIGS_DELETED" >> "$MARK"

sleep 5

# Step c: cm-a deployments
> "$C2/deleted-resources.txt"
echo "=== deployments (instance=cm-a) ===" >> "$C2/deleted-resources.txt"
kubectl -n cert-manager get deploy -l app.kubernetes.io/instance=cm-a -o name >> "$C2/deleted-resources.txt"
kubectl -n cert-manager delete deploy -l app.kubernetes.io/instance=cm-a
echo "$(date -u +%FT%TZ) CASE2_CM_A_DEPLOYS_DELETED" >> "$MARK"

sleep 5

# remaining namespaced + cluster RBAC resources, EXPLICITLY excluding CRDs
for res in service serviceaccount configmap role rolebinding; do
  echo "=== $res (instance=cm-a) ===" >> "$C2/deleted-resources.txt"
  kubectl -n cert-manager get $res -l app.kubernetes.io/instance=cm-a -o name >> "$C2/deleted-resources.txt"
  kubectl -n cert-manager delete $res -l app.kubernetes.io/instance=cm-a --ignore-not-found
done
for res in clusterrole clusterrolebinding; do
  echo "=== $res (instance=cm-a) ===" >> "$C2/deleted-resources.txt"
  kubectl get $res -l app.kubernetes.io/instance=cm-a -o name >> "$C2/deleted-resources.txt"
  kubectl delete $res -l app.kubernetes.io/instance=cm-a --ignore-not-found
done
echo "=== EXCLUDED: CRDs (instance=cm-a) kept intact ===" >> "$C2/deleted-resources.txt"
kubectl get crd -l app.kubernetes.io/instance=cm-a -o name >> "$C2/deleted-resources.txt"

echo "$(date -u +%FT%TZ) CASE2_DONE" >> "$MARK"
touch "$C2/CASE2_COMPLETE.marker"
