#!/bin/bash
# Expose Kibana on localhost:5601. NodePort 30561 is also available on the node IP.
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "Kibana will be reachable at http://localhost:5601"
echo "Create an index pattern 'k8s-*' on first login."
exec kubectl -n logging port-forward svc/kibana 5601:5601 --address=0.0.0.0
