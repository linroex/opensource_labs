# 實驗：切換 VSO 的 Vault endpoint (IP ↔ domain，同一座 Vault) 對 application 的影響

對 **ricoberger/vault-secrets-operator (VSO) v1.26.0** 做的經驗實驗：當 operator 的 `VAULT_ADDRESS`
從 IP 換成 domain（或 A domain 換 B domain，但其實連的是同一座 Vault）時，掛載該 secret 的
application 會不會受影響、secret 會不會消失、短暫讀不到，或其他沒考慮過的可能。

## 環境

| 元件 | 版本 / 設定 |
|---|---|
| Kubernetes | **v1.31.14+k3s1**（單節點 k3s，sandbox 內） |
| Vault | `hashicorp/vault:1.18`，dev 模式，KV v2 (`kvv2/`)，token auth (root) |
| VSO | `ghcr.io/ricoberger/vault-secrets-operator:v1.26.0`，token auth，`reconciliationTime=30s`，`VAULT_RENEW_TOKEN=false`(註1) |
| 「同一座 Vault、不同 endpoint」 | 單一 Vault pod，前面掛多個 Service：`vault`(ClusterIP=IP)、`vault.vault.svc`(domainA)、`vault-b.vault.svc`(domainB)、`vault-missing.vault.svc`(後補) |

> 註1：dev 的 root token 不可續租，會讓 VSO 的 token-renew 迴圈持續失敗、累積到 liveness 門檻而重啟 pod，
> 這與「位址切換」無關。為隔離變因把 renew 關掉。生產環境用可續租的 periodic token 即無此雜訊。

兩個 VaultSecret / 兩個持續讀取的 consumer（每 5s 讀掛載檔、印 hash 或 FAIL）：
- `helloworld` → 一般 secret（`foo=bar`），consumer 量 `hash`。
- `templated` → **用 `{% .Vault.Address %}` 模板**把 Vault 位址寫進 secret 內容，consumer 量 `addr`。

## 程式碼層級的機制（先看原始碼，再用實驗驗證）

1. **位址只在 operator 啟動時讀一次**：`VAULT_ADDRESS` → `vault/vault.go:74,106` → 在 `main.go:60`
   (`InitSharedClient`) 建立 shared client 後固定。**改位址必須重啟 VSO pod 才生效。**
2. **下游 K8s Secret 由 VaultSecret CR 透過 ownerReference 擁有** (`vaultsecret_controller.go:197`)；
   fetch 失敗只 requeue + 在 CR 標 `FetchFailed` (`:158-159`)，**不刪除、不清空既有 Secret**。
   Secret 只有在 CR 被刪除時才被 GC 回收。
3. **資料一致就跳過更新** (`:242-243`)：同一座 Vault → 讀回的 data 相同 → "Skip updating a Secret"，
   連 Secret 的 `resourceVersion` 都不動。
4. **模板陷阱** (`:335`)：`runTemplate` 把 `os.Getenv("VAULT_ADDRESS")` 當 `.Vault.Address` 注入。
   secret 內容內嵌位址 → 改位址會讓 data 真的改變 → 觸發 update → 掛載檔案內容變動。

## 情境與實測結果

切換一律用 `helm upgrade --set vault.address=...`，這會 **rollout 一顆新的 VSO pod**（位址才會生效）。

| # | 切換 | helloworld（一般 secret） | templated（含 .Vault.Address） | application 觀察 |
|---|---|---|---|---|
| S1 | IP → domainA | `Skip updating`，rv 不變(684)，`foo=bar` 不變 | `Updating`，`addr` IP→domainA | consumer 零 FAIL，hash 不變 |
| S2 | domainA → domainB | rv 不變(684) | `addr`→domainB | 零 FAIL，hash 不變 |
| S3a | → **不存在的 domain** | CR=`FetchFailed`(DNS no such host)，**secret 仍在**、rv 不變 | CR=`FetchFailed`，**secret 仍在**、保留最後good值(domainB) | 零 FAIL，hash 不變 |
| S3b | 補上 `vault-missing` Service | ~15s 後 `Updated` 自動恢復 | 自動恢復，`addr`→vault-missing | 零 FAIL（全程未中斷） |
| S5 | 改 deployment env **但不重啟 pod** | 既有 pod env 仍是舊值、仍連舊位址 | 同左 | 無任何變化（位址未生效） |

### 量化驗證（`results/` 內的 log 與快照）
- **FAIL 次數：0 / 0**（兩個 consumer 全程沒有一次讀不到 secret）。
- helloworld consumer：81 個樣本，**最大取樣間隔 6.0s**（迴圈 5s + jitter，無漏樣、無空窗）。
- helloworld 只出現**單一 hash `37b51d19`**；`foo=bar` 在 baseline/S1/S2/S3broken/S3recovered **五份快照完全相同**。
- templated 的 `addr` 隨每次切換改變：
  `IP → domainA → domainB →（broken 期間保留 domainB）→ vault-missing`。
- **模板情境的傳播延遲**：S1 時 Secret 物件在 `04:38:09Z` 被更新，但掛載檔案到 `04:39:12Z` 才翻成新位址
  → **約 63s 的 kubelet mount 刷新延遲**（secret 物件變更與 pod 內檔案更新之間的正常落差）。

## 結論

**對「同一座 Vault」改 endpoint（IP↔domain、A↔B domain），只要新位址可達，掛載 secret 的
application 不會受影響：secret 不會消失、不會變空、值不變、也沒有任何一刻讀不到。**
原因是下游 K8s Secret 由 CR 以 ownerReference 擁有，VSO 在 reconcile 失敗時不會去動既有 Secret，
而且同一座 Vault 讀回的資料相同會直接「跳過更新」。

需要特別注意、容易沒考慮到的幾點：

1. **改位址必須重啟 VSO pod**（位址啟動時才讀一次）。`helm upgrade` 會自動 rollout；但若只手動改
   env / configmap 而沒讓 pod 重建，**完全不生效**（S5 證實：存活 pod 仍用舊位址且讀取正常）。
2. **`.Vault.Address` 模板是唯一會真的改到 application 的情況**。一旦 VaultSecret 的 `spec.templates`
   內嵌了 Vault 位址字串，改 endpoint 會讓 secret 內容跟著變 → 掛載檔案更新（且有 ~60s 刷新延遲）。
   若 application 把這個值當連線目標或拿去比對，行為就會改變。要避免就別把位址放進模板。
2.5. （同理）若 application 用 `subPath` 掛載該 secret，K8s 的 subPath 掛載**不會**自動刷新，
   即使 secret 變了也要重啟 pod 才會看到——這會放大上一點的影響。本實驗用一般 volume 掛載（會刷新）。
3. **切到「打不到」的新位址**（DNS 解析失敗、TLS 不符、網路不通）時，**既有 secret 不會消失**，
   只會「停止刷新（stale）」並在 CR 標 `FetchFailed`；新位址恢復可達後會自動補上（S3 證實）。
   真正的風險不是「secret 消失」，而是「在你沒注意到的情況下 secret 停止更新」——
   要監控 `kube_customresource` / CR 的 `SucceededReason=FetchFailed` 或 operator 的 reconcile error。
4. **rollout 期間的短暫空窗**：切換時舊 VSO pod 被新 pod 取代，這幾秒內沒有 operator 在 reconcile；
   但因為它本來就不會碰既有 Secret，application 仍完全無感（本實驗零 FAIL 已涵蓋這段）。

## 重現方式

```bash
# 1) k3s 1.31 + runc wrapper（見 .claude/skills/k3s-experiment）
# 2) 部署 Vault dev 與多個 Service
kubectl apply -f manifests/vault.yaml
# 3) 安裝 VSO 1.26.0（初始 address 設為 vault Service 的 ClusterIP）
helm install vso <repo>/vso-v1.26.0/charts/vault-secrets-operator -n vso -f manifests/vso-values.yaml
# 4) 部署 VaultSecret×2 與 consumer×2
kubectl apply -f manifests/vaultsecret.yaml -f manifests/vaultsecret-templated.yaml \
              -f manifests/consumer.yaml   -f manifests/consumer-templated.yaml
# 5) 逐一切換並觀察（見 results/markers.log 的時間軸）
helm upgrade vso ... --reuse-values --set vault.address=http://vault.vault.svc.cluster.local:8200
```

`results/` 內含：`markers.log`（時間軸）、`consumer-*.log`（連續讀取記錄）、
`secret-*-{baseline,s1,s2,s3broken,s3recovered}.yaml` 與 `vaultsecret-*.yaml`（各階段快照）。
