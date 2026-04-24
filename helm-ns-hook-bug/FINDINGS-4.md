# Helm 3.17.1 — `pre-install` hook 的 namespace + 不帶 `--create-namespace` 也炸

## 直覺 vs 實際

**直覺**：把 namespace 標成 `helm.sh/hook: pre-install`，pre-install 顧名思義「在 install 之前」，所以 hook 應該會比建立 release secret 更早跑、把 ns 建好。

**實際**：hook **連跑都沒跑**。錯誤跟「沒 hook 也不帶 `--create-namespace`」完全一樣：

```
Error: INSTALLATION FAILED: create: failed to create: namespaces "vvv" not found
```

跑兩次也一樣。

## 為什麼

`pkg/action/install.go` 的順序是固定的：

```
401  Releases.Create(rel)          # ← 寫 release secret 進 release ns（這裡死）
408  performInstall(...)
       └─ 447  execHook(HookPreInstall, ...)   # ★ pre-install hook 才在這裡跑
       └─ 456  KubeClient.Create(target)
       └─ 476  execHook(HookPostInstall, ...)
```

**`pre-install` 的「pre」是相對於 `KubeClient.Create(target)` 的（line 456），不是相對於整個 install 流程的開頭**。`Releases.Create` 在 line 401，比 `performInstall` 早，hook 對它無效。

於是：
1. existingResourceConflict（line 353）：ns 不存在，跳過
2. **沒** `--create-namespace`，line 366 整段跳過
3. line 401 `Releases.Create(rel)` → 寫 secret 進 vvv ns → ns 不存在 → **死**
4. line 408 永遠到不了 → pre-install hook 永遠不執行

Stack trace 證實：

```
helm.sh/helm/v3/pkg/storage/driver.(*Secrets).Create   secrets.go:168
helm.sh/helm/v3/pkg/storage.(*Storage).Create          storage.go:69
helm.sh/helm/v3/pkg/action.(*Install).RunWithContext   install.go:401   ← 死在這
```

完全沒有 `execHook` 出現在 stack trace 裡。

## 完整四個 bug 對照表（Helm 3.17.1）

| `--create-namespace` | chart 內 `namespace.yaml` | hook | 結果 | 第二次救得了？ |
|:---:|:---:|:---:|---|:---:|
| ✅ | ✅ | `pre-install` | "STATUS: deployed" 但 release secret 被 hook 的 `before-hook-creation` 連 ns 一起 cascade delete 掉 | ❌ |
| ✅ | ✅ | 無 | `namespaces "xxx" already exists`（單純）／`no Namespace with the name "xxx" found`（chart 還有其他 cluster-scoped helm-owned 資源） | ✅（走 upgrade path） |
| ❌ | ✅ | 無 | `create: failed to create: namespaces "xxx" not found`（連 release secret 都寫不進） | ❌ |
| ❌ | ✅ | `pre-install` | 同上：`create: failed to create: namespaces "xxx" not found`，**hook 根本沒執行的機會** | ❌ |

## 結論

`pre-install` hook **無法**用來「自助」建立 release namespace。helm 在跑任何 hook 之前就已經要存取那個 namespace 來寫 release secret 了。

實務上能跑的還是只剩這幾條：
1. `--create-namespace` + chart 內**不放** namespace.yaml（最標準）
2. 外部先建 ns + `helm install --take-ownership`（v3.17+）
3. 外部先建 ns 並手動加 `app.kubernetes.io/managed-by=Helm` + `meta.helm.sh/release-name/namespace` 標註
