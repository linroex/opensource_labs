#!/bin/bash
# Quick sanity check that logs are reaching Elasticsearch.
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

ES="kubectl -n logging exec elasticsearch-0 -c elasticsearch -- curl -s"

echo "== Cluster health =="
$ES http://localhost:9200/_cluster/health | jq '{status,number_of_nodes,active_primary_shards}'

echo ""
echo "== Indices =="
$ES "http://localhost:9200/_cat/indices?v"

echo ""
echo "== Doc counts per namespace =="
$ES -H 'Content-Type: application/json' "http://localhost:9200/k8s-*/_search" -d '{
  "size":0,
  "aggs":{"by_ns":{"terms":{"field":"kubernetes.namespace_name.keyword","size":20}}}
}' | jq '.aggregations.by_ns.buckets'

echo ""
echo "== One sample document =="
$ES "http://localhost:9200/k8s-*/_search?size=1" | jq '.hits.hits[0]._source | {timestamp:."@timestamp", ns: .kubernetes.namespace_name, pod: .kubernetes.pod_name, message}'
