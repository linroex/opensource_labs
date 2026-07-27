#!/bin/bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
LOG=/home/user/opensource_labs/cert-manager-duplicate-experiment/results/consumer.log
while true; do
  ts=$(date -u +%FT%TZ)
  err=$(kubectl -n demo annotate certificate demo-cert probe.ts="$ts" --overwrite 2>&1 1>/dev/null)
  if [ $? -eq 0 ]; then
    echo "$ts OK" >> "$LOG"
  else
    firstline=$(echo "$err" | head -1)
    echo "$ts FAIL $firstline" >> "$LOG"
  fi
  sleep 5
done
