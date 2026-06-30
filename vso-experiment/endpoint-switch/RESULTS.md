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
| HTTPS 情境 (S6) | nginx TLS 終結 (`manifests/vault-tls-proxy.yaml`)，憑證 SAN 只簽 `vault-tls.vault.svc`；Service `vault-tls`(相符)/`vault-tls-b`(不符) 同指 nginx；VSO 用 `vso-values-tls.yaml` 掛 CA + `VAULT_CACERT` |

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
| S6 | **HTTPS，換到憑證 SAN 不符的 domain** | CR=`FetchFailed`(x509)，**secret 仍在**、rv 不變(1887) | CR=`FetchFailed`，**secret 仍在**、保留最後good值 | 零 FAIL，hash 不變 |
| S6b | 同上 + `VAULT_SKIP_VERIFY=true`（不安全旁路） | ~17s 後 `Updated` 恢復（略過憑證驗證） | 恢復 | 零 FAIL |

### 量化驗證（`results/` 內的 log 與快照）
- **FAIL 次數：0 / 0**（兩個 consumer 全程沒有一次讀不到 secret）。
- helloworld consumer：81 個樣本，**最大取樣間隔 6.0s**（迴圈 5s + jitter，無漏樣、無空窗）。
- helloworld 只出現**單一 hash `37b51d19`**；`foo=bar` 在 baseline/S1/S2/S3broken/S3recovered **五份快照完全相同**。
- templated 的 `addr` 隨每次切換改變：
  `IP → domainA → domainB →（broken 期間保留 domainB）→ vault-missing`。
- **模板情境的傳播延遲**：S1 時 Secret 物件在 `04:38:09Z` 被更新，但掛載檔案到 `04:39:12Z` 才翻成新位址
  → **約 63s 的 kubelet mount 刷新延遲**（secret 物件變更與 pod 內檔案更新之間的正常落差）。

### S6 詳述：HTTPS 憑證 SAN 不符（換 domain 但 SSL 憑證不符合）

用 nginx 做 TLS 終結放在 Vault 前面（`https://...:8443` → `http://vault:8200`），憑證的
SAN **只簽了 `vault-tls.vault.svc.cluster.local`**。VSO 透過 `VAULT_CACERT` 信任這張自簽 CA。

- baseline：VSO 連 `https://vault-tls.vault.svc.cluster.local:8443`（名稱在 SAN 內）→ TLS 通過、secret 正常同步。
- 切到 `https://vault-tls-b.vault.svc.cluster.local:8443`（**同一個 nginx、同一張憑證、同一座 Vault**，
  但這個 domain 不在 SAN）→ VSO 端 Go TLS 驗證直接擋下：

  ```
  FetchFailed: tls: failed to verify certificate:
    x509: certificate is valid for vault-tls.vault.svc.cluster.local,
    not vault-tls-b.vault.svc.cluster.local
  ```

- **結果與「切到打不到的位址」(S3) 完全一樣**：fetch 失敗、CR 標 `FetchFailed`，但既有 K8s Secret
  **不刪、不變**（helloworld rv 仍 1887、`foo=bar`），consumer 零 FAIL。application 無感，只是停止刷新。
- 旁路（S6b）：加 `VAULT_SKIP_VERIFY=true`（operator 透過 `api.DefaultConfig()` 讀此 env）後，
  即使憑證不符也能連上、~17s 恢復。**這是放棄 TLS 驗證、不安全**，正式做法應是「重簽含新 SAN 的憑證」
  或「沿用憑證涵蓋的名稱」，而非 skip-verify。

> 這是真實世界「IP→domain」最常見的破壞點：原本用 IP（或舊 domain）連、憑證沒簽新名稱，
> 一換 domain 就 x509 失敗。好消息是它**不會弄丟 application 的 secret**，只會讓它停在最後一次成功的值。

### S7：Vault 連不上時 `/healthz`（liveness）回什麼？

**重點：`/healthz`/`/readyz` 只反映「token 續租」健康，完全不反映「secret 是否抓得到」。**

程式碼路徑（`main.go:127-145`、`vault/client.go:97-104`）：
- `/healthz` → `GetHealth(10)`、`/readyz` → `GetHealth(5)`：只有在 `failedRenewTokenAttempts >= 門檻` 時才回錯誤(500)。
- `failedRenewTokenAttempts` **只在 token 續租迴圈 `RenewToken()` 內增減**（client.go:74/88），
  reconcile / `GetSecret` 失敗**不會**動到它。
- 續租迴圈只有 `VAULT_RENEW_TOKEN=true` 才會啟動（`main.go:64`）；若 shared client 為 nil（純 vaultRole 模式）`/healthz` 永遠回 nil(200)。

實測兩種設定（把 Vault scale 到 0 模擬連不上）：

| 設定 | Vault 連不上時的觀察 |
|---|---|
| **`VAULT_RENEW_TOKEN=false`**（本實驗其餘情境用的設定） | CR 全 `FetchFailed`、一個 secret 都抓不到，但 **`/healthz`=200、`/readyz`=200、0 重啟**。operator 回報「健康」卻完全無法工作。 |
| **`VAULT_RENEW_TOKEN=true` + 可續租 token** | 續租每 5s 失敗一次、`failedRenewTokenAttempts` 累加：**~41s 時 `/readyz`→500**（達門檻 5），**~90s 時 `/healthz`→500**（達門檻 10），接著 liveness 連續失敗觸發 **pod 重啟**（event: `Liveness probe failed: HTTP probe failed with statuscode: 500`）。 |

實務意義：
1. **不能用 `/healthz` 當「Vault 連線健康」的指標。** Vault 掛掉、DNS 壞掉、憑證不符導致 secret 全部停更時，
   只要 token 續租沒在跑（或不需要續租），liveness 仍是綠的，pod 不會自我重啟、不會告警。
   要偵測「VSO 抓不到 secret」必須看 **VaultSecret CR 的 `SucceededReason=FetchFailed`** 或 operator 的
   reconcile error / metrics，而不是 liveness。
2. 反過來，當你**有**開 token 續租而 Vault 連不上，`/healthz` 會在約 10 次續租失敗後翻 500 → pod 被
   liveness 重啟。重啟也救不了「Vault 連不上」，只會進入 CrashLoop，但至少這個訊號看得到。
3. `/readyz`（門檻 5）比 `/healthz`（門檻 10）早一半翻 500，可當較早的預警。

### S8：`VAULT_RECONCILIATION_TIME` 的作用 & 啟動時 Vault 連不上會不會 Ready

**`VAULT_RECONCILIATION_TIME`（chart `vault.reconciliationTime`，秒，預設 0）**
— 啟動時讀進 package 變數 `vault.ReconciliationTime`（`vault/vault.go:56`），在 reconcile **成功**後決定要不要
週期性重排：`vaultsecret_controller.go:72-76` 回傳 `ctrl.Result{RequeueAfter: N 秒}`。
- `> 0`：每 N 秒把每個 VaultSecret 重新讀一次 Vault → Vault 端的值改了，K8s Secret 會在 ≤N 秒內跟上（**輪詢式同步**）。本實驗設 30，log 才會每 30s 看到一次 `Read secret`。
- `0`：關閉週期重排。K8s Secret 只在 **CR 的 spec 變動**（generation 改變，`ignorePredicate` 只放行 generation 變化）或 **operator 重啟** 時才重新同步。→ 若只改 Vault 裡的值、不動 CR，K8s Secret **不會自動更新**。
- 注意：它只影響「成功路徑」的重排間隔；reconcile **失敗**時 controller-runtime 會用自己的指數退避重試（與此值無關）。PKI engine 則改用憑證到期時間當重排依據（`:178-183`），不吃這個值。
- （細節）程式碼註解寫「requeue only if no version is specified」，但實際上 `reconcileResult` 不論有沒有
  `spec.version` 都照樣帶 `RequeueAfter`；註解與行為略有出入，pin version 的 secret 仍會被週期重讀。

**啟動時 Vault 就連不上，pod 會 Ready 嗎？→ 看 auth method：**

| auth method | 啟動時是否連 Vault | Vault 連不上時的結果 |
|---|---|---|
| **token**（本實驗用） | `CreateClient` **不連** Vault，只建 client、設 token（`vault.go:133-186`） | pod 照常啟動、**~5s 就 Ready=True**；readyz 只看 token 續租失敗數(=0) → 200。**即使一個 secret 都抓不到（CR 全 `FetchFailed`），仍回報 Ready。** |
| **kubernetes / approle / aws / gcp / azure** | `CreateClient` 啟動時就 **向 Vault 登入**（如 `auth/kubernetes/login`，`vault.go:223`） | 登入失敗 → `InitSharedClient` 回 error → `main.go:60` **`os.Exit(1)`** → `Error` / **CrashLoopBackOff、永遠不會 Ready**。 |

實測（Vault scale 到 0 後冷啟動 VSO）：
- token auth：pod `1/1 Running`、`Ready=True`、0 重啟，但 CR `FetchFailed: connect: connection refused`、實際抓不到 secret。
- kubernetes auth：pod `0/1 Error` → CrashLoop，log：`Could not create API client for Vault ... /v1/auth/kubernetes/login: connection refused`。

**結論**：用 **token auth** 時，「Pod Ready」**完全不保證** VSO 連得到 Vault、也不保證 secret 同步正常
（Ready 只代表 token 續租沒爆門檻）。要確認 VSO 真的在工作，看 VaultSecret CR 的 `FetchFailed`，別只看 Pod Ready。
反之用 **kubernetes/approle 等需登入的 auth**，啟動時連不到 Vault 會直接 CrashLoop——這時「沒 Ready」反而是個明確訊號。

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
3. **切到「打不到」的新位址**（DNS 解析失敗、**SSL 憑證 SAN 不符**、網路不通）時，**既有 secret 不會消失**，
   只會「停止刷新（stale）」並在 CR 標 `FetchFailed`；新位址恢復可達後會自動補上（S3 與 S6 證實）。
   換 domain 時最常見的就是憑證沒簽新名稱導致 x509 失敗（S6），解法是重簽含新 SAN 的憑證，別用 skip-verify。
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
