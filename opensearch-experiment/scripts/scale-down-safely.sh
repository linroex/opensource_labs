#!/bin/bash
# Safely scale down OpenSearch master nodes by first excluding them
# from the voting configuration, then waiting for the cluster to acknowledge.
#
# Usage: ./scale-down-safely.sh <namespace> <statefulset> <target_replicas>
set -euo pipefail

NS="${1:?namespace required}"
STS="${2:?statefulset required}"
TARGET="${3:?target replicas required}"

current=$(kubectl -n "$NS" get statefulset "$STS" -o jsonpath='{.spec.replicas}')
echo "current replicas=$current, target=$TARGET"
if [ "$TARGET" -ge "$current" ]; then
  echo "Not a scale-down; use kubectl scale directly for scale-up."
  exit 1
fi

# Nodes that will be removed are the highest ordinals.
to_remove=()
for i in $(seq "$TARGET" $((current-1))); do
  to_remove+=("${STS}-${i}")
done
join=$(IFS=,; echo "${to_remove[*]}")
echo "Will exclude from voting config: $join"

# Issue voting config exclusion via the existing leader.
leader_pod="${STS}-0"
kubectl -n "$NS" exec "$leader_pod" -c opensearch -- curl -sS -X POST \
  "http://localhost:9200/_cluster/voting_config_exclusions?node_names=${join}&timeout=60s"
echo

# Wait until each excluded node appears in voting_config_exclusions and is no
# longer in last_committed_config.
for n in "${to_remove[@]}"; do
  for i in $(seq 1 30); do
    s=$(kubectl -n "$NS" exec "$leader_pod" -c opensearch -- curl -sS \
      "http://localhost:9200/_cluster/state/metadata?filter_path=metadata.cluster_coordination")
    if echo "$s" | grep -q "\"$n\""; then
      echo "  excluded $n acknowledged"
      break
    fi
    sleep 2
  done
done

# Now safe to scale down.
kubectl -n "$NS" scale statefulset "$STS" --replicas="$TARGET"

# After successful scale-down, clean up the exclusions so they don't pile up.
echo "Waiting for terminated pods..."
kubectl -n "$NS" wait --for=delete pod/"${to_remove[0]}" --timeout=120s || true
kubectl -n "$NS" exec "$leader_pod" -c opensearch -- curl -sS -X DELETE \
  "http://localhost:9200/_cluster/voting_config_exclusions?wait_for_removal=false"
echo
echo "Scale-down complete."
