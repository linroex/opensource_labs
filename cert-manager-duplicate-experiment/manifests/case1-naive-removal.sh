#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BASE=/home/user/opensource_labs/cert-manager-duplicate-experiment
RESULTS=$BASE/results
C1=$RESULTS/04-case1
mkdir -p "$C1"
MARK=$RESULTS/markers.log

echo "$(date -u +%FT%TZ) CASE1_START" >> "$MARK"
kubectl -n kube-system get lease -o yaml > "$C1/leases-case1-before.yaml"

# Step 2: delete cm-b deployments FIRST (naive - webhook configs still point at dead svc)
kubectl -n cert-manager delete deploy -l app.kubernetes.io/instance=cm-b
echo "$(date -u +%FT%TZ) CASE1_DEPLOYS_DELETED" >> "$MARK"

# Step 3: sleep 90s inside window; capture one manual annotate error
sleep 15
kubectl -n demo annotate certificate demo-cert probe.manual="$(date -u +%FT%TZ)" --overwrite > "$C1/naive-window-error.txt" 2>&1
echo "exit_code=$?" >> "$C1/naive-window-error.txt"
sleep 75

# Step 4: delete cm-b webhook configs
kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/instance=cm-b
echo "$(date -u +%FT%TZ) CASE1_WEBHOOKCONFIGS_DELETED" >> "$MARK"

sleep 10

# Step 5: delete the rest of cm-b (svc, sa, cm, role, rolebinding, clusterrole, clusterrolebinding)
kubectl -n cert-manager delete service -l app.kubernetes.io/instance=cm-b --ignore-not-found
kubectl -n cert-manager delete serviceaccount -l app.kubernetes.io/instance=cm-b --ignore-not-found
kubectl -n cert-manager delete configmap -l app.kubernetes.io/instance=cm-b --ignore-not-found
kubectl -n cert-manager delete role -l app.kubernetes.io/instance=cm-b --ignore-not-found
kubectl -n cert-manager delete rolebinding -l app.kubernetes.io/instance=cm-b --ignore-not-found
kubectl delete clusterrole -l app.kubernetes.io/instance=cm-b --ignore-not-found
kubectl delete clusterrolebinding -l app.kubernetes.io/instance=cm-b --ignore-not-found
echo "$(date -u +%FT%TZ) CASE1_DONE" >> "$MARK"

touch "$C1/CASE1_COMPLETE.marker"
