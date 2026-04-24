# Helm 3.17.1 — `--create-namespace` + 一般 Namespace template 在第一次 install 會炸

## 症狀（使用者描述）

```bash
helm install --create-namespace --namespace xxx app ./chart
# → Error: no Namespace with the name "xxx" found
# → 但 namespace xxx 已被建立（只有 ns）
# → 第二次再執行就成功
```

## 重現結論

**兩種錯誤訊息、同一個根因**，視 chart 是否還有其他 cluster-scoped 資源而定。

### Manifestation A — chart 只有 Namespace template

```
Error: INSTALLATION FAILED: 1 error occurred:
	* namespaces "zzz" already exists
```

- release 會被記成 `failed`（`helm list -A` 看得到 `STATUS=failed`）
- ns 被建立，但**沒有** helm ownership labels
- 第二次用 `helm upgrade --install` 會進 upgrade path → 成功

### Manifestation B — chart 還有一個已存在、且帶 helm ownership 的 cluster-scoped 資源（例如 ClusterRole 從上次失敗/外部工具留下）

```
Error: INSTALLATION FAILED: no Namespace with the name "ttt" found
```

**這個就是使用者看到的字串。** 複製路徑見 `chart4/` + 預先建立帶 `app.kubernetes.io/managed-by=Helm` 標籤的 ClusterRole。

## 根因：`pkg/action/install.go` 操作順序錯

```
313  rel := createRelease(...)
316  renderResources(...)
332  resources := KubeClient.Build(rel.Manifest)             // target list（含 Namespace + 其他資源）
338  resources.Visit(setMetadataVisitor(...))                // 把 helm labels/annotations 加到 *in-memory* target

349  if !ClientOnly && !isUpgrade {
353      toBeAdopted, err = existingResourceConflict(resources, ...)   // (1) 先檢查衝突
     }
366  if CreateNamespace {
387      KubeClient.Create(namespaceObj)                              // (2) 再建 namespace
     }
401  Releases.Create(rel)                                            // (3) 寫 release secret

408  performInstall(rel, toBeAdopted, resources)
     └─ 455  if len(toBeAdopted) == 0 && len(resources) > 0:
        456      KubeClient.Create(resources)                         // (4a)
        457  else if len(resources) > 0:
        458      KubeClient.Update(toBeAdopted, resources, force)     // (4b)
```

### 關鍵「不變式」被打破

在 `existingResourceConflict`（`pkg/action/validate.go:65`）執行時，namespace 根本還沒存在：

```go
func existingResourceConflict(resources, ...) (toBeAdopted, err) {
    for each info in target:
        existing := helper.Get(info.Namespace, info.Name)
        if IsNotFound(existing): continue        // <-- ns 還沒建，跳過 → 不會進 toBeAdopted
        if checkOwnership(existing, ...) != nil:
            return error
        toBeAdopted.Append(info)
}
```

Namespace 被跳過 → 不在 `toBeAdopted` 裡。

緊接著 step (2) 用 `--create-namespace` 的程式碼**直接**呼叫 `KubeClient.Create` 建了 ns，但**沒再把它放進 `toBeAdopted`**。

於是 step (4) 碰到：target 裡有 Namespace、cluster 裡有 Namespace、但 `toBeAdopted` 裡沒有 Namespace。兩個 branch 都爆：

### 4a — `Create` 路徑（toBeAdopted 空）

`pkg/kube/client.go` 的 `Create` 會對每個 target resource 呼叫 Kubernetes 的 create API。Namespace 已經存在 → k8s 回 `AlreadyExists` → 錯誤訊息 **`namespaces "xxx" already exists`**。

### 4b — `Update` 路徑（toBeAdopted 非空：例如 ClusterRole 被 adopt）

`pkg/kube/client.go:389` `Update(original=toBeAdopted, target=resources)`：

```go
for each info in target:
    if helper.Get(info) fails with NotFound:
        createResource        // 走這邊
        continue
    originalInfo := original.Get(info)      // 在 toBeAdopted 找
    if originalInfo == nil:
        return errors.Errorf("no %s with the name %q found", kind, info.Name)   // <-- ★ 就是這行
    updateResource(..., originalInfo, ...)
```

對 Namespace `xxx`：
- `helper.Get("xxx")` 成功（剛剛 `--create-namespace` 建好）
- `original.Get(info)` → nil（`toBeAdopted` 只有 ClusterRole）
- → 回傳 **`no Namespace with the name "xxx" found`** ← **使用者看到的字串來源**

## 為什麼「第二次就成功」

第一次失敗後：
- ns 已經被建立（只有 `name=xxx` label，沒 helm ownership）
- release secret `sh.helm.release.v1.app.v1` 已寫入 → `helm list -A` 看得到 `failed`

第二次用 `helm upgrade --install`：
- release 已有歷史 → 走 `upgrade.go`，不走 `install.go`
- upgrade path 完全不走 `existingResourceConflict(target)` 的 Namespace 檢查（它只檢查「相對於 current release 新增」的資源，見 `upgrade.go:334-344`）
- 直接對 Namespace 做 Patch（`client.go:701` log：`Patch Namespace "zzz" in namespace`）
- 順帶把 helm ownership labels/annotations 補上 ← 以後都沒事

## 相關程式碼位置一覽

| 行為 | 檔案 | 行號 |
|---|---|---|
| install 主流程 | `pkg/action/install.go` | 313–498 |
| existingResourceConflict 呼叫點 | `pkg/action/install.go` | 353 |
| `--create-namespace` 建 ns | `pkg/action/install.go` | 366–390 |
| 決定 Create / Update | `pkg/action/install.go` | 455–459 |
| `existingResourceConflict` 實作 | `pkg/action/validate.go` | 65–92 |
| `checkOwnership` | `pkg/action/validate.go` | 94–122 |
| `Client.Update` 裡的 "no X with the name" | `pkg/kube/client.go` | 400–421 |
| `ResourceList.Get` | `pkg/kube/resource.go` | 51–58 |

## 修法 / workaround

1. **最乾淨：不要同時用 `--create-namespace` 和 chart templates 裡的 namespace**。兩者擇一。
   - 想在 namespace 加 annotation：拿掉 `--create-namespace`，直接用 template，但 namespace 在 release uninstall 時會被刪（Helm 會當作 release 一部分）
   - 或是 namespace 完全交給外部管理（手動 `kubectl apply`、GitOps 等），helm chart 裡不要放

2. **保留現在結構但吞掉錯誤**：第一次失敗後再跑一次 `helm upgrade --install`，進 upgrade path 就能成功（官方 workaround，本身就是 bug 的副作用）。

3. **Upstream 修法思路**（給 helm PR 用）：
   - `existingResourceConflict` 的 target 遍歷應該**排除**正在要被 `--create-namespace` 建立的 ns（它邏輯上屬於「helm 自己要建的」）；或
   - 在 `--create-namespace` 建完之後，把那個 Namespace info 補進 `toBeAdopted`，並在 cluster 側也補上 helm ownership labels
