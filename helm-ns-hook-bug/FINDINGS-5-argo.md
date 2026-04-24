# 為什麼一樣的 chart 在 Argo CD 上跑得起來？

## 一句話結論

**Argo CD 根本不呼叫 `helm install`，它只用 `helm template` 把 chart 渲染成 YAML，然後由它自己的 apply engine（gitops-engine）依靠 kind 排序去 apply**。所以 helm 的 `install.go:401 Releases.Create` 那一行（你卡住的地方）根本不會被執行 —— **Argo 不寫 helm release secret**。

## 證據（Argo CD source）

- `util/helm/cmd.go` 的 `func (c *Cmd) template(...)` 組 args 是這樣開頭的：
  ```go
  args := []string{"template", chartPath, "--name-template", opts.Name}
  ```
  接著條件性加 `--namespace`、`--kube-version`、`--set`、`--values`、`--api-versions`、`--include-crds` 等，最後 `c.run(ctx, args...)`。**完全沒有 `install` 或 `upgrade` 字串出現在這個檔案。**

- `util/helm/helm.go` 的 `Template()`：
  ```go
  out, command, err := h.cmd.template(".", templateOpts)
  ```

- `reposerver/repository/repository.go` 的 `GenerateManifests()` 處理 `case v1alpha1.ApplicationSourceTypeHelm:` 時，呼叫 `helmTemplate(...)` → `h.Template(...)`。

渲染出來的 YAML 是純文字流，然後 parse 成 `[]*unstructured.Unstructured` 交給 gitops-engine。

## gitops-engine 怎麼 apply 這堆東西

`github.com/argoproj/gitops-engine/pkg/sync/sync_context.go` 的同步流程：
1. **Phase 排序**：PreSync → Sync → PostSync
2. **每個 phase 內部 kind 排序**：`Namespace` 排在 `ConfigMap`、`Deployment` 等 namespaced 資源**前面**
3. 用 kubectl-style apply / SSA 直接打 K8s API 建出來

所以你 chart 裡 `templates/namespace.yaml` 渲染出來的 Namespace，會先被 Argo 建好；之後同一輪同步裡 namespaced 的資源就能正常進去 —— 完全繞開 helm CLI 的順序問題。

## `--namespace xxx` 在兩邊的語意完全不同

| 工具 | 旗標 | 對 K8s 做了什麼 |
|---|---|---|
| `helm install --namespace xxx` | 馬上呼叫 K8s API 寫 release secret 到 `xxx` ns（如果 ns 不存在就炸） | |
| `helm template --namespace xxx` | **完全沒碰 K8s API**。只把 `.Release.Namespace` 設成 `xxx` 餵給 template engine 渲染。|

Argo CD 用的是後者，所以「ns 還沒存在」對它來講根本不是問題 —— 渲染階段不需要 K8s。

## `syncOptions: CreateNamespace=true` 不是傳給 helm 的

很多人會以為 Argo 的 `CreateNamespace=true` 對應 `helm install --create-namespace`，**錯**。它是 gitops-engine 自己做的事：`pkg/sync/sync_context.go` 的 `autoCreateNamespace` 函式自己用 Go 建一個 `corev1.Namespace` 物件、check 存在、用 PreSync phase 去 apply 它。

所以你的情境（Argo 沒打開 `CreateNamespace`、chart 內有 namespace.yaml）能跑：
- 沒走 `autoCreateNamespace` → Argo 不主動 pre-create ns
- 但 chart template 渲染出 Namespace manifest → 進到 Sync phase 的 manifest list
- gitops-engine 依 kind 排序：Namespace 排在 namespaced 資源前面 → 先 apply Namespace → 之後 apply 其他資源 → 全部成功

而且因為 Argo 不需要 helm release secret，**這個 bug 在 Argo 流程下根本不存在**。

## 對你目前的情境

你之前在 helm CLI 看到的所有錯誤（`namespaces "xxx" not found`、`already exists`、`no Namespace with the name`、release secret 消失）**都源自 helm 自己要把 release 狀態存在 K8s 裡 (`sh.helm.release.v1.*` secret)** 這個設計。Argo CD 用 git 當 source of truth、用自己的 apply engine 維護 sync state，**不依賴 helm release secret**，所以那條 code path 根本不會被觸發。

換句話說：你 chart 裡 `templates/namespace.yaml` 的設計**對 Argo CD 是合理的**，是 helm CLI 那邊的設計卡住自己。

## 實務影響

這也是為什麼很多 Helm chart 作者會把 namespace 放在 templates 裡 —— 在 GitOps 流程下這完全合理（甚至更乾淨：所有資源都在 chart 裡描述）。但同一個 chart 換到 helm CLI 就會炸。這算是 helm CLI 跟 GitOps 工具之間長年的設計斷層。

## 來源

- `argoproj/argo-cd: util/helm/cmd.go` `template()`（約 L413-477）
- `argoproj/argo-cd: util/helm/helm.go` `Template()`（約 L73-77）
- `argoproj/argo-cd: reposerver/repository/repository.go` `helmTemplate()`（約 L1700）, `GenerateManifests()`（約 L2100）
- `argoproj/gitops-engine: pkg/sync/sync_context.go` `autoCreateNamespace`（約 L1266-1310）
