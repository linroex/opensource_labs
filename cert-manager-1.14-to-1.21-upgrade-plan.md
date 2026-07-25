# cert-manager 1.14 → 1.21 升級評估與計畫（Vault Issuer 環境）

> 適用情境：所有憑證皆透過 cert-manager 的 **Vault issuer**（HashiCorp Vault PKI）簽發。
> 文件日期：2026-07-24。研究基準：cert-manager 官方 release notes、GitHub release 頁面、官方升級文件，以及對關鍵論點的對抗式驗證與 k3s + Vault 實機測試。

---

## 0. TL;DR — 你最該記住的六件事

1. **一次只跳一個 minor，且每次跳到該 minor 的「最新 patch」**。官方不保證跨多版直跳。目標路徑：
   `1.14.7 → 1.15.5 → 1.16.5 → 1.17.4 → 1.18.6 → 1.19.6 → 1.20.3 → 1.21.0`（共 7 個 hop）。
2. **Kubernetes 版本沒有任何一版同時被 cert-manager 1.14 與 1.21 支援**（1.14 支援 K8s 1.24–1.31；1.21 需要 K8s 1.33–1.36）。cert-manager 的升級必須與叢集 K8s 升級交錯進行。
3. **三個一定會踩到的破壞性變更**（與 issuer 類型無關，Vault 用戶照樣中）：
   - **v1.18**：`Certificate.spec.privateKey.rotationPolicy` 預設由 `Never` → `Always`（下次續期就換新私鑰）；`revisionHistoryLimit` 預設 → `1`（清掉舊的 CertificateRequest）。**v1.20 起此 feature gate GA 且無法再關閉**，所以要在 1.18 之前就決定。
   - **v1.16**：Helm chart 導入 `values.schema.json` 嚴格驗證，**打錯字或已移除的 value 會讓 `helm upgrade` 直接失敗**。
   - **v1.21**：Helm chart **不再自動建立** 讓 controller 對自己 ServiceAccount 簽 token 的 Role/RoleBinding（`serviceaccounts/token`）。若你的 Vault Kubernetes auth 用 `serviceAccountRef` 指向 controller 自己的 SA，會壞掉。
4. **v1.19.0 有已知的「續期風暴」bug**（issuerRef 省略 kind/group 時會誤觸大量重新簽發），**絕對不要停在 1.19.0**，直接上 1.19.6。同理 **1.16.0 不要用**（ClusterIssuer 命名空間 regression）。
5. **v1.21.0 目前是 1.21 線上唯一版本，且帶一個已知 crash bug**：只要有任何 Certificate 設了新的 `spec.renewal.policy: Disabled`，controller 會 nil-pointer crash-loop（#9031，修正已 merge 但未發 patch）。在 1.21 patch 出來前，**禁止使用 `spec.renewal` 欄位**即可安全上線。
6. **升級本身不會觸發重新簽發**（除了上面 1.19.0 的 bug）。CRD 全程只有 `v1` 一個版本、無 conversion webhook、schema 全部只增不減 → 這讓每個 hop 的回滾風險相對可控。

---

## 1. 你問的第一件事：「我該如何評估這 7 個版本會有哪些變化？」——評估方法論

這是一套可重複的評估流程，之後你要升到 1.22、1.23 也適用：

### 1.1 權威資料來源（照優先序）
1. **官方 Release Notes 索引**：<https://cert-manager.io/docs/releases/> — 內含「Supported Releases」相容性表（K8s / OpenShift 版本、EOL 日期）。
2. **每個 minor 的 release notes**：`https://cert-manager.io/docs/releases/release-notes/release-notes-1.XX/`（會標出 Breaking changes / Feature / Bug fix）。
3. **逐 hop 升級指引**：`https://cert-manager.io/docs/releases/upgrading/upgrading-1.XX-1.YY/`（1.14→1.15 一路到 1.20→1.21 每一段都有專頁，內含「必做步驟」）。
4. **GitHub Release 頁面**：`https://github.com/cert-manager/cert-manager/releases/tag/vX.Y.Z` — 這是最權威的、含每個 **patch** 的修正與 **Known Issues** 清單。
5. **官方升級總則**：<https://cert-manager.io/docs/installation/upgrade/>。
6. **Vault issuer 設定文件**：新舊對照 <https://cert-manager.io/v1.14-docs/configuration/vault/> vs <https://cert-manager.io/docs/configuration/vault/>。

### 1.2 每個版本要盯的 6 個維度
針對每一個 minor，逐一問：

| 維度 | 要找什麼 | 對 Vault 用戶的意義 |
|---|---|---|
| **API / CRD** | Certificate/Issuer schema 有無欄位新增、移除、預設值改變 | 決定 manifest 是否要改、回滾是否安全 |
| **預設行為** | rotationPolicy、revisionHistoryLimit、簽章演算法、auto-approval | 可能在「你沒改任何 YAML」的情況下改變行為 |
| **Helm chart** | value 新增/改名/移除、schema 驗證、CRD 管理方式、預設值 | 決定 `helm upgrade` 會不會失敗、部署物件有無變化 |
| **Feature gates** | 哪些 gate 被加入/升 Beta/GA/移除 | 被移除的 gate 若留在 config 會讓 controller 開不起來 |
| **Vault issuer** | `spec.vault.*` 欄位、auth 方法、token/audience 行為 | 直接影響你的簽發流程 |
| **元件部署** | controller/webhook/cainjector/startupapicheck 的 image、port、RBAC、securityContext | 影響 air-gapped mirror、監控、PSA/SCC |

### 1.3 「這次升級到底安不安全」的三個判斷準則
- **CRD 是否有破壞性 schema 變更？** → 本次範圍內 **沒有**（全部只增不減，全程 `v1` + `conversion: none`）。這是最大的定心丸。
- **有沒有「不改 YAML 也會變」的預設行為？** → 有三個：1.18 rotationPolicy、1.18 revisionHistoryLimit、1.20 container UID/GID（65532）。
- **有沒有會讓升級指令當場失敗的東西？** → 有兩個：1.16 Helm schema 驗證、1.21 移除的 prometheus value / RBAC。

> 本文件第 5～6 節就是用這套方法把 1.15–1.21 全部跑過一遍的結果。

---

## 2. 相容性矩陣（升級規劃的地基）

資料來源：<https://cert-manager.io/docs/releases/>（Supported Releases 表）+ GitHub tags，驗證於 2026-07-24。

| cert-manager | 發布日 | EOL / 狀態（2026-07） | 支援 K8s | 支援 OpenShift | 最新 patch |
|---|---|---|---|---|---|
| 1.14 | 2024-02-03 | EOL 2024-10-03 | 1.24 – 1.31 | 4.11 – 4.16 | **v1.14.7** |
| 1.15 | 2024-06-05 | EOL 2025-02-03 | 1.25 – 1.32 | 4.12 – 4.16 | **v1.15.5** |
| 1.16 | 2024-10-03 | EOL 2025-06-10 | 1.25 – 1.32 | 4.14 – 4.17 | **v1.16.5** |
| 1.17 | 2025-02-03 | EOL 2025-10-07 | 1.29 – 1.33 | 4.16 – 4.20 | **v1.17.4** |
| 1.18 | 2025-06-10 | EOL 2026-03-10 | 1.29 – 1.33 | 4.16 – 4.20 | **v1.18.6** |
| 1.19 | 2025-10-07 | EOL 2026-07-08 | 1.31 – 1.35 | 4.18 – 4.20 | **v1.19.6** |
| 1.20 | 2026-03-10 | **支援中**（1.22 發布時 EOL） | 1.32 – 1.35 | 4.19 – 4.21 | **v1.20.3** |
| 1.21 | 2026-07-08 | **支援中**（最新） | 1.33 – 1.36 | 4.20 – 4.22 | **v1.21.0** |

**支援政策**：每個版本支援到「再往後第二個 minor 發布為止」，任何時間點只有最新兩個 minor 受支援。**目前（2026-07-24）只有 1.20 與 1.21 在支援期內**——你目前的 1.14 早已 EOL 近兩年，升級屬「補技術債」性質，越早做越好。

### 2.1 關鍵限制：K8s 版本必須交錯升級
1.14（K8s 上限 1.31）與 1.21（K8s 下限 1.33）**沒有任何共同支援的 K8s 版本**。跨越各 hop 的 K8s 對照：

- **K8s 1.31** 橫跨 cert-manager 1.14 → 1.19
- **K8s 1.32** 橫跨 cert-manager 1.15 → 1.20
- **K8s 1.33** 橫跨 cert-manager 1.17 → 1.21

**規劃建議**：把 cert-manager 的 7 個 hop 分成兩到三段，中間插入 K8s 升級：
- 若目前 K8s ≤ 1.31：先把 cert-manager 推到 1.17～1.19（在 K8s 1.31 上都支援），再升 K8s 到 1.33，再把 cert-manager 推完 1.20→1.21。
- **硬性關卡**：cert-manager 1.20 需要 K8s ≥ 1.32；cert-manager 1.21 需要 K8s ≥ 1.33。上這兩個 hop 前，K8s 必須已到位。
- 每個 hop 都要同時滿足「當前 hop」與「上一個 hop（保留回滾空間）」的 K8s 支援窗。

---

## 3. 升級路徑與每個 hop 的目標 patch（含理由）

官方總則（<https://cert-manager.io/docs/installation/upgrade/>）：**一次一個 minor、每次到最新 patch、讀該版 release notes**。跨多版的「uninstall/reinstall」只是「或許可行」，官方不保證，且對你這種正式環境風險過高，**不採用**。

| Hop | 目標版本 | 為什麼是這個 patch（不是 .0） |
|---|---|---|
| 1 | **v1.15.5** | 避開 1.15.0 的 Vault issuer 不重試 bug（1.15.1 修）與 webhook CA 續期偵測 bug（1.15.3 修） |
| 2 | **v1.16.5** | **絕不要用 1.16.0**（ClusterIssuer 命名空間 regression、schema 對 `global:` 過嚴）；1.16.1 才修好 |
| 3 | **v1.17.4** | 低風險版；1.17.4 修掉 NameConstraints 的一個 bug |
| 4 | **v1.18.6** | 1.18.5 修掉「公鑰與 CSR 不符時無限重簽」的迴圈；1.18.3 含跨 1.19 前的預防性修正 |
| 5 | **v1.19.6** | **絕不要停在 1.19.0**（續期風暴 bug，1.19.1 才 revert）；1.19.3 修 DNS DoS 與重簽迴圈；1.19.6 修 RBAC CVE |
| 6 | **v1.20.3** | 1.20.2 修 chart YAML 產生錯誤；1.20.3 含 GHSA-8rvj-mm4h-c258 高風險 RBAC 修正 |
| 7 | **v1.21.0** | 目前唯一版本；可上線但**升級前必須先補 tokenrequest RBAC，且禁用 `spec.renewal`**（見第 4、7 節）|

> **關於 1.21**：v1.21.0（2026-07-08）到今天仍是 1.21 線唯一版本，尚無 v1.21.1。它對 Vault-only 環境「可用」，但帶 `spec.renewal.policy: Disabled` 的 crash bug（#9031）。若你需要用到新的續期排程窗（`spec.renewal`），建議**等 v1.21.1**；若用不到，維持不碰該欄位即可安全上 1.21.0。

---

## 4. 三個「必處理」的破壞性變更（Vault 環境務必逐一確認）

### 4.1 【v1.18】privateKey.rotationPolicy 預設 Never → Always
- **影響**：任何**沒有明確設定** `spec.privateKey.rotationPolicy` 的 Certificate，在 1.18 之後**下一次續期或重簽時會產生全新的私鑰**。這作用於「controller 端」、依 feature gate `DefaultPrivateKeyRotationPolicyAlways`（1.18 預設開啟）判斷，**不會改寫已存在物件的 YAML**。
- **不可逆時間點**：此 gate 在 **v1.20 GA 且無法再關閉**。所以「維持舊行為」的唯一持久做法是**在每個相關 Certificate 上明確寫 `rotationPolicy: Never`**（關 gate 只是暫時手段，1.20 後失效）。
- **誰會痛**：有「私鑰指紋綁定 / key pinning」、把私鑰掛載進其他系統、或 HSM 綁定的應用。對純 TLS 伺服憑證通常無害（反而更安全）。
- **行動**：**在第 4 個 hop（→1.18）之前**，用第 9.3 節的稽核指令列出所有缺 `rotationPolicy` 的 Certificate。**最穩的策略是把「每一張」Certificate 都明確寫上 `rotationPolicy`（`Never` 或 `Always`，依消費端逐一判定）——讓這個預設值變更徹底變成 no-op**，而不是只處理需要 `Never` 的那幾張。欄位補齊後，1.18 和 1.20 的 gate 演進都與你無關。
- **連帶提醒**：對「接受輪替」的憑證，確認消費端會重載——掛載 Secret 的 Pod 會自動收到更新檔案，但**應用程式若把憑證/私鑰快取在記憶體，需要能熱重載或接受重啟**；這在 1.18 之後會從「續期時偶爾發生」變成「每次續期都發生」。

### 4.2 【v1.18】revisionHistoryLimit 預設 → 1
- **影響**：升級後，未明確設定此欄位的 Certificate 會把多餘的舊 `CertificateRequest` 垃圾回收，只留 1 份。一般無害（只是歷史紀錄變少），但若你有稽核/除錯流程依賴舊 CertificateRequest，要先撈出來或明確加大該值。

### 4.3 【v1.16】Helm values JSON schema 嚴格驗證
- **影響**：1.16 起 chart 帶 `values.schema.json`（root 為 `additionalProperties: false`）。你在 1.14 時代**被默默忽略的打錯字 / 已移除的 value，現在會讓 `helm upgrade` 直接失敗**。
- **已知會中招的**：`prometheus.servicemonitor.targetPort`、`prometheus.servicemonitor.path`、`prometheus.podmonitor.path`（這三個在 1.21 被移除，若留著 → schema 失敗）。
- **官方 pre-flight**：升級前用 `helm template` 先驗證你的 values：
  ```bash
  helm template cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --version v1.16.5 --values your-values.yaml >/dev/null
  ```

### 4.4 【v1.21】移除 controller 自簽 token 的預設 RBAC（Vault Kubernetes auth 專屬）
- **影響**：1.21 chart **不再產生** `<release>-tokenrequest` 的 Role/RoleBinding（授予 controller 對「自己的 ServiceAccount」`serviceaccounts/token: create`）。
- **只有這種設定會壞**：Issuer/ClusterIssuer 的 `spec.vault.auth.kubernetes.serviceAccountRef.name` **指向 cert-manager controller 自己的 SA**。
- **不受影響**：`tokenSecretRef`（靜態 token）、`appRole`、`clientCertificate`、`kubernetes.secretRef`（靜態 SA token），以及 `serviceAccountRef` 指向**專用 SA**（官方推薦寫法）。
- **行動**：升 1.21 前先用第 6 節稽核指令盤點 `serviceAccountRef.name`；若指向 controller SA，**升級前**先自建等效 RBAC，或改用專用 SA：
  ```yaml
  apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata: { name: cert-manager-vault-tokenrequest, namespace: cert-manager }
  rules:
    - apiGroups: [""]
      resources: ["serviceaccounts/token"]
      verbs: ["create"]
      resourceNames: ["cert-manager"]   # controller SA 名稱
  ```

---

## 5. 逐版本重大變更摘要（Vault 視角，僅列與你相關者）

> ACME / Let's Encrypt / Venafi 專屬變更一律略過或標註「ACME-only 可忽略」。

### v1.15.5（"Vault" 版）
- **Helm**：`installCRDs` 被 `crds.enabled`（預設 false）+ `crds.keep`（預設 true）取代（詳見第 7.2 節）。`installCRDs` 仍可用但已 deprecated；**同時設 `installCRDs` 與 `crds.enabled` 會讓 chart 直接報錯**。
- **startupapicheck** 換 image：`quay.io/jetstack/cert-manager-startupapicheck`（舊 `cert-manager-ctl` 停用）——**air-gapped mirror 要補這個 image**。`cmctl` 移到獨立 repo。
- **Vault**：新增 mTLS（`clientCertSecretRef`/`clientKeySecretRef`）與 Kubernetes auth 的 token audiences（`serviceAccountRef.audiences`）。皆為 opt-in，不影響既有設定。
- **Gateway API** gate 改為 `--enable-gateway-api` flag（ACME 相關，可忽略）。
- **新 Helm value**：`disableAutoApproval` / `approveSignerNames`（auto-approval 預設仍全開）。

### v1.16.5
- **【破壞性】Helm schema 驗證**（見 4.3）。
- 舊 API 版本 `v1alpha2/v1alpha3/v1beta1` 從程式碼中移除（多年前就不再服務，manifest 只要都用 `v1` 就無事）。
- **Vault**：新增 `spec.vault.auth.clientCertificate`（Vault TLS cert auth）。
- webhook / cainjector 各自獨立的 metrics server；controller 匯出 process/Go runtime metrics（**更新 scrape config / NetworkPolicy**）。cainjector 只快取 Secret metadata（降記憶體）。
- 新增 gate `UseDomainQualifiedFinalizer`（opt-in）、`WatchListClient`（需 K8s 1.27+，opt-in）。
- **不要用 1.16.0**。

### v1.17.4
- **對 Vault 幾乎零摩擦**：無 Vault 專屬變更、無 Certificate 預設值變更、無 CRD schema 移除。
- CA / SelfSigned issuer 對 RSA ≥3072/4096 改用 SHA-384/512 簽章——**只影響 CA/SelfSigned，不影響 Vault**（Vault 在伺服器端簽）。
- **結構化 log**：非結構化 log 訊息改為結構化——**任何用字串比對 log 的告警要改**。
- gate `ValidateCAA` 標為 deprecated（1.18 移除）；`NameConstraints`、`UseDomainQualifiedFinalizer` 升 Beta（預設開）。

### v1.18.6
- **【破壞性】rotationPolicy 預設 Never→Always**（見 4.1）。
- **【破壞性】revisionHistoryLimit 預設→1**（見 4.2）。
- **Vault**：新增 `spec.vault.serverName`（覆寫 Vault 憑證的 TLS 主機名/SNI 驗證）；`caBundle`/`caBundleSecretRef` 語意不變。
- 新增 `spec.signatureAlgorithm` 欄位；gate `ValidateCAA` 移除；`UseDomainQualifiedFinalizer`、`AdditionalCertificateOutputFormats` 升 GA。
- 新增 `not_before` / `not_after` timestamp metrics（無 rename）。
- Helm：Service/ServiceMonitor 的 port 由號碼改為名稱。
- ACME-only（低優先）：HTTP01 Ingress `pathType` 改 `Exact`（1.18.1 加 gate `ACMEHTTP01IngressPathTypeExact` 可關）。

### v1.19.6
- **【嚴重】不要停在 1.19.0**：issuerRef 省略 kind/group 的 Certificate 會被 CRD 預設值誤觸**重新簽發**——這對 Vault 憑證一視同仁。1.19.1 已 revert，官方明文「never install v1.19.0」。**實驗實證（見第 15 節）**：誤重簽不是升級瞬間的可見風暴，而是 **CRD defaulting 在物件被寫入時非對稱持久化造成的「延遲性、逐張、時點不可預測」誤重簽**（事件：`Fields on existing CertificateRequest resource not up to date: [spec.issuerRef]`），且因 1.18 起 rotationPolicy=Always 已生效，**誤重簽會連私鑰一起換掉**——更難監控、傷害更大。
- **緩解做法**：跨 1.19 前，**把所有 Certificate 的 `issuerRef` 明確補上 `kind` 與 `group`**。註：此 API 預設值功能在 1.19.1 被 revert 後，**1.20.0 也維持 revert**（release notes 原文「Revert API defaults for issuer reference kind and group」）——所以補齊 kind/group 是防禦性措施（未來版本很可能重新引入此預設值），不是 1.20 的硬需求。
- Vault issuer 本身無 runtime 變更（僅測試框架換 client）。
- 1.19.3 起：簽發後會**驗證憑證公鑰與私鑰相符**才儲存，失敗改為 backoff（適用所有 issuer 含 Vault，防無限重簽）。
- gate `CAInjectorMerging` 升 Beta 預設開（cainjector 改為「合併」而非「取代」CA bundle，webhook/CA 輪替更平滑）。
- 觀測性（ACME-only 可忽略）：移除 acme client metrics 的高基數 `path` label。
- 1.19.6 強化 RBAC：`cert-manager-edit` 移除對 Challenges/Orders 的 create（GHSA-8rvj-mm4h-c258，只影響直接建立 ACME 物件的工具）。

### v1.20.3
- **Vault**：generated ServiceAccount token 現在**多帶一個預設 audience = Vault server 位址**（原本只有 `vault://<ns>/<issuer>`）。**經實測（見第 6 節）此為 any-match，不會弄壞任何在 1.14 能登入的設定**。
- **【破壞性】feature gate `DefaultPrivateKeyRotationPolicyAlways` GA，無法再關閉**（1.18 的 rotationPolicy 變更在此定案）。
- **【破壞性】container 預設 UID 1000→65532、GID 0→65532**——檢查 `securityContext` 覆寫、PSA/SCC、volume 檔案擁有者。
- 1.20.0 revert 掉 1.19.0 的 issuerRef 預設值 bug 並修正誤續期。
- Helm：新增 `extraContainers`、各 Deployment 的 NetworkPolicy、startupapicheck 的 imagePullSecrets、PDB `unhealthyPodEvictionPolicy`；1.20.0/1.20.1 有 chart YAML bug（webhook.config + webhook.volumes 併用時），**1.20.2 修好**。
- Prometheus label 固定為 `cert-manager`（**可能影響 dashboard/scrape matcher**）。
- gate `OtherNames` 升 Beta（預設開）。
- 1.20.3 含 GHSA-8rvj-mm4h-c258 高風險 RBAC 修正。

### v1.21.0
- **【破壞性・Vault 關鍵】移除 controller 自簽 token 的預設 RBAC**（見 4.4）。
- **【破壞性】移除 Helm value** `prometheus.servicemonitor.targetPort/.path`、`prometheus.podmonitor.path`（留著會 schema 失敗）；controller Service metrics port 由 `tcp-prometheus-servicemonitor` **改名 `http-metrics`**——**更新 ServiceMonitor / scrape config**。
- **Vault**：新增 **AWS IAM auth**（`spec.vault.auth.aws`：IRSA / EKS Pod Identity / EC2/ECS 環境憑證）；webhook 驗證現在**拒絕 vault path 中的 `..`**。
- **【已知 bug #9031】** 任何 Certificate 設 `spec.renewal.policy: Disabled` → controller nil-pointer crash-loop（修正 PR 已 merge，未發 patch）→ **1.21 patch 出來前禁用 `spec.renewal`**。
- deprecation：Helm 的 `config.enableGatewayAPI` → `config.gatewayAPI.enabled`（注意這是 ControllerConfiguration 欄位，透過 chart 的 `config.*` passthrough，不是頂層 chart value）；`ServerSideApply` gate deprecated（cainjector SSA 改為無條件）；`CAInjectorMerging` GA。
- 新增 `--certificate-request-maximum-backoff-duration`（預設 32h，Helm `config.certificateRequestMaximumBackoffDuration`）——與 **Vault 中斷後的重簽 backoff** 有關。
- 有用的修正：修掉「issuer 回傳已過期憑證時的無限重簽迴圈」（對接近到期的 Vault CA 很實用）、`renewBeforePercentage` 在 >3 年憑證的整數溢位。

---

## 6. Vault Issuer 專屬變更全表（v1.14 → v1.21）

> 經 release notes + API source + **k3s + 真實 Vault 實機測試**驗證。

### 6.1 `spec.vault` 欄位新增時間軸（全部只增不減、皆為 opt-in）
| 版本 | 新增欄位 | 用途 |
|---|---|---|
| 1.15 | `clientCertSecretRef`, `clientKeySecretRef` | 對 Vault 的傳輸層 mTLS |
| 1.15 | `auth.kubernetes.serviceAccountRef.audiences` | K8s auth token 額外 audience |
| 1.16 | `auth.clientCertificate` (`mountPath`/`name`/`secretName`) | Vault TLS cert auth 後端 |
| 1.18 | `serverName` | 覆寫 Vault 憑證的 TLS 主機名驗證 (SNI) |
| 1.21 | `auth.aws` (`role`/`iamRoleArn`/`region`/`mountPath`/`serviceAccountRef`/`vaultHeaderValue`) | AWS IAM auth（IRSA/EKS Pod Identity） |

**未變動**（1.14 就有、行為一致）：Vault health check（`v1/sys/health` 探測 unsealed+initialized）、`tokenSecretRef`（不自動續期的既有限制）、`appRole`、`spec.vault.namespace`（Vault Enterprise）、`caBundle` / `caBundleSecretRef`（兩者互斥，1.14 就是這樣，只是舊文件沒列出 `caBundleSecretRef`）。**Vault 相關功能全部沒有 feature gate**。

### 6.2 兩個會「影響你」的行為變更 —— 實測結論

**(A) v1.20 的雙 audience 變更 —— 安全，any-match**
1.20 起 Vault issuer 產生的 SA token 帶**兩個** audience（`vault://<ns>/<issuer>` + Vault server 位址）。經在 **Vault 1.16.3 / 1.20.4 / 1.21.4** 三個版本實機跑完整登入矩陣：
- Vault role `audience = vault://...` → 單 audience（1.14 舊 token）與雙 audience（1.20+ 新 token）**都成功**。
- Vault role **無 audience** → 兩種 token **都成功**。
- Vault role `audience = <server 位址>` → 只有新 token 成功，舊 token **失敗**。
- **結論**：Kubernetes/JWT auth 的 audience 驗證都是「任一符合即可」，多出來的 audience 會被忽略 → **1.14 能登入的設定，升到 1.20+ 一定還能登入，Vault 端不用改任何東西**。

> **⚠️ 一個排序陷阱**：**不要**在 cert-manager 到達 1.20 之前，就把 Vault role 的 audience 改成「server 位址」——那個 audience 只存在於 1.20+ 產生的 token，改早了會讓舊版 token 登入失敗（403 invalid audience）。整個升級期間 Vault role audience **維持 `vault://...` 不動**，升完之後再視需要調整。

**(B) v1.21 移除 tokenrequest RBAC —— 需盤點**（見 4.4）。

### 6.3 升級前必跑的 Vault 曝險稽核
```bash
# 1) 列出所有 Vault issuer 與其 auth 方法
kubectl get clusterissuers,issuers -A -o json | jq -r '
  .items[] | select(.spec.vault != null) | [
    .kind, (.metadata.namespace // "-"), .metadata.name,
    (if .spec.vault.auth.tokenSecretRef then "tokenSecretRef"
     elif .spec.vault.auth.appRole then "appRole"
     elif .spec.vault.auth.clientCertificate then "clientCertificate"
     elif .spec.vault.auth.kubernetes.serviceAccountRef then "kubernetes/serviceAccountRef"
     elif .spec.vault.auth.kubernetes.secretRef then "kubernetes/secretRef"
     else "unknown" end),
    (.spec.vault.auth.kubernetes.serviceAccountRef.name // "-"),
    (.spec.vault.server // "-")
  ] | @tsv'
```
- 結果為 `kubernetes/serviceAccountRef` 且 `name == controller SA` 的 → 受 1.21 RBAC 移除影響，升級前補 RBAC。
- `tokenSecretRef` / `appRole` / `clientCertificate` / `kubernetes/secretRef` → **不受 1.20、1.21 兩個變更影響**。

Vault 端對照：`vault read auth/<mount>/role/<role> -format=json | jq '{audience,bound_service_account_names,bound_service_account_namespaces}'`。

---

## 7. CRD 與 Helm 管理機制（含 installCRDs 遷移陷阱）

### 7.1 好消息：CRD 層面風險很低
經實機下載並比對 v1.14.7 → v1.21.0 每一版的 `cert-manager.crds.yaml`：
- 全部 6 個 CRD **只服務且只儲存 `v1`**，`conversion strategy = none`（**無 conversion webhook、無 storage 版本遷移**）。
- 全範圍的 schema 變更**純粹只增不減（零欄位刪除）**。逐 hop 新增：1.15 `keystores.jks.alias`；1.16 `renewBeforePercentage`；1.17 keystore `password`；1.18 `signatureAlgorithm`；1.19 無；1.20 無（僅 CRD 層 `selectableFields`）；1.21 `spec.renewal`。
- **意涵**：不需要跑任何 API 遷移步驟；回滾時舊 CRD 服務新物件也不會壞（新欄位在讀取時被隱藏、下次寫入時被 prune，API server 不報錯）。

> 例外：若你的叢集安裝史早於 cert-manager 1.7（曾用過 v1alpha2 等），需確認當年有跑過 `cmctl upgrade migrate-api-version`。從 1.14 起才裝的環境無此問題。

### 7.2 `installCRDs` → `crds.enabled` 遷移（1.15 hop 執行）
1.15 起 chart 用 `crds.enabled`（預設 false）+ `crds.keep`（預設 true）取代 `installCRDs`。**遷移陷阱**：
- chart 會 **hard-fail** 若：`installCRDs` 與 `crds.enabled` 同時設，或 `installCRDs` 搭 `crds.keep=false`。
- **絕不可**在升級的同一步把 CRD template 從「開」變「關」（例如刪掉 `installCRDs` 又沒設 `crds.enabled=true`）——這會讓 CRD 從 release manifest 消失，**Helm 可能刪掉 CRD → 連帶垃圾回收掉所有 Certificate/Issuer**。
- **正確做法**：在 1.15 hop，於**同一次變更**把 `installCRDs: true` 換成 `crds.enabled: true`（維持 CRD 全程都在 manifest 裡，並獲得 `helm.sh/resource-policy: keep` 保護）。之後每個 hop 都用 `crds.enabled: true`。
- 若你的 CRD 是用**靜態 `cert-manager.crds.yaml`（Helm 外管理）**，則每個 hop 都要**先** `kubectl apply` 該版 CRD，再 `helm upgrade`。

### 7.3 每個 hop 的 Helm 指令範本
```bash
# CRD 由 Helm 管理（推薦）：
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager \
  --version v1.15.5 \
  --reset-then-reuse-values \
  --set crds.enabled=true \
  --values your-values.yaml

# CRD 靜態管理：先 apply 再 upgrade
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.5/cert-manager.crds.yaml
helm upgrade ... --set crds.enabled=false ...
```
> `--reset-then-reuse-values` 是官方推薦，但它會把**舊 values 全程帶著走 7 個 hop**——這正是第 11 節（feature gate 清理）的風險來源。
> **更推薦的替代做法**：如果你的 values 本來就有版控（git 裡有一份完整的 `your-values.yaml`），就**不要用** reuse 類 flag，每個 hop 直接 `-f your-values.yaml` 明確指定——values 的演進（逐 hop 清理）也跟著進版控，狀態完全可預期。兩種模式擇一，不要混用。

**工具前置需求**：
- `--reset-then-reuse-values` 需要 **Helm ≥ 3.14**；`oci://` chart 來源需要 **Helm ≥ 3.8**。升級戰役開始前先確認執行環境的 Helm 版本。
- OCI chart 可用性已逐一驗證（2026-07-24，quay.io manifest HTTP 200）：`v1.14.7`～`v1.21.0` 全部 8 個 hop 版本都存在於 `oci://quay.io/jetstack/charts/cert-manager`。傳統的 `https://charts.jetstack.io` 也同樣可用，作為備援。

---

### 7.4 若 cert-manager 由 GitOps（Argo CD / Flux）管理 —— 機制差異
本計畫的指令以「直接下 `helm upgrade`」為基準。若實際上是 Argo CD / Flux 在管 cert-manager，**觀念不變（hop 順序、values 清理、驗證關卡全部相同），但操作機制要對應調整**：

| 本計畫的做法 | GitOps 對應 |
|---|---|
| `helm upgrade --version vX.Y.Z` | 改 git 裡的 `targetRevision` / `HelmRelease.spec.chart.version`，一次一個 hop，逐 hop 開 PR |
| `--reset-then-reuse-values` | 不適用——values 本來就在 git，逐 hop 直接改 values 檔（反而更乾淨，第 11 節的清理直接進版控） |
| `helm rollback <revision>` | **不可用**。回滾 = `git revert` 該 hop 的 commit + sync。Argo CD 的 rollback 功能對啟用 auto-sync 的 app 無效，要先關 auto-sync |
| `helm template` 預檢 | Argo CD 的 diff / dry-run（`argocd app diff`）；1.16+ 的 values schema 驗證在 render 階段一樣會生效 |
| Helm hooks（startupapicheck） | Argo CD 會把 `helm.sh/hook` 映射成 Argo hook（post-install → PostSync）；行為略有差異，建議直接 `startupapicheck.enabled=false`，用自己的 smoke test 把關 |
| CRD 隨 chart 套用 | Argo CD 對大型 CRD 建議開 **Server-Side Apply**（`syncOptions: [ServerSideApply=true]`），避免 annotation 大小與 diff 問題 |

另外：**升級戰役期間建議關閉 auto-sync / self-heal**（逐 hop 手動 sync），避免 Argo 在你觀察期自動把任何東西「修」回去，也讓每個 hop 的變更邊界清楚。

## 8.〔操作〕升級視窗機制與 HA 設計

資料來源：<https://cert-manager.io/docs/installation/best-practice/>、<https://cert-manager.io/docs/concepts/webhook/>。

### 8.1 為什麼升級前一定要先做 HA
- **預設每個元件（controller / webhook / cainjector）只有 1 個 replica**。在單副本下，每一次 `helm upgrade` 滾動 webhook 時都會有短暫的「webhook 不可用」窗口。
- **webhook 是 fail-closed**：官方明文「**若 cert-manager webhook 不可用，所有對 cert-manager custom resource 的 API 操作都會失敗**，並中斷任何會建立/更新/刪除 cert-manager 資源的軟體」。也就是說，webhook 掛掉那幾秒，任何新的 Certificate/CertificateRequest 的建立與狀態更新都會被拒。
- **好消息**：這只影響「對 cert-manager CRD 的寫入」。**已簽發的憑證 Secret 不受 webhook 管轄**，所以既有 TLS 連線在升級窗口完全不受影響；受影響的只是「這幾秒內的新簽發/續期」，controller 會在 webhook 恢復後自動重試——**不會遺失、只會延遲**。
- 對 Vault 用戶而言：升級窗口內若剛好有 Certificate 到期要續期，該次 Vault 簽發會被短暫擋下、稍後重試成功。只要不是「大量憑證同時在這幾秒到期」，實務上無感。

### 8.2 建議的 HA 配置（在階段 0 就套用，讓 7 個 hop 全程零中斷）
| 元件 | 預設 replica | 建議 replica | leader election |
|---|---|---|---|
| controller | 1 | **2** | 有（只有 1 個 active，避免重複 reconcile） |
| cainjector | 1 | **2** | 有 |
| webhook | 1 | **3** | 無（可水平擴展，直接分攤流量） |

搭配：
- **每個元件設 PodDisruptionBudget `minAvailable: 1`**。官方警告：**`replicaCount` 必須大於 `minAvailable`**，否則 PDB 會擋住 drain。
- K8s ≥ 1.24 有內建 default topology constraints 會自動把 replica 分散到不同 node/zone；需要更嚴格可用 Helm values 加 `topologySpreadConstraints`。
- 這樣設定後，滾動升級時 webhook 永遠至少有 1 個 replica 在服務 → **升級窗口對 cert-manager API 零中斷**。

> Helm values 範例（併入你的 `your-values.yaml`）：
> ```yaml
> replicaCount: 2
> podDisruptionBudget: { enabled: true, minAvailable: 1 }
> webhook:
>   replicaCount: 3
>   podDisruptionBudget: { enabled: true, minAvailable: 1 }
> cainjector:
>   replicaCount: 2
>   podDisruptionBudget: { enabled: true, minAvailable: 1 }
> ```

### 8.3 CRD apply 與版本 skew
- **CRD 由 Helm 管理時**：`helm upgrade` 會把 CRD 與 Deployment 在同一次 release 一起套用，沒有你手動控制的 skew 窗口；因為 schema 只增不減、無 conversion webhook，「新 CRD + 舊 controller」在滾動的短暫過渡期是安全的（舊 controller 忽略它不認得的新欄位）。
- **CRD 靜態管理時**：你會「先 `kubectl apply` 新 CRD、再 `helm upgrade`」。這段「新 CRD + 舊 controller」窗口同樣安全（同上理由）。
- **262KB annotation 上限**：1.18–1.21 的 CRD 檔案很大，但最大的單一 CRD（clusterissuers）約 147KB compact JSON，**仍在 262144-byte 的 `last-applied-configuration` 上限內**，所以 client-side `kubectl apply` 可正常運作。若你的環境曾因其他大型 CRD 遇過此限制，或想避免風險，**用 `kubectl apply --server-side --force-conflicts`** 最保險（server-side apply 不受該 annotation 限制）。

### 8.4 startupapicheck Job
- chart 內建 `startupapicheck` 是一個 Helm hook Job，但**預設的 hook 只有 `post-install`**（已核對 v1.21.0 chart values.yaml：`helm.sh/hook: post-install`）——**也就是說預設情況下它只在全新 `helm install` 時跑，7 個 hop 的 `helm upgrade` 期間根本不會執行**，不能把它當成升級的驗證關卡。每個 hop 的把關要靠 `kubectl rollout status` + 第 9.4 節的 Vault 簽發 smoke test。
- 例外：若你曾自訂 `startupapicheck.jobAnnotations` 加了 `post-upgrade`，它才會在升級時跑並阻塞 release 直到 API 就緒。
- **1.15 hop 注意**：它的 image 從舊的 `cert-manager-ctl` 改名為 **`cert-manager-startupapicheck`**（`quay.io/jetstack/cert-manager-startupapicheck`）。預設 hook 下升級不會拉這個 image，但 **air-gapped / 私有 registry 環境仍建議 mirror**（未來重裝或開啟 post-upgrade hook 時會用到）。
- 若確定不需要它，可用 `startupapicheck.enabled=false` 關閉以簡化升級。

---

## 9.〔操作〕逐 hop 監控與驗證 Runbook

### 9.1 要盯的關鍵 Prometheus metrics（Vault 環境）
metrics 由每個元件在 **port 9402 的 `/metrics`**（port 名稱 `http-metrics`）匯出。偵測「續期風暴 / 簽發失敗」最有用的：

| Metric | 用途 |
|---|---|
| `certmanager_certificate_ready_status{condition="True\|False"}` | 有多少 Certificate 處於 Ready / 非 Ready；升級後 False 數量若上升即為警訊 |
| `certmanager_certificate_expiration_timestamp_seconds` | 每張憑證到期時間；配合 `now` 算剩餘壽命 |
| `certmanager_certificate_renewal_timestamp_seconds` | 排定的續期時間；用來預測續期波峰 |
| `certmanager_certificate_not_before_timestamp_seconds` / `_not_after_*`（1.18+ 新增） | 憑證有效區間；可偵測「憑證被重新簽發」（not_before 跳動） |
| `certmanager_controller_sync_call_count{controller=...}` | 各 controller 的 reconcile 次數；短時間暴衝 = 續期風暴徵兆 |
| CertificateRequest 建立速率（由 `apiserver_request_total` 或對 CR 物件計數推導） | 續期風暴最直接的訊號 |

> 確切 metric 清單以叢集 `/metrics` 端點為準（<https://cert-manager.io/docs/devops-tips/prometheus-metrics/>）；上表名稱在 1.14→1.21 全程穩定未改名。

### 9.2 監控 surface 會在這幾個 hop 變動 —— 別讓監控在最需要時瞎掉
- **1.16**：webhook 與 cainjector 各自新增獨立 metrics server；controller 新增 process/Go runtime metrics → **更新 scrape config / NetworkPolicy 以涵蓋新 endpoint**。
- **1.20**：Prometheus 的 job/label 固定為 `cert-manager`（先前會變動）→ **檢查 dashboard / alert 的 label matcher**。
- **1.21**：controller Service 的 metrics port 由 `tcp-prometheus-servicemonitor` **改名 `http-metrics`**，且 **移除 Helm value** `prometheus.servicemonitor.targetPort/.path`、`prometheus.podmonitor.path` → **同步更新 ServiceMonitor/PodMonitor 定義**（否則 scrape 斷掉，且留著舊 value 會 schema 失敗）。

### 9.3 升 1.18 前必跑：rotationPolicy 曝險稽核
列出所有**未明確設定** `rotationPolicy` 的 Certificate（這些會在 1.18 後於下次續期換新私鑰）：
```bash
kubectl get certificate -A -o json | jq -r '
  .items[]
  | select(.spec.privateKey.rotationPolicy == null)
  | [.metadata.namespace, .metadata.name] | @tsv'
```
對清單中「私鑰被外部綁定 / key pinning」的，升級前補上 `spec.privateKey.rotationPolicy: Never`。

### 9.4 每個 hop 後必跑：Vault 簽發 smoke test
在測試 namespace 用**生產的 Vault ClusterIssuer** 簽一張拋棄式憑證，確認端到端可用：
```bash
kubectl create ns cm-smoke 2>/dev/null || true
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: smoke, namespace: cm-smoke }
spec:
  secretName: smoke-tls
  duration: 1h
  privateKey: { rotationPolicy: Never }   # 避免污染稽核；1.21 不要加 spec.renewal
  commonName: smoke.internal.example
  issuerRef: { name: <你的-vault-clusterissuer>, kind: ClusterIssuer, group: cert-manager.io }
EOF
# 斷言 Ready=True（限時 120s）
kubectl wait --for=condition=Ready certificate/smoke -n cm-smoke --timeout=120s \
  && echo "OK: Vault 簽發正常" || kubectl describe certificate/smoke -n cm-smoke
kubectl delete ns cm-smoke
```
> `issuerRef` **務必寫全 `kind` + `group`**（呼應第 5 節 1.19 的 issuerRef 陷阱）。
> 也可用 `cmctl`（自 1.15 起在獨立 repo `cert-manager/cmctl`，<https://cert-manager.io/docs/reference/cmctl/>）：`cmctl status certificate smoke -n cm-smoke`、`cmctl renew` 手動觸發續期測試。

### 9.5 續期風暴 / Vault 失敗告警（Prometheus 範例）
```promql
# 續期風暴：CertificateRequest 簽發 reconcile 速率異常（Vault 的 controller 名稱為 certificaterequests-issuer-vault）
sum(rate(certmanager_controller_sync_call_count{controller=~"certificaterequests-issuer-.*"}[5m])) > 5

# 大量憑證變成 NotReady（升級後最該盯的）
sum(certmanager_certificate_ready_status{condition="False"}) > 0

# 即將到期卻沒續上（Vault 簽發卡住的最終症狀）
count(certmanager_certificate_expiration_timestamp_seconds - time() < 3*24*3600) > 0
```
升級每個 hop 後，**觀察到跨過至少一次自然續期**、確認上述告警無觸發，再進下一個 hop。

---

## 10.〔操作〕生態系元件相容性

> **先確認你裝了哪些**：`kubectl get deploy -A | grep -Ei 'approver-policy|trust-manager|csi-driver|istio-csr'`。若都沒有、只用內建 auto-approver，本節大多可略過，只需看 10.2。

### 10.1 approver-policy（若有安裝，這是最高風險的相依）
- **關鍵風險**：若你用 approver-policy，**cert-manager 內建的 auto-approver 必須關閉**，否則兩者會 race、policy 失效。關閉方式：cert-manager Helm value `disableAutoApproval: true`（**此 value 只在 cert-manager v1.15.0+ 才有**；更早版本需用 controller flag `--controllers=*,-certificaterequests-approver`）。
- **停擺風險**：一旦 approver-policy 在跑，但**沒有任何 CertificateRequestPolicy 匹配**某個請求，該 CertificateRequest 會「既不被核准也不被拒絕」→ 官方原文「**will not be further processed by cert-manager until it gets either approved or denied**」→ **該憑證的簽發直接卡住**。這對「全部走 Vault」的環境是致命的——任何一個 hop 若不小心讓 approver-policy 掛掉或 policy 失配，**所有 Vault 簽發會停擺**。
- **版本對應**：approver-policy **官方沒有發布明確的版本相容矩陣**；它透過 go.mod 緊釘特定 cert-manager 版本，實務上與 cert-manager 版本亦步亦趨。**建議做法**：
  1. 到 <https://github.com/cert-manager/approver-policy/releases> 選一個「go.mod 釘的 cert-manager 版本 ≥ 你當前 hop」的 approver-policy release。
  2. **approver-policy 與 cert-manager 同步升級**：在每個 cert-manager hop 後，若 approver-policy 落後太多就一併升到相容版本，尤其跨到 1.20/1.21（K8s API 版本已拉高）時務必確認 approver-policy 也支援對應 K8s。
  3. 升級順序：先確保 approver-policy 對新 cert-manager 版本相容 → 升 cert-manager → 驗證 CertificateRequest 仍被正常核准（`kubectl get certificaterequest -A` 應無長期 pending）。
- **RBAC 影響**：GHSA-8rvj-mm4h-c258（1.19.6/1.20.3 的 `cert-manager-edit` 收斂）與 1.21 tokenrequest RBAC 移除，**都不影響 approver-policy 自己的 SA**（它有獨立 RBAC）；但仍建議升級後確認 approver-policy 能正常 watch/approve。

### 10.2 若只用內建 auto-approver（無 approver-policy）
- **好消息**：內建 auto-approver 對「內部 signer」（含 Vault issuer 產生的 CertificateRequest）的自動核准語意 **1.14→1.21 全程不變**，預設全開。
- 1.15/1.16 新增的 `disableAutoApproval` / `approveSignerNames` 兩個 value **預設維持原行為**（不設就是全部自動核准），你不必動它們。
- 唯一要知道的：這代表你的 Vault CertificateRequest 一律自動核准——升級不會改變這點。

### 10.3 trust-manager（若有安裝，用於分發 CA bundle）
- trust-manager 依賴 cert-manager 的 CRD 與 cainjector，但兩者是**鬆耦合**、各自獨立版本；1.14→1.21 沒有強制的 lockstep 需求。
- **唯一要留意**：cert-manager **1.19 的 `CAInjectorMerging` 升 Beta 預設開**（cainjector 改為「合併」而非「取代」CA bundle）。若你依賴 cainjector 分發 CA、且有多來源合併的場景，在 1.19 hop 後驗證 trust bundle / webhook CA 注入仍正確。trust-manager 本身不受影響。
- trust-manager 對 K8s 版本有自己的相容窗，跨 K8s 升級時一併確認。

### 10.4 csi-driver / csi-driver-spiffe / istio-csr（若有安裝）
- 這些元件透過 cert-manager 的 `CertificateRequest` API 運作，該 API（`v1`）全程未變，**無強制 lockstep**。
- **但**：istio-csr / csi-driver-spiffe 若使用 `serviceAccountRef` 或依賴特定 RBAC，升 1.21 時同樣要檢查是否踩到 tokenrequest RBAC 移除（第 4.4）。逐一確認各元件的 SA 與 RBAC。
- 保守做法：這些元件也各自看其 release notes 對 cert-manager 最低版本的要求，通常遠低於 1.21，不會是阻礙。

---

## 11.〔操作〕Feature Gate 與設定值清理

### 11.1 為什麼這是隱藏地雷
- 官方推薦的 `helm upgrade --reset-then-reuse-values` 會**把你 1.14 時代的 values 全程帶著走 7 個 hop**——包含 `config.featureGates` 與 `config.*`（ControllerConfiguration / WebhookConfiguration）passthrough。
- cert-manager 的 feature gate 由 Kubernetes `k8s.io/component-base/featuregate` 解析。**當某個 gate 名稱被新版 binary 移除、而你的 config 還設著它時，`MutableFeatureGate.Set()` 會回傳 error「unrecognized feature gate」→ 元件啟動失敗 → CrashLoopBackOff**。同理，某個 gate GA 並「鎖定為預設值」後，若你仍嘗試把它設成非預設值（例如 GA 後還設 `=false`），也會啟動失敗。
- **最陰險的地方**：chart 的 `values.schema.json`（1.16+）**不驗證 `config.*` passthrough 區塊**。所以 `helm template` / `helm upgrade` **不會**在提交時報錯——問題只在 **pod 啟動時** 才爆，且是 CrashLoop（webhook 若也中招，會連帶讓 API 操作全失敗）。**因此不能只靠 `helm template` 預檢，必須在 staging 實際 apply 並看 pod 是否 Ready。**

### 11.2 Feature Gate 生命週期時間軸（1.14 → 1.21）
| Gate | 事件 | 若舊 config 帶著它的後果 |
|---|---|---|
| `ExperimentalGatewayAPISupport` | 1.15 升 Beta 預設開，但「啟用功能」改由 `--enable-gateway-api` flag 控制 | gate 本身在 1.15 仍被接受（無 CrashLoop 風險）；沒用 Gateway API 就從 values 移除，有用則加上 flag（1.21 起為 `config.gatewayAPI.enabled`） |
| `ValidateCAA` | 1.17 deprecated → **1.18 移除** | **1.18 hop 起 CrashLoop**（unrecognized gate） |
| `DefaultPrivateKeyRotationPolicyAlways` | 1.18 Beta（可關）→ **1.20 GA 鎖定** | 若你在 1.18/1.19 設了 `=false`，**1.20 hop 起 CrashLoop**（GA 後不可再設值）→ 必須在 1.20 前移除此 override，改用「每個 Certificate 明確設 `rotationPolicy: Never`」 |
| `ServerSideApply` | **1.21 deprecated**（cainjector SSA 改無條件） | 1.21 起應移除；deprecated 通常先警告，但下一版可能移除 → 及早清掉 |
| `UseDomainQualifiedFinalizer` | 1.16 加入 → 1.17 Beta → 1.18 GA | 一般無害（隨預設演進） |
| `AdditionalCertificateOutputFormats` | 1.15 Beta → 1.18 GA | 無害 |
| `NameConstraints` | 1.17 Beta | 無害 |
| `CAInjectorMerging` | 1.19 Beta 預設開 | 無害（行為改善，見 10.3） |
| `OtherNames` | 1.20 Beta 預設開 | 無害 |

> 規則：**gate「被移除」或「GA 後鎖定」才是地雷**（會 CrashLoop）；單純「升 Beta/GA、預設值演進」不會讓你當機，只是行為隨預設改變。

### 11.3 逐 hop 要清掉的東西
1. **進 1.15 前**：若 config 有舊的 `ExperimentalGatewayAPISupport` gate 用法，改為 `--enable-gateway-api` / `config.enableGatewayAPI`（沒用 Gateway API 就直接移除）。
2. **進 1.18 前**：**移除 `ValidateCAA`**（任何值都會在 1.18 讓 controller 起不來）。
3. **進 1.20 前**：**移除 `DefaultPrivateKeyRotationPolicyAlways: false` 這類 override**；要保留舊私鑰行為改用「Certificate 上明確 `rotationPolicy: Never`」（第 4.1）。
4. **進 1.21 前**：清掉 `ServerSideApply` gate；把 `config.enableGatewayAPI` / `config.enableGatewayAPIListenerSet` 改為 `config.gatewayAPI.enabled` / `config.gatewayAPI.enableListenerSet`（deprecated 改名，注意這是 `config.*` 下的 ControllerConfiguration 欄位，不是頂層 chart value）。

### 11.4 每個 hop 的 config 預檢流程
```bash
# (a) 先看你目前帶了哪些 gate / config
helm get values cert-manager -n cert-manager | grep -A30 -E 'featureGates|config:'

# (b) helm template 只能抓「頂層 value」的 schema 問題，抓不到 config.* 內的壞 gate：
helm template cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v<目標> --values your-values.yaml >/dev/null   # 通過 ≠ 安全

# (c) 真正的預檢：在 staging apply 後確認三個 Deployment 都 Ready、無 CrashLoop
kubectl -n cert-manager rollout status deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector --timeout=120s
kubectl -n cert-manager get pods   # 看有無 CrashLoopBackOff
kubectl -n cert-manager logs deploy/cert-manager | grep -i 'unrecognized\|feature gate\|error'  # 抓 gate 錯誤
```
> 若某 hop 的 controller/webhook 起不來且 log 出現 `unrecognized feature gate` 或 `feature gate ... is locked`，就是本節的地雷——回到 11.3 把對應的 gate/override 從 values 清掉再重試。

---

## 12. 回滾計畫（每個 hop 都要有）

cert-manager **官方沒有任何回滾/降版文件**——以下為經實機驗證的自建程序。

### 12.1 為什麼回滾相對安全
- CRD 全程 `v1` + `conversion: none` + schema 只增不減 → 降 CRD 只會「隱藏並最終 prune 掉新欄位」，**不會壞資料、API server 不報錯**。
- chart 把 CRD 當**一般 template**（非 `crds/` 特殊目錄），所以 **`helm rollback` 會把 controller + webhook + RBAC + CRD 一起原子性地回退**到上一個 revision。
- 最大的 CRD（clusterissuers，約 147KB compact JSON）**未超過** 262144-byte 的 last-applied annotation 上限，所以靜態管理時 client-side `kubectl apply` 舊版 CRD 也能正確移除新欄位。

### 12.2 回滾程序
- **CRD 由 Helm 管理**：`helm rollback cert-manager <上一個 revision> -n cert-manager`（升級前先 `helm history` 記下 revision）。
- **CRD 靜態管理**：`helm rollback` **不會**動 CRD，需另外 `kubectl apply -f <舊版>/cert-manager.crds.yaml`。
- **1.21→1.20.3 回滾**：降 CRD 會 prune 掉 `spec.renewal`，順帶消除 #9031 crash 觸發條件。
- **絕對禁止用 `helm uninstall` 來降版**——會刪 CRD → 垃圾回收掉所有 Certificate/Issuer。runbook 明文禁止。

### 12.3 不可逆的部分（回滾也救不回）
- **1.18+ 已輪替的私鑰**：回滾不會把私鑰換回舊的——這正是每個 hop 都要備份 Secret 的原因（提供 TLS 連續性）。
- **回滾休息點**：目前只有 1.20/1.21 在支援期；**1.20.3 是唯一「受支援」的回滾停靠點**。若升級中途已升 K8s，可能讓更早的 cert-manager 版本變成不受支援，回滾窗口就關了。

### 12.4 每個 hop 前的備份（官方 backup 指令 + Vault 補充）
```bash
# 1) 官方 backup（排除 CertificateRequests/Orders/Challenges）
kubectl get --all-namespaces -o json issuer,clusterissuer,cert > backup-preHop.json
# 2) 憑證 Secret（只撈 cert-manager 簽發的：以 annotation 篩選，避免全叢集 Secret dump）
kubectl get secret -A -o json | jq '[.items[]
  | select(.metadata.annotations["cert-manager.io/certificate-name"] != null)]' \
  > backup-cert-secrets-preHop.json
# 2b) Vault issuer 引用的認證 Secret（token/appRole/client-cert/CA bundle——名單來自第 6.3 節稽核輸出）
kubectl get secret -n <issuer-secret-ns> <vault-auth-secret...> -o yaml > backup-issuer-secrets-preHop.yaml
# ⚠️ 備份檔含私鑰與 Vault 憑證，落地位置要加密且限制存取
# 3) CRD 定義
kubectl get crd certificates.cert-manager.io certificaterequests.cert-manager.io \
  issuers.cert-manager.io clusterissuers.cert-manager.io \
  orders.acme.cert-manager.io challenges.acme.cert-manager.io -o yaml > backup-crds-preHop.yaml
# 4) Helm 狀態
helm get values cert-manager -n cert-manager > backup-values-preHop.yaml
helm history cert-manager -n cert-manager > backup-history-preHop.txt
```

---

## 13. 建議執行時序（把前面所有東西串起來）

### 階段 0：準備（不動生產）
0. **盤點現況安裝方式**（整份計畫的路徑選擇取決於此）：
   - `helm list -A | grep cert-manager` → release 名稱、namespace、chart 版本；`helm get values` 取得現行 values（若 values 沒有版控，這就是起點基準）。
   - CRD 是 Helm 管的還是靜態 `kubectl apply` 的？（`kubectl get crd certificates.cert-manager.io -o jsonpath='{.metadata.labels}'`——有 `app.kubernetes.io/managed-by: Helm` 即 Helm 管）→ 決定第 7 節走哪條路。
   - 是否由 Argo CD / Flux 管理？→ 是的話全程改用第 7.4 節的對應機制。
   - 確認目前 patch 版本是否已是 1.14.7（不是就先升到 1.14.7 再開始，起點含 Vault 重試修正的 backport）。
1. 建 staging 叢集，**逐 hop 完整彩排**（含回滾）。cert-manager 對降版零保證，staging 演練是硬需求。
2. 跑第 6.3 節 Vault 曝險稽核 + 第 9 節 rotationPolicy 稽核，產出「受影響資源清單」。
3. 盤點生態系元件（approver-policy / trust-manager / csi-driver）版本（第 10 節）。
4. air-gapped 環境：mirror 每個目標版本的 image（**注意 1.15 的 startupapicheck image 改名**）。
5. **升 HA**：把 controller/webhook/cainjector 拉到多副本 + 設 PDB（第 8 節），讓升級視窗不中斷。
6. 規劃 K8s 交錯升級時序（第 2.1 節），確認 1.20/1.21 前 K8s 版本到位。

### 階段 1：低風險 hop（1.14→1.15→1.16→1.17）
- 1.15：執行 `installCRDs → crds.enabled` 遷移（第 7.2）。
- 1.16：**先 `helm template` 驗 values**，清掉會 schema 失敗的 key（第 4.3）。用 1.16.5。
- 1.17：注意 log 轉結構化，改 log 字串告警。

### 階段 2：行為變更 hop（1.17→1.18）★最需謹慎
- **升級前**：對「需保留私鑰」的 Certificate 明確設 `rotationPolicy: Never`（第 4.1）；決定 `revisionHistoryLimit`（第 4.2）。用 1.18.6。
- 升級後密切觀察續期/簽發 metrics（第 9 節）。

### 階段 3：跨 1.19（1.18→1.19）★避開續期風暴
- **升級前**：把所有 Certificate 的 `issuerRef` 補齊 `kind` + `group`（第 5 節 1.19）。**直接上 1.19.6，絕不停在 1.19.0**。
- 若 K8s 尚未到 1.32/1.33，在此之後、進 1.20 之前完成 K8s 升級。

### 階段 4：收尾（1.19→1.20→1.21）
- 1.20：確認 K8s ≥ 1.32；注意 container UID/GID 改 65532（第 5 節）；rotationPolicy gate 在此 GA 定案。用 1.20.3。
- 1.21：確認 K8s ≥ 1.33；**升級前補 tokenrequest RBAC**（第 4.4）；更新 Prometheus ServiceMonitor（port 改名 + 移除的 value）；**禁用 `spec.renewal`**（第 5 節 1.21）。

### 每個 hop 的通用檢查點
0. **時機檢查**：確認接下來 24h 內沒有大批憑證排定續期（有的話改期，避免升級窗口撞上續期高峰）：
   ```bash
   kubectl get certificate -A -o json | jq '[.items[]
     | select(.status.renewalTime != null)
     | select((.status.renewalTime | fromdateiso8601) < (now + 86400))] | length'
   ```
1. 備份（第 12.4）→ 2. `helm template` 驗 values（記住抓不到 `config.*`，見 11.4）→ 3. `helm upgrade` → 4. 三個 Deployment rollout 完成、無 CrashLoop → 5. **跑 Vault 簽發 smoke test**（第 9.4，驗證「新簽發」路徑）→ 6. **對一張常駐 canary 憑證跑 `cmctl renew`，驗證「續期」路徑**（不要等自然續期——7 個 hop 每個都等不現實；canary 用短 duration 的專用憑證，強制續期後確認 Ready 且 `not_before` 更新）→ 7. 檢查 metrics：無續期風暴、`certmanager_certificate_ready_status{condition="False"}` 無新增、Issuer 皆 Ready=True → 8. 高風險 hop（1.18、1.19、1.21）建議多觀察一個工作天再進下一個 hop；低風險 hop（1.15/1.16/1.17）驗證通過即可續行。

---

## 14. 附錄：關鍵風險一覽

| 風險 | 觸發 hop | 嚴重度 | 緩解 |
|---|---|---|---|
| 私鑰非預期輪替 | 1.18 | 中～高 | 事前設 `rotationPolicy: Never` |
| Helm upgrade 因 schema 失敗 | 1.16 / 1.21 | 中 | 事前 `helm template` 驗證、清 value |
| 續期風暴 | 1.19.0 | 高 | 補齊 issuerRef、跳過 1.19.0 上 1.19.6 |
| Vault K8s auth 壞掉 | 1.21 | 高 | 事前補 tokenrequest RBAC |
| Vault role audience 改太早 | 任何 | 高 | 升級期間 audience 維持 `vault://...` |
| controller crash-loop | 1.21 | 高 | 不使用 `spec.renewal`（或等 1.21.1） |
| 監控中斷 | 1.16/1.20/1.21 | 中 | 各 hop 同步更新 ServiceMonitor/scrape |
| CRD 被誤刪 | 1.15 / 回滾 | 極高 | 絕不 uninstall、正確做 installCRDs 遷移 |
| K8s 版本不相容 | 1.20 / 1.21 | 高 | 交錯升 K8s（≥1.32 / ≥1.33）|

---

## 15. 實機實驗驗證（直跳 vs 分批）

本計畫的關鍵論點已在 k3s + 真實 Vault 環境完整走過兩條升級路徑驗證——**1.14.7 直跳 1.21.0** 與 **7 hop 逐版升級**，含 11 個實證、1.19.0 誤重簽機制重現、#9031 crash 重現、helm rollback 實測（16 秒完成且 CRD 同步回退）。完整報告、腳本與原始記錄見 [`cert-manager-upgrade-experiment/REPORT.md`](cert-manager-upgrade-experiment/REPORT.md)。

一句話結論：**直跳機械上可行（CRD 純增量所賜），但把 7 個版本的行為變更壓進同一個變更窗、失去逐版歸因能力與近距離回退點；生產環境維持本計畫的分批路徑。**

---

*本文件基於 cert-manager 官方 release notes、GitHub releases、官方升級文件，並對關鍵論點做對抗式驗證與 k3s + 真實 Vault（1.16.3 / 1.20.4 / 1.21.4）實機測試。所有版本事實驗證於 2026-07-24。升級路徑實機驗證於 2026-07-25（見第 15 節）。*
