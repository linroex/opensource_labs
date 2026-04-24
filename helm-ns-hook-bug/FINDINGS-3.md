# Helm 3.17.1 — 拿掉 `--create-namespace` 也炸（第三個 manifestation）

## 你的問題

> 拿掉 `--create-namespace`，由 chart 管 namespace（會隨 release 一起被刪）  
> 我好像會遇到 helm 反映說該 namespace 不存在

**確認重現**。比前兩個 bug 還要嚴重 —— 第二次再跑也救不了。

## 重現

```bash
# chart3/templates/namespace.yaml 是普通 Namespace template（無 hook）
helm install --namespace uuu app ./chart3
# Error: INSTALLATION FAILED: create: failed to create: namespaces "uuu" not found
```

特徵：
- ns `uuu` 完全沒被建立
- release secret 也沒寫入（沒地方寫）
- `helm list -A` 完全空
- **再跑第二次同樣失敗**，沒有自動恢復路徑

## 根因（`pkg/action/install.go` 同一段，但卡在更早的位置）

執行順序：

```
332  resources := KubeClient.Build(rel.Manifest)    // target list（含 Namespace）
338  setMetadataVisitor                              // 加 helm labels 到 in-memory target
353  existingResourceConflict(resources)            // ns 不存在 → 跳過 → toBeAdopted = []

366  if CreateNamespace {  ... }                    // ★ 沒帶 --create-namespace → 完全跳過

401  Releases.Create(rel)                            // ← 試圖把 release secret 寫進 ns uuu
                                                      //   呼叫 storage/driver/secrets.go:163
                                                      //   k8s API 回 namespaces "uuu" not found
                                                      //   wrap 成 "create: failed to create"
405  return rel, err                                 // 整個流程在這裡死掉
```

`pkg/storage/driver/secrets.go:163-168`：

```go
if _, err := secrets.impl.Create(ctx, obj, metav1.CreateOptions{}); err != nil {
    if apierrors.IsAlreadyExists(err) { return ErrReleaseExists }
    return errors.Wrap(err, "create: failed to create")    // ← 你看到的字串
}
```

關鍵：**release secret 必須寫進 release namespace，但 helm 沒先去確保那個 namespace 存在**。  

`--create-namespace` 是唯一能在這個 step 之前先把 ns 建起來的機制。一旦關掉它，且 chart 又把 namespace 放在 templates 裡（templates 要等 `Releases.Create` 之後的 `performInstall` 才會被 apply），就一定卡死。

跟前兩個 bug 一樣的 root cause 結構：**install.go 的順序假設「namespace 一定存在」，但它把實際確保 ns 存在的責任全部丟給 `--create-namespace`，沒考慮 chart 內部的 Namespace template**。

## 為什麼第二次再跑也救不了

前兩個 bug 第二次能成功是因為：
- Bug 2A/2B：第一次失敗會把 release secret 寫進 ns（即使最終回報 failed），第二次走 upgrade path

這個 case 連 `Releases.Create(rel)` 都失敗 → 沒有任何 release 歷史 → 第二次永遠走 install path → 永遠卡在同一行。

## 試過的「救援」路徑

| 嘗試 | 結果 |
|---|---|
| 跑第二次 `helm install` | ❌ 同樣錯誤 |
| 先 `kubectl create namespace uuu` 再 `helm install` | ❌ `Namespace "uuu" exists and cannot be imported into the current release: invalid ownership metadata` （`existingResourceConflict` 把它當衝突） |
| 先 `kubectl create ns uuu` + `helm install --take-ownership` | ✅ 成功（v3.17.0+ 才有 `--take-ownership`） |
| 先建好帶 helm ownership labels/annotations 的 ns，再 `helm install`（沒 `--create-namespace`、沒 `--take-ownership`） | ✅ 成功 |
| 不建 ns，直接 `helm install --take-ownership`（沒 `--create-namespace`） | ❌ 一樣 `namespaces "uuu" not found`，因為還是卡在 `Releases.Create(rel)` |

唯一能用的兩條路：
1. **`--take-ownership` + 預先建 ns**（手動或交給 GitOps）
2. **預先建 ns + 在 ns 上手動加 helm ownership labels/annotations**

兩種都需要外部先把 ns 建好，**chart 裡的 namespace.yaml 等於完全沒用**（甚至會礙事）。

## 完整三個 bug 的對照

| 設定 | 結果 | 第二次能否救活 |
|---|---|---|
| `--create-namespace` + chart 有 ns template + `helm.sh/hook: pre-install` | "STATUS: deployed" 但 release secret 被自己刪 (`helm list` 空) | ❌（每次都這樣） |
| `--create-namespace` + chart 有 ns template（無 hook） | `namespaces "xxx" already exists` 或 `no Namespace with the name "xxx" found` | ✅（第二次走 upgrade path） |
| **沒** `--create-namespace` + chart 有 ns template | `create: failed to create: namespaces "xxx" not found` | ❌（連 release secret 都沒能寫） |

## 結論

「`--create-namespace` 與 chart 內 namespace.yaml 兩者擇一」這句話**單獨拿掉 `--create-namespace` 不成立**：在 Helm 3.17.1 裡，chart templates 內的 Namespace 既不能單獨負責建立 ns，也不能跟 `--create-namespace` 共存。實務上能跑的組合是：

| ns 由誰建 | helm 旗標 | chart 裡是否放 namespace.yaml | 行為 |
|---|---|---|---|
| `--create-namespace` | （預設） | **不要放** | ✅ 標準路徑，但 ns 不會在 uninstall 時被刪 |
| 外部（kubectl/GitOps） | `--take-ownership` | 可放可不放 | ✅ 但 ns 變成 helm 管的，uninstall 會把它刪 |
| 外部（已帶 helm 標註） | （預設） | 可放可不放 | ✅ 同上 |
| chart templates 自己建 | （任何） | 放 | ❌ 三種都會炸 |

換句話說：**Helm 3.17.1 的設計就是不允許 chart templates 內的 Namespace 單獨負責建立 release namespace**。你想加 annotation 在 ns 上的需求，在這個版本下只能靠外部（kubectl / kustomize / Argo / kubectl create -f）先建好那個帶 annotation 的 ns，然後再讓 helm 接手（`--take-ownership` 或預先放好 helm 標註）。
