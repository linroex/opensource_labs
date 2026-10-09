#!/usr/bin/env bash
# Sandbox workaround (only needed where the Docker host lacks CAP_SYS_RESOURCE):
# runc cannot write a negative oom_score_adj, so every pod sandbox fails with
#   "failed to update /proc/self/oom_score_adj: Permission denied".
# Wrap runc inside the k3d node(s) to reset oomScoreAdj to 0 in the OCI bundle.
# Safe to run repeatedly; harmless on a normal Docker host (just not required).
set -euo pipefail

CLUSTER="${1:-cm-vault}"

for node in $(docker ps --format '{{.Names}}' | grep -E "^k3d-${CLUSTER}-(server|agent)-[0-9]+$"); do
  if docker exec "$node" test -f /bin/runc.real; then
    echo "[$node] runc already wrapped"
    continue
  fi
  docker exec "$node" sh -c '
    mv /bin/runc /bin/runc.real
    cat > /bin/runc <<"WRAPPER"
#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev" = "--bundle" ] || [ "$prev" = "-b" ]; then
    [ -f "$a/config.json" ] && sed -i -E "s/\"oomScoreAdj\":-?[0-9]+/\"oomScoreAdj\":0/" "$a/config.json"
  fi
  prev="$a"
done
exec /bin/runc.real "$@"
WRAPPER
    chmod +x /bin/runc'
  echo "[$node] runc wrapped"
done
