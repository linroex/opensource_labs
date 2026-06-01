#!/bin/bash
# Rolling restart experiment for OpenSearch masters - inspect cluster state
# consistency from each surviving master's perspective at every step.
set -uo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=os
RESULTS=${RESULTS:-/home/user/opensource_labs/opensearch-experiment/results}
mkdir -p "$RESULTS"
LOG="$RESULTS/rolling_restart.log"
: > "$LOG"

snapshot() {
  local tag=$1
  {
    echo "=========================================================="
    echo "TAG: $tag   time=$(date -u +%FT%TZ)"
    echo "=========================================================="
    echo "--- K8s pod IPs ---"
    kubectl -n $NS get pods -l app=opensearch-master \
      -o custom-columns=NAME:.metadata.name,IP:.status.podIP,READY:.status.containerStatuses[0].ready --no-headers
    for n in opensearch-master-0 opensearch-master-1 opensearch-master-2; do
      ready=$(kubectl -n $NS get pod $n -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
      if [ "$ready" != "true" ]; then
        echo "--- $n: NOT_READY (skipping query) ---"
        continue
      fi
      echo "--- $n's view of cluster nodes (_cat/nodes) ---"
      kubectl -n $NS exec $n -c opensearch -- curl -sS --max-time 4 \
        "localhost:9200/_cat/nodes?h=id,name,ip,master" 2>/dev/null \
        | sort -k2
    done
    echo
  } | tee -a "$LOG"
}

restart_pod() {
  local pod=$1
  echo "*** Restarting $pod ***" | tee -a "$LOG"
  local old_uid old_ip
  old_uid=$(kubectl -n $NS get pod $pod -o jsonpath='{.metadata.uid}')
  old_ip=$(kubectl -n $NS get pod $pod -o jsonpath='{.status.podIP}')
  echo "    old uid=$old_uid old ip=$old_ip" | tee -a "$LOG"

  # Force-delete so the IP is freed promptly and the new pod is more likely
  # to be allocated a different IP from the CNI pool.
  kubectl -n $NS delete pod $pod --force --grace-period=0 --wait=true >/dev/null 2>&1 || true

  # Wait for a NEW pod object (different uid) and Ready.
  for i in $(seq 1 90); do
    new_uid=$(kubectl -n $NS get pod $pod -o jsonpath='{.metadata.uid}' 2>/dev/null)
    ready=$(kubectl -n $NS get pod $pod -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
    if [ -n "$new_uid" ] && [ "$new_uid" != "$old_uid" ] && [ "$ready" = "true" ]; then
      new_ip=$(kubectl -n $NS get pod $pod -o jsonpath='{.status.podIP}')
      echo "    new uid=$new_uid new ip=$new_ip" | tee -a "$LOG"
      break
    fi
    sleep 4
  done
  # Extra grace so the leader has published the new state.
  sleep 12
}

snapshot "baseline"
restart_pod opensearch-master-2
snapshot "after_restart_m2"
restart_pod opensearch-master-1
snapshot "after_restart_m1"
restart_pod opensearch-master-0
snapshot "after_restart_m0"
