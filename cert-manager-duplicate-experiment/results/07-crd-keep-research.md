# Research: cert-manager Helm chart CRD lifecycle after v1.14

Question: does the cert-manager Helm chart start protecting its CRDs with
`helm.sh/resource-policy: keep` in versions after v1.14.7 (which our own experiment
showed does NOT set it, see `REPORT.md` section 1 and `results/01-baseline/crd-annotations-certificates.json`)?
If so, from which version, how is it configured, exactly what does it protect against,
and what should a v1.14 user do?

Method: 100% client-side. `helm repo update` against the pre-added `jetstack` repo, then
`helm template ... --kube-version=1.24.17` (no live cluster contact) across 11 chart
versions, plus `helm show values` and `helm pull --untar` to inspect the raw chart
templates/`_helpers.tpl`. No `helm install`/`upgrade`/`uninstall` was run, and the
cluster's `cert-manager` namespace was never touched. Cross-checked against cert-manager's
published release notes/docs and Helm's own upstream Go source (`helm/helm` GitHub,
fetched via `WebFetch`/`curl` through the proxy).

All raw evidence files referenced below are in this directory:
`results/07-crd-keep-research/`.

## 1. Version matrix (empirical, from `helm template --set installCRDs=true`)

Rendered the `certificates.cert-manager.io` CRD for 11 chart versions and inspected
`metadata.annotations`/`metadata.labels`. Full per-version blocks:
`results/07-crd-keep-research/crd-metadata-by-version.txt`.

| Chart version | `helm.sh/resource-policy: keep` present by default? | `crds.*` values block exists? | `app.kubernetes.io/component: crds` label? |
|---|---|---|---|
| v1.14.7  | **NO** | No (`installCRDs: false` only) | No |
| v1.15.0  | **YES** | Yes (`crds.enabled: false`, `crds.keep: true`) | No |
| v1.15.5  | **YES** | Yes | No |
| v1.16.0  | **YES** | Yes | No |
| v1.16.5  | **YES** | Yes | No |
| v1.17.0  | **YES** | Yes | No |
| v1.17.4  | **YES** | Yes | No |
| v1.18.0  | **YES** | Yes | No |
| v1.19.0  | **YES** | Yes | Yes (added) |
| v1.20.0  | **YES** | Yes | Yes |
| v1.21.0 (latest at time of research, 2026-07-27) | **YES** | Yes | Yes |

Exact evidence, v1.14.7 vs. v1.15.0 (from `crd-metadata-by-version.txt`):

```yaml
# v1.14.7 — no annotations block at all
kind: CustomResourceDefinition
metadata:
  name: certificates.cert-manager.io
  labels:
    app: 'cert-manager'
    ...
spec:

# v1.15.0 — resource-policy: keep present
kind: CustomResourceDefinition
metadata:
  name: certificates.cert-manager.io
  annotations:
    helm.sh/resource-policy: keep
  labels:
    app: 'cert-manager'
    ...
spec:
```

**First chart version with keep-by-default: v1.15.0** (this is also the first version
where `crds.enabled`/`crds.keep` values exist at all). All 10 subsequent versions tested
through v1.21.0 (current latest) keep the same default. `helm search repo jetstack/cert-manager --versions`
confirms v1.21.0 is the newest chart in the repo as of this research (full list in
scratch output; v1.15.0 through v1.21.0 span the entire "after v1.14" era checked).

## 2. How it's configured

From `helm show values` (v1.15.0 through v1.21.0 are byte-identical on this block):

```yaml
installCRDs: false   # deprecated alias, still works

crds:
  # This option decides if the CRDs should be installed
  # as part of the Helm installation.
  enabled: false

  # This option makes it so that the "helm.sh/resource-policy": keep
  # annotation is added to the CRD. This will prevent Helm from uninstalling
  # the CRD when the Helm release is uninstalled.
  # WARNING: when the CRDs are removed, all cert-manager custom resources
  # (Certificates, Issuers, ...) will be removed too by the garbage collector.
  keep: true
```

Template source confirms the exact conditional (`templates/crd-cert-manager.io_certificates.yaml`,
identical pattern on all 6 CRD templates; captured in
`results/07-crd-keep-research/crd-template-v1.21.0-conditional-header.yaml`):

```yaml
{{- if or .Values.crds.enabled .Values.installCRDs }}
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: "certificates.cert-manager.io"
  {{- if .Values.crds.keep }}
  annotations:
    helm.sh/resource-policy: keep
  {{- end }}
```

- `crds.enabled=false` (default): CRDs not rendered at all — matches `installCRDs=false` behavior in 1.14.
- `crds.enabled=true`: CRDs rendered, and **since `crds.keep` defaults to `true`, the keep
  annotation is present by default** — confirmed by rendering `--set crds.enabled=true`
  alone on v1.15.0 (6 CRDs, all carrying the annotation; same output as `--set installCRDs=true`).
- `crds.enabled=true --set crds.keep=false`: annotation is explicitly suppressed —
  verified empirically (`results/07-crd-keep-research/crd-metadata-v1.21.0-crds.keep=false.yaml`
  shows the CRD rendered with the label block but **no** `annotations:` key at all).
- `installCRDs=true` still works as a deprecated alias through v1.21.0 (confirmed: 6 CRDs
  render identically to `crds.enabled=true`). The chart added a guard in
  `templates/_helpers.tpl` (`cert-manager.crd-check`, present unchanged from v1.15.0
  through v1.21.0, captured in `helpers-v1.21.0-crd-check-excerpt.tpl.txt`) that makes
  Helm **hard-fail the render** if:
  - both `installCRDs=true` and `crds.enabled=true` are set together, or
  - `installCRDs=true` is combined with `crds.keep=false` (i.e. you cannot use the
    deprecated flag to opt out of the keep annotation — the old flag always implies keep).

## 3. Behavior on `helm uninstall` with the keep annotation present

Per Helm's own docs (quoted via WebFetch from
https://helm.sh/docs/howto/charts_tips_and_tricks/):

> "The annotation `helm.sh/resource-policy: keep` instructs Helm to skip deleting this
> resource when a helm operation (such as `helm uninstall`, `helm upgrade` or
> `helm rollback`) would result in its deletion."
>
> "*However*, this resource becomes orphaned. Helm will no longer manage it in any way.
> This can lead to problems if using `helm install --replace` on a release that has
> already been uninstalled, but has kept resources."

So on `helm uninstall` of the CRD-owning release: **the CRD (and its custom resources)
are retained in the cluster, but the CRD becomes untracked/orphaned from Helm** — it no
longer shows up in any release's manifest, `helm list` no longer references it, and a
future chart upgrade that re-adopts it needs the same manual re-labeling dance our main
experiment already demonstrated in `REPORT.md` section 5 (patching
`meta.helm.sh/release-name` + `helm upgrade`).

cert-manager's own install docs (WebFetch, https://cert-manager.io/docs/installation/helm/)
confirm the same behavior in cert-manager-specific terms:

> "the `CustomResourceDefinition` for `Issuers`, `ClusterIssuers`, `Certificates`,
> `CertificateRequests`, `Orders` and `Challenges` are not removed by the Helm uninstall
> command. This is to prevent data loss, as removing the `CustomResourceDefinition` would
> also remove all instances of those resources."
>
> "cert-manager versions prior to `v1.15.0` do not keep the `CustomResourceDefinition` on
> uninstall and will remove all `Issuers`, `ClusterIssuers`, `Certificates`,
> `CertificateRequests`, `Orders` and `Challenges` resources from the cluster."

This exactly corroborates our v1.14.7 experimental finding and pins the fix to v1.15.0.
cert-manager's 1.15 release notes (WebFetch,
https://cert-manager.io/docs/releases/release-notes/release-notes-1.15/) frame it as a
breaking-change / default-behavior flip:

> "From this release, the Helm chart will no longer uninstall the CRDs when the chart is
> uninstalled." / "Add new `crds.keep` and `crds.enabled` Helm options which will replace
> the `installCRDs` option." / "⚠️ Possibly breaking: Helm will now keep the CRDs when you
> uninstall cert-manager by default to prevent accidental data loss." (Restore old
> delete-on-uninstall behavior via `crds.keep=false`.)

## 4. Behavior on `helm upgrade` when `crds.enabled` is later flipped to `false`

This is the "danger" the task asked to check for. There is **no explicit named warning**
in the cert-manager upgrade docs about flipping `crds.enabled` mid-life (checked
https://cert-manager.io/docs/installation/upgrading/ — it only documents the two
supported CRD-management workflows, see section 5 below, with no callout about toggling
the flag). But digging into **Helm's own source** (not cert-manager's) turned up an
important, non-obvious asymmetry relevant to this exact scenario — see
`results/07-crd-keep-research/helm-source-resource-policy-evidence.txt` for full code:

- **`helm uninstall`** (`pkg/action/resource_policy.go` `filterManifestsToKeep`, called
  from `pkg/action/uninstall.go`): checks the annotation on manifests parsed from the
  **stored release manifest text** (`rel.Manifest`, i.e. what Helm rendered and saved at
  the last install/upgrade) — **not** a live `GET` against the cluster.
- **`helm upgrade`**'s resource-pruning step, when a resource that existed in the
  previous release's manifest is absent from the new one (`pkg/kube/client.go`,
  `Client.Update()`, the `originals.Difference(targets)` loop): it does an `info.Get()`
  — a fresh **live GET** — and reads the annotation off that live object.

So: if a release previously rendered the CRD with `crds.keep: true` (the default from
v1.15.0 on), the CRD's live object carries the annotation. If someone later runs
`helm upgrade ... --set crds.enabled=false`, the CRD disappears from the new rendered
manifest, Helm's pruning step live-`GET`s it, sees `helm.sh/resource-policy: keep`, and
**skips deleting it — it is orphaned from that release but left in the cluster**,
consistent with the "prevent accidental data loss" intent stated in the 1.15 release
notes. It is not deleted; it just stops being tracked by any release from that point on
(same orphaning consequence as the uninstall case in section 3).

Net effect: with the default `crds.keep=true` in place since v1.15.0, **neither**
`helm uninstall` of the release **nor** `helm upgrade --set crds.enabled=false` will
delete the CRDs — both paths independently respect the annotation, just via different
mechanisms (stored-manifest read vs. live-object read).

## 5. Upstream recommendation (current docs, v1.21.0-era)

cert-manager's install docs (https://cert-manager.io/docs/installation/helm/) recommend,
as the **primary** method:

```
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.21.0 --namespace cert-manager --create-namespace \
  --set crds.enabled=true
```

i.e. **let Helm manage the CRDs via `crds.enabled=true`**, relying on the `crds.keep=true`
default for safety. This is a reversal from the v1.14.7-era guidance embedded right in
that chart's own `values.yaml` comment (captured verbatim,
`helm show values jetstack/cert-manager --version v1.14.7`):

> "Install the cert-manager CRDs, it is recommended to not use Helm to manage the CRDs"

The upgrade docs (https://cert-manager.io/docs/installation/upgrading/) describe a
**second**, still-supported path for teams that prefer to manage CRDs fully outside Helm:

> "If you have installed the CRDs separately (instead of with the `--set crds.enabled=true`
> option added to your Helm install command), you should upgrade your CRD resources first"
> via `kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/<version>/cert-manager.crds.yaml`,
> then upgrade the chart.

And for the Helm-managed path: "If you have installed the CRDs together with the helm
install command (using `--set crds.enabled=true`), Helm will upgrade the CRDs
automatically when you upgrade the cert-manager Helm chart" — i.e. `crds.enabled=true` is
now presented as the low-effort default, no longer discouraged.

## 6. Guidance for a user currently on chart v1.14.7

**Best fix — upgrade the chart.** Running (client-side dry check first, then for real,
outside this read-only task's scope):

```
helm upgrade <release> jetstack/cert-manager -n cert-manager \
  --version v1.21.0 --set crds.enabled=true
```

on a release that already has CRDs installed will re-render those CRDs and, since they
already exist live, Helm patches them in place — adding
`helm.sh/resource-policy: keep` to both the live objects **and** the stored release
manifest. That closes the gap on *both* the uninstall path (section 3, needs the stored
manifest) and the upgrade-prune path (section 4, needs the live object) in one step. This
is the only change that gets full protection with no caveats.

**If staying on v1.14 (chart version pinned, no upgrade allowed yet):**

- `kubectl annotate crd <name> helm.sh/resource-policy=keep` on the six live CRDs **does**
  protect against a *future* `helm upgrade` that stops rendering the CRDs (e.g. if
  `installCRDs` is later flipped to `false` on an upgrade) — verified against Helm's
  source in section 4, because that code path does a live annotation check.
- It does **NOT** protect against `helm uninstall` of the CRD-owning release, because
  `uninstall`'s `filterManifestsToKeep` (section 4) reads the annotation from the
  **stored release manifest**, and v1.14.7's rendered manifest has no such annotation —
  a live-only `kubectl annotate` never gets baked into what's stored for that release. To
  close that gap while genuinely staying on v1.14.7's chart, you'd have to vendor/patch a
  local copy of the chart's CRD templates to add the annotation and `helm upgrade` with
  that local chart (so the annotation lands in the stored manifest) — there is no
  values-only way to do this on v1.14.7, since that chart version has no `crds.keep`
  option at all.
- Either way, the annotation is a **Helm-only convention**. It has zero effect on a raw
  `kubectl delete crd -l ...` label sweep (the same kind of operation our main experiment
  flagged as a risk) — that bypasses Helm's delete code entirely. The only real mitigation
  for that risk is operational (restrict who can run cluster-scoped `kubectl delete crd`,
  or use a validating admission policy / OPA Gatekeeper rule blocking CRD deletion) —
  Helm's annotation can't help there regardless of chart version.
- Practically: **upgrading is strictly better** than any live-annotation workaround, since
  v1.15.0+ closes both gaps by default with zero extra flags beyond `crds.enabled=true`.

## 7. Files in this research directory

- `crd-metadata-by-version.txt` — rendered `certificates.cert-manager.io` CRD metadata for
  all 11 tested chart versions, `--set installCRDs=true`.
- `crd-metadata-v1.21.0-crds.keep=false.yaml` — proof that `crds.keep=false` suppresses
  the annotation even with `crds.enabled=true`.
- `crd-template-v1.21.0-conditional-header.yaml` — the Go-template conditional
  (`{{- if .Values.crds.keep }}`) controlling the annotation.
- `helpers-v1.21.0-crd-check-excerpt.tpl.txt` — the `cert-manager.crd-check` guard that
  hard-fails `installCRDs`+`crds.enabled` conflicts.
- `helm-source-resource-policy-evidence.txt` — Helm upstream Go source (`pkg/action/resource_policy.go`,
  `pkg/kube/client.go`, `pkg/kube/resource_policy.go`) documenting the uninstall
  (stored-manifest) vs. upgrade-prune (live-GET) asymmetry described in section 4.
