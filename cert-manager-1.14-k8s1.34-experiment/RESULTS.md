# cert-manager 1.14 on Kubernetes 1.34 — 實測風險評估

實測日期:2026-06-29
目的:評估**短期內**維持 cert-manager 1.14 跑在 k8s 1.34 的可行性與風險,聚焦使用者實際使用的 **self-signed** 與 **Vault** issuer。

## 環境

| 元件 | 版本 |
|---|---|
| Kubernetes (k3s) | **v1.34.9+k3s1** |
| cert-manager (controller/webhook/cainjector) | **v1.14.7** |
| Vault (dev 模式, PKI engine) | v2.0.2 |

> 註:cert-manager 1.14 官方測試上限為 k8s 1.31 且已 EOL。本實測刻意把它放到 1.34.9(高 3 個 minor)以驗證真實行為。

## 測試結果總覽

| 測試項目 | 結果 |
|---|---|
| cert-manager 安裝 / 全組件啟動 | ✅ 通過(含 startupapicheck) |
| Pod 重啟 / 崩潰 | ✅ 0 重啟、0 崩潰 |
| CRD (`apiextensions.k8s.io/v1`) 安裝於 1.34 apiserver | ✅ 通過 |
| webhook(validating/mutating, `admissionregistration v1`) | ✅ 通過 |
| API 棄用 / version-skew 警告(controller log + kubectl) | ✅ 無任何警告 |
| **self-signed** Issuer 簽發 | ✅ 通過 |
| **self-signed → CA** issuer 鏈簽發 + 鏈驗證 + SAN | ✅ 通過 |
| **Vault** Issuer(Kubernetes auth / serviceAccountRef) | ✅ 通過 |
| Vault 簽發憑證鏈驗證 | ✅ 通過 |
| self-signed 憑證**自動續期** | ✅ 通過(serial 變更 + 鏈驗證 OK) |
| Vault 憑證**自動續期** | ✅ 通過(serial 變更 + 鏈驗證 OK) |

## 細節

### self-signed
- `Issuer{selfSigned}` → 簽發 root CA(`isCA`)→ `Issuer{ca}` → 簽發 leaf。
- leaf 鏈用 `openssl verify` 對 CA 驗證:**OK**;SAN `app.example.test, api.example.test` 正確。

### Vault(最能踩到 k8s 版本敏感路徑的測試)
- 路徑:cert-manager `serviceAccountRef` → **TokenRequest**(建立 bound SA token)→ Vault `kubernetes` auth login → Vault **TokenReview** 驗證 → PKI `pki/sign` 簽發。
- Issuer 狀態:`Ready=True / VaultVerified`;leaf 由 `CN=vault-experiment-root` 簽出,鏈驗證 **OK**。
- 過程中發現需補的 RBAC(**這是設定問題,不是相容性問題**):cert-manager controller SA 需 `create` `serviceaccounts/token`(見 `manifests/03-vault-tokenrequest-rbac.yaml`)。此為 cert-manager 1.14 使用 serviceAccountRef 的標準要求,與 k8s 版本無關。

### 續期
兩張 leaf 憑證皆設 `duration:1h / renewBefore:55m`,強制在簽發後約 5 分鐘觸發續期。
cert-manager 續期控制器在排程的 `renewalTime` 自動換發新憑證(serial 改變即證明):

| 憑證 | 原 serial | 續期後 serial | 時間 | 續期後鏈驗證 |
|---|---|---|---|---|
| self-signed leaf | `CC8FF5E9…EBFE` | `203374C1…F9C7` | 08:14:14Z | OK |
| vault leaf | `0D0FEE47…702B` | `2E5A1492…1168` | 08:16:46Z | OK |

全程 cert-manager pod **0 重啟**。詳見 `results/renewal-results.txt`。

## 結論

在 k8s 1.34.9 上,cert-manager 1.14.7 的**安裝、self-signed 與 Vault 兩種 issuer 的簽發路徑、CRD/webhook、Kubernetes auth (TokenRequest/TokenReview)** 均正常運作,**未觀察到任何被 sunset 的 API 造成的功能破壞,也無 version-skew 警告**。

→ 證實先前評估:1.31→1.34 之間**沒有 cert-manager 1.14 直接依賴的 GA API 被移除**,短期內「能跑」的可行性已由實測支持。

### 仍須注意(實測無法消除的風險)
1. **EOL 無安全修補** — 此組合不受官方支援,1.14 不再收 CVE patch。短期可接受,但要設明確升級期限。
2. **client-go skew** — 本次未觸發問題,但屬未保證範圍,複雜情境(大量 CR、特殊 webhook 行為)仍可能有邊界差異。
3. 建議升級目標:cert-manager **1.19 / 1.20**(官方測試涵蓋 k8s 1.34)。
