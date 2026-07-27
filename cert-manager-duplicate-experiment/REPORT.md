# cert-manager Duplicate Helm Release Removal Experiment

Question: Two cert-manager Helm releases (different names) were accidentally deployed
into the same namespace. CRDs and leader-election leases exist only once. How do you
remove one release using MANUAL `kubectl` deletion (no `helm uninstall`), and what is
the impact?

All timestamps UTC. All numbers below are taken from files under `results/`.

## 1. Setup summary

- Kubernetes: k3s **v1.24.17+k3s1**, single node, `--disable=traefik --disable=servicelb
  --disable=metrics-server --disable-network-policy --flannel-backend=host-gw`.
  Started via `nohup k3s server` (no systemd). runc oomScoreAdj wrapper installed on the
  bundled runc binary before every server start (required in this sandbox or no pod
  starts). Evidence: `results/00-cluster.txt`.
- cert-manager chart: **jetstack/cert-manager v1.14.7** (appVersion v1.14.7), pinned
  explicitly with `--version`. Evidence: `results/01-chart-version.txt`.
- Two releases installed into namespace `cert-manager`:
  - `cm-a`: `helm install cm-a jetstack/cert-manager -n cert-manager --create-namespace
    --version v1.14.7 --set installCRDs=true`
  - `cm-b`: `helm install cm-b jetstack/cert-manager -n cert-manager --version v1.14.7
    --set installCRDs=false`
  - No resource-name conflict occurred (`results/01-install-conflicts.txt`) — chart
    v1.14.7's resource names are release-name-prefixed, so both installs succeeded
    cleanly side by side. All 6 deployments became Ready.
- Certificate issuance backend: **HashiCorp Vault 1.17.6** dev-mode server run on the
  host (`vault server -dev`, PID tracked, kept running), with a `pki` secrets engine,
  root CA `common_name=experiment-root`, and role `demo` (`allowed_domains=demo.example`,
  `max_ttl=72h`). cert-manager reaches it at `http://192.0.2.2:8200` (node IP), token
  auth via `Secret/vault-token` in namespace `cert-manager`, `ClusterIssuer/vault-issuer`.
  Verified reachable from a pod (`results/02-baseline-cert/vault-reachability-from-pod.json`).
- Important chart-version finding: **cert-manager chart v1.14.7 CRDs carry NO
  `helm.sh/resource-policy: keep` annotation** — only
  `meta.helm.sh/release-name`/`release-namespace` (`results/01-baseline/crd-annotations-certificates.json`).
  This raises the stakes of removing the CRD-owning release: unlike newer charts, there
  is no Helm-side safety net stopping a `helm uninstall cm-a` (or an accidental
  label-selector sweep) from deleting the CRDs outright.

## 2. Observed coexistence behavior

- CRDs (6: certificates, certificaterequests, issuers, clusterissuers, orders, challenges)
  exist exactly once, owned by `cm-a` (`meta.helm.sh/release-name: cm-a`).
  `results/01-baseline/crds-before.txt`.
- Both releases run their own controller/cainjector/webhook Deployments (6 pods total),
  but only ONE of each leader-election Lease exists in `kube-system`:
  `cert-manager-controller` and `cert-manager-cainjector-leader-election`.
  At baseline both leases were held by **cm-a**'s pods
  (`results/01-baseline/leader.txt`, `leases-before.yaml`). cm-b's controller log shows
  it "attempting to acquire leader lease" — i.e. hot standby, never running reconcile
  loops while cm-a holds the lease (`results/01-baseline/standby-controller.log`).
- TWO ValidatingWebhookConfigurations and TWO MutatingWebhookConfigurations exist
  (`cm-a-cert-manager-webhook`, `cm-b-cert-manager-webhook`), both `failurePolicy: Fail`
  (`results/01-baseline/webhookconfigs-before.yaml`). Kubernetes calls BOTH on every
  Certificate/Issuer write — if either points at a dead Service, all such writes fail.
- Baseline Certificate issuance (`demo-cert`, Vault-backed) was processed by **cm-a**
  (CertificateRequest requestor `system:serviceaccount:cert-manager:cm-a-cert-manager`,
  the active leader). Issuer CN confirmed as `experiment-root`
  (`results/02-baseline-cert/demo-cert-tls-openssl.txt`).

## 3. Case 1 — naive kubectl removal of cm-b (wrong order)

Driver: `manifests/case1-naive-removal.sh`. Deliberately deletes cm-b's Deployments
BEFORE its webhook configurations, to show the blast radius of getting the order wrong.

Timeline (`results/markers.log`):
| time | marker |
|---|---|
| 05:59:15 | CASE1_START / CASE1_DEPLOYS_DELETED — `kubectl -n cert-manager delete deploy -l app.kubernetes.io/instance=cm-b` |
| 05:59:20 | first probe FAIL |
| 06:00:41 | last probe FAIL |
| 06:00:45 | CASE1_WEBHOOKCONFIGS_DELETED — `kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/instance=cm-b` |
| 06:00:46 | first probe OK (recovered) |
| 06:00:57 | CASE1_DONE (remaining namespaced/cluster RBAC resources removed) |

**Measured outage window: 05:59:20Z → 06:00:46Z ≈ 86 seconds** (17 consecutive probe
FAILs, `results/04-case1/`, cross-checked against `results/consumer.log` and
`results/06-final/consumer-log-analysis.txt`). Every FAIL during the window was the
identical error (`results/04-case1/naive-window-error.txt`):
```
Error from server (InternalError): Internal error occurred: failed calling webhook
"webhook.cert-manager.io": failed to call webhook: Post
"https://cm-b-cert-manager-webhook.cert-manager.svc:443/validate?timeout=30s":
no endpoints available for service "cm-b-cert-manager-webhook"
```
Root cause: cm-b's ValidatingWebhookConfiguration (`failurePolicy: Fail`) still routed
`cert-manager.io` admission requests to `cm-b-cert-manager-webhook`, whose only backing
pod had just been deleted — so ALL writes to Certificate/Issuer objects cluster-wide
failed (including cm-a's own certificates, since Kubernetes calls both webhook
configurations on every matching write, not just "the right one").

Evidence collected: leases unaffected (cm-a still leader — cm-b was never leader in this
run, so no failover forced by Case 1: `results/04-case1/leases-case1-before.yaml`
vs `leases-after.yaml`), `helm list` still showed `cm-b` deployed even after all its
k8s objects were gone (leftover release secret
`sh.helm.release.v1.cm-b.v1`, `results/04-case1/helm-secrets.txt`), CRDs unchanged
(`crd-list-after.txt` diff-clean against baseline), `demo-cert`'s secret sha256
unchanged (`demo-cert-tls-sha256-after.txt`), and a fresh issuance
`demo-cert2` reached Ready after full removal, Vault cert count went 2→3
(`vault-certs-count-before/after-case1.txt`) — proving the system fully recovered
and cm-a (sole survivor) still functions.

Cleanup: `kubectl -n cert-manager delete secret -l name=cm-b,owner=helm` removed the
leftover Helm release secret; `helm list -n cert-manager` afterward shows only `cm-a`
(`results/04-case1/helm-list-after-cleanup.txt`).

## 4. Case 2 — safe kubectl removal of cm-a (the CRD owner)

cm-b was reinstalled (`--set installCRDs=false`, CASE2_PREP_DONE 06:02:16) before this
case. Driver: `manifests/case2-safe-removal.sh`, removes cm-a's
ValidatingWebhookConfiguration/MutatingWebhookConfiguration FIRST, then Deployments,
then the rest — CRDs explicitly excluded throughout.

Timeline:
| time | marker |
|---|---|
| 06:02:50 | CASE2_START; demo-cert3 created; cm-a webhook configs deleted |
| 06:02:55 | cm-a Deployments deleted |
| 06:03:02 | CASE2_DONE (remaining svc/sa/cm/role/rolebinding/clusterrole/clusterrolebinding removed, `results/05-case2/deleted-resources.txt`) |

**Probe FAILs during the Case 2 window (06:02:50–06:03:02): 0**
(`results/05-case2/`, cross-checked in `results/06-final/consumer-log-analysis.txt`)
— because cm-b's webhook configurations kept serving admission for the entire window;
removing cm-a's webhook configs first meant Kubernetes never had a broken webhook
target to call.

Leader failover (lease evidence, `results/05-case2/leases-case2-after.yaml` +
`results/05-case2/cm-b-controller-leader-acquire.log`):
- `cert-manager-cainjector-leader-election`: acquired by cm-b's cainjector at
  06:03:08.05Z → **13s** after cm-a's Deployments were deleted (06:02:55Z).
- `cert-manager-controller`: acquired by cm-b's controller at 06:03:28.33Z → **33s**
  after cm-a's Deployments were deleted. Confirmed via controller log line
  `"successfully acquired lease kube-system/cert-manager-controller"`.
- Both leases show `leaseTransitions: 1` — a single clean handover.

Functional reconciliation gap (`results/05-case2/reconciliation-gap.txt`):
`demo-cert3`, created at the instant of CASE2_START, was still serviced by cm-a
(requestor `cm-a-cert-manager`, Ready at the same second it was created — cm-a was
alive for 5 more seconds before its Deployments were deleted). `demo-cert4`, created
after CASE2_DONE, was serviced by **cm-b** (requestor `cm-b-cert-manager`) and reached
Ready normally — proving end-to-end issuance kept working across the handover with no
observable gap in this run. `demo-cert`'s original secret hash was unchanged
(`demo-cert-tls-sha256-after-case2.txt`), CRDs remained present
(`crds-after-case2.txt`), Vault cert count went 4→5 for the one new issuance
(`vault-certs-count-before/after-case2.txt`, no unexpected re-issuance observed).

Cleanup: `kubectl -n cert-manager delete secret -l name=cm-a,owner=helm`; final
`helm list -n cert-manager` shows only `cm-b` (`results/06-final/final-helm-list.txt`).

## 5. CRD danger and adoption remediation

- `kubectl get crd -l app.kubernetes.io/instance=cm-a` lists all 6 cert-manager CRDs —
  they belong to cm-a alone, and chart v1.14.7 does not set
  `helm.sh/resource-policy: keep` on them (see section 1).
- `kubectl delete crd -l app.kubernetes.io/instance=cm-a --dry-run=server` (never
  executed for real) confirms all 6 would be deleted
  (`results/05-case2/dryrun-crd-sweep.txt`). Executing this for real would
  cascade-delete every Certificate/CertificateRequest/Issuer/ClusterIssuer/Order/
  Challenge object cluster-wide (both cm-a's and cm-b's, since they share the same
  CRDs) and permanently break cm-b, which has no way to recreate CRDs it never owned.
  Kubernetes Secrets holding already-issued TLS material (e.g. `demo-cert-tls`) are a
  separate core-API resource and would survive as orphaned, unrenewable data.
- Remediation demonstrated: patched `meta.helm.sh/release-name` from `cm-a` to `cm-b`
  on all 6 CRDs (before/after captured in `results/05-case2/crd-adoption.txt`), then
  ran `helm upgrade cm-b jetstack/cert-manager -n cert-manager --version v1.14.7 --set
  installCRDs=true`, which succeeded (`REVISION: 2`, same file) — proving the CRDs are
  now fully "adopted" into cm-b's Helm ownership and would be correctly managed by
  future `helm upgrade`/`helm uninstall cm-b` operations.

## 6. Leftovers of manual (kubectl-only) removal and how to clean each

| Leftover | Why it happens | How to clean |
|---|---|---|
| Helm release secret `sh.helm.release.v1.<name>.vN` stays in the namespace | `kubectl delete` never touches Helm's release-state storage; `helm list` keeps showing the release as "deployed" even though every k8s object is gone | `kubectl -n cert-manager delete secret -l name=<release>,owner=helm` |
| CRDs remain annotated with the removed release's name | CRDs are cluster-scoped and were deliberately excluded from deletion; annotations are stale metadata only | `kubectl annotate crd <crd> meta.helm.sh/release-name=<survivor> --overwrite` on each CRD, then `helm upgrade <survivor> ... --set installCRDs=true` to make Helm's release manifest agree |
| leader-election Lease can briefly show `holderIdentity: ""` mid-handover | The old holder's process exited/lost the lock before a new one grabbed it | Self-heals within `leaseDurationSeconds` (60s here); no action needed, but confirm via `kubectl -n kube-system get lease -o yaml` that a new stable holder appears |
| A transient probe FAIL right after cm-b's own reinstall (06:01:57Z, `results/consumer.log`) | cm-b's brand-new webhook pod was still starting when a write raced it | Not specific to the removal case; wait for the survivor's own webhook Deployment to report Ready before writing |

## 7. Recommended safe manual-removal runbook

To remove Helm release `<victim>` from a namespace shared with another cert-manager
release `<survivor>`, purely with `kubectl` (no `helm uninstall`):

1. Confirm which release is the CRD owner and which holds the leader-election leases:
   `kubectl get crd -l app.kubernetes.io/instance=<victim>`,
   `kubectl -n kube-system get lease -o yaml | grep holderIdentity`.
2. **Delete the victim's webhook configurations FIRST**, before touching its pods:
   `kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/instance=<victim>`.
   This is the single most important ordering rule — skipping it causes a
   cluster-wide admission outage the moment the victim's webhook pod dies (Case 1,
   ~86s in this run).
3. Delete the victim's Deployments:
   `kubectl -n <ns> delete deploy -l app.kubernetes.io/instance=<victim>`.
4. Delete remaining namespaced objects: `service`, `serviceaccount`, `configmap`,
   `role`, `rolebinding`, all `-l app.kubernetes.io/instance=<victim>`.
5. Delete cluster-scoped RBAC: `clusterrole`, `clusterrolebinding`,
   `-l app.kubernetes.io/instance=<victim>`.
6. **Do NOT delete CRDs** even if `-l app.kubernetes.io/instance=<victim>` matches
   them — check with `--dry-run=server` first if unsure, and exclude
   `customresourcedefinition` from any broad label-selector sweep.
7. If `<victim>` owned the CRDs, re-point them at the survivor:
   `kubectl annotate crd <each-crd> meta.helm.sh/release-name=<survivor> --overwrite`,
   then `helm upgrade <survivor> ... --set installCRDs=true` to reconcile Helm's state.
8. Clean up the orphaned Helm release-state secret:
   `kubectl -n <ns> delete secret -l name=<victim>,owner=helm`.
9. Verify: `helm list -n <ns>` shows only `<survivor>`; leases show a single stable
   holder belonging to `<survivor>`'s pods; a fresh Certificate reaches `Ready`.

## 8. Anomalies / deviations from plan

- **Mid-experiment version change**: the experiment was originally started on the
  latest cert-manager chart (v1.21.0) on k3s v1.30.5. Partway through Phase 1 (both
  `cm-a` and `cm-b` already `helm install`ed) a requirement change mandated k8s v1.24,
  cert-manager chart v1.14.x, and Vault-backed issuance instead of selfsigned. The
  entire cluster was torn down (`k3s-killall.sh` + `k3s-uninstall.sh`) and rebuilt from
  scratch on k3s v1.24.17+k3s1, the runc wrapper was re-applied to the newly-unpacked
  runc binary, kubectl was replaced with a matching v1.24.17 client, and cert-manager
  was reinstalled on chart v1.14.7 with `installCRDs=`. All artifacts under `results/`
  are from this final, correct-version run; the abandoned v1.30.5/v1.21.0 run's
  `results/01-chart-version.txt` and install logs were deleted and regenerated.
- `kubectl logs` against the kubelet's `containerLogs` endpoint returned `EOF` for
  every pod in this sandbox (a pre-existing environment quirk, not related to the
  experiment). Worked around by reading container logs directly via `crictl logs
  <container-id>` throughout (used for `results/01-baseline/standby-controller.log`
  and `results/05-case2/cm-b-controller-leader-acquire.log`).
- The Certificate spec required an explicit `commonName` for the Vault `pki/roles/demo`
  role (`require_cn` defaults true); the first `demo-cert` apply failed until
  `commonName: demo-cert.demo.example` was added — reflected in the final
  `manifests/demo-cert.yaml`.
- One incidental probe FAIL (06:01:57Z) occurred during cm-b's CASE2_PREP reinstall
  (its fresh webhook pod briefly not Ready) — not part of either removal Case, noted
  in section 6.
- `results/consumer.log` totals: 75 lines, 57 OK, 18 FAIL (17 from Case 1's naive
  window, 1 from the CASE2_PREP reinstall gap, 0 from Case 2 itself). Max gap between
  consecutive probe lines: 6.0s (i.e. no probe iteration was ever skipped — the 5s
  loop plus kubectl round-trip time). Source: `results/06-final/consumer-log-analysis.txt`.
- The k3s cluster, Vault dev server, and cm-b's cert-manager pods were left RUNNING at
  the end, as instructed.
