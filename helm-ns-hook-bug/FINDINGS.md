# Helm 3.17.1 — pre-install hook on Namespace deletes release secret

## 症狀

```bash
helm upgrade --install --create-namespace --namespace xxx app ./chart
# → STATUS: deployed 顯示成功
# → 但 helm list -A 找不到 release
# → kubectl -n xxx get secrets 看不到 sh.helm.release.v1.app.v1
```

只有當 `templates/namespace.yaml` 含 `annotations: "helm.sh/hook": pre-install` 時才會發生。

## 重現步驟 (Helm v3.17.1 + k3s v1.30.5)

```bash
helm version  # v3.17.1
kubectl delete ns xxx --ignore-not-found
helm upgrade --install --create-namespace --namespace xxx app ./chart --debug
```

關鍵 debug log：

```
client.go:142 creating 1 resource(s)                # 建 namespace hook
client.go:486 Starting delete for "xxx" Namespace   # 又把它刪了 <-- 關鍵
wait.go:104   beginning wait for 1 resources to be deleted
action.go:368 warning: Failed to update release app: update: failed to update: secrets "sh.helm.release.v1.app.v1" not found
install.go:495 failed to record the release: ... secrets "sh.helm.release.v1.app.v1" not found
```

## 根本原因（Helm v3.17.1 source）

執行順序（`pkg/action/install.go`）：

1. L313  `createRelease(...)` — 組 release 物件
2. L366  `if i.CreateNamespace { ... KubeClient.Create(namespace) ... }` — `--create-namespace` 先用 k8s API 把 `xxx` ns 建起來
3. L401  `i.cfg.Releases.Create(rel)` — **把 release 以 Secret 形式寫進 `xxx` ns**（`sh.helm.release.v1.app.v1`，status=pending-install）
4. L447  `execHook(rel, HookPreInstall, ...)`

`execHook` (`pkg/action/hooks.go` L45–57) 每個 hook 做兩步：

```go
// L47-53: 使用者沒指定 delete policy → 預設 before-hook-creation
if len(h.DeletePolicies) == 0 {
    h.DeletePolicies = []release.HookDeletePolicy{release.HookBeforeHookCreation}
}

// L55: 先跑 before-hook-creation 的刪除
if err := cfg.deleteHookByPolicy(h, release.HookBeforeHookCreation, timeout); err != nil {
    return err
}
```

`deleteHookByPolicy` (L125–149)：

```go
_, errs := cfg.KubeClient.Delete(resources)       // 刪除該 hook 對應的資源
// ...
kubeClient.WaitForDelete(resources, timeout)      // 同步等完全刪除
```

## 爆炸連鎖

1. 步驟 2：`xxx` namespace 已由 `--create-namespace` 建立
2. 步驟 3：release secret `sh.helm.release.v1.app.v1` 放進 `xxx` 內
3. 步驟 4：pre-install hook `namespace.yaml` 執行。預設 delete policy = `before-hook-creation`
4. Helm 呼叫 `Delete(Namespace xxx)`，然後 `WaitForDelete` 同步等到 ns 真的消失
5. k8s 刪 ns 會 **cascade delete** 底下所有資源 → release secret 一起被刪
6. Helm 重新建 ns（hook）、建 configmap、做完 post-install
7. 最後 `recordRelease` 試圖把 release 狀態從 pending-install 更新成 deployed → **找不到 secret**，只印 warning，然後退出
8. 退出時印的訊息是 `STATUS: deployed`（因為 in-memory 的 `rel` 物件是 deployed），但實際上 etcd 裡什麼都沒有 → `helm list` 空空如也

## 驗證

把 `helm.sh/hook-delete-policy` 覆寫成不包含 `before-hook-creation` 的值（例如 `hook-failed`），Helm 就不會刪 ns：

```yaml
annotations:
  "helm.sh/hook": pre-install
  "helm.sh/hook-delete-policy": "hook-failed"
```

但這時 hook 自己建 namespace 會撞到 `--create-namespace` 已經建好的那個 → hook 失敗 → release 被標記成 `failed`，不過 **release secret 仍然存在、`helm list` 看得到**。

## 結論與建議

此為 **usage bug**（同時使用 `--create-namespace` 與把 namespace 放進 `templates/` 當 pre-install hook 形成的衝突），但 Helm 沒檢查此狀況就預設刪除 → 炸掉自己的 release secret。

**解法（擇一）**：
- 移除 `helm.sh/hook: pre-install`，讓 namespace 當作普通 manifest 被管理（但 --create-namespace 比它先執行，要考量 manifest 順序／adoption）
- 不要把 namespace 放 chart 裡，用 `--create-namespace` 或手動建立
- 保留 hook，但設 `helm.sh/hook-delete-policy` 排除 `before-hook-creation`，並拿掉 `--create-namespace`

最乾淨的作法：**不要同時依賴 `--create-namespace` 跟把 namespace 放進 chart templates**。兩者只選一個。

## 關鍵檔案位置

- `pkg/action/install.go:366-390` — `--create-namespace` 的實作
- `pkg/action/install.go:401` — release secret 寫入
- `pkg/action/install.go:447` — pre-install hook 執行點
- `pkg/action/hooks.go:45-57` — 預設 delete policy = `before-hook-creation`
- `pkg/action/hooks.go:136-146` — Delete + WaitForDelete
- `pkg/kube/client.go:486` — log 訊息 `Starting delete for %q %s`
