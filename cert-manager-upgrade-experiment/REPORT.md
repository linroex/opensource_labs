# cert-manager 1.14.7 → 1.21.0 實機升級實驗：直跳 vs 逐版分批

> 實驗日期：2026-07-25。環境：本沙箱 k3s v1.30.5（單節點）+ 真實 Vault 1.16.3（dev mode）+ 官方 cert-manager Helm charts（quay.io OCI）。
> 目的：回答「一次升級完（1.14 直跳 1.21）與分批次升級（7 個 hop）到底差在哪」，並實證升級計畫文件中的關鍵論點。

---

## 1. 實驗設計

### 1.1 Fixtures（兩個情境完全相同）
**Vault**：真實 Vault dev server，PKI engine 簽發、kubernetes auth（TokenReview 對接 k3s API）+ appRole auth。

**3 個 ClusterIssuer**（覆蓋三種 auth 模式）：
| Issuer | Auth | 設計目的 |
|---|---|---|
| `vault-ctrl-sa` | kubernetes auth，`serviceAccountRef` → **controller 自己的 SA** | 追蹤 1.21 RBAC 移除的破壞弧線 |
| `vault-dedicated-sa` | kubernetes auth，專用 SA + 自建 RBAC（官方推薦） | 對照組：應全程存活 |
| `vault-approle` | appRole | 對照組：不受任何版本變更影響 |

**6 張 Certificate**：
| 憑證 | 特徵 | 設計目的 |
|---|---|---|
| `cert-legacy` | issuerRef **缺 group**、未設 rotationPolicy | 1.19.0 defaulting 陷阱 + rotation 翻轉受害者 |
| `cert-nokind` | issuerRef **kind+group 全省略**（namespaced Issuer） | 1.19.0 陷阱的加強版 |
| `cert-pinned` | 完整 issuerRef + `rotationPolicy: Never` | 金鑰連續性對照組 |
| `cert-canary` | 1h 憑證 + 55m renewBefore → **每 ~5 分鐘續期** | 觀察「續期時換不換私鑰」的行為翻轉 |
| `cert-ctrlsa` | 走 `vault-ctrl-sa` issuer | RBAC 弧線的憑證側觀察 |
| `cert-approle` | 走 appRole issuer | 對照組 |

**Values 檔埋了兩個真實世界常見的暗雷**：
```yaml
installCRDs: true
replicaCounts: 2          # ← 打錯字（正確是 replicaCount）：1.14 無 schema，默默被吞
prometheus:
  servicemonitor:
    targetPort: 9402      # ← 1.14 合法、1.21 被移除的 value
```

### 1.2 兩個情境
- **情境 A（直跳）**：1.14.7 → `helm upgrade` 一步到 1.21.0
- **情境 B（分批）**：1.14.7 → 1.15.5 → 1.16.5 → 1.17.4 → 1.18.6 →（支線：刻意上 1.19.0 + helm rollback 實測）→ 1.19.6 → 1.20.3 → 1.21.0

---

## 2. 結果總表：11 個實證

| # | 實證 | 情境 | 證據 |
|---|---|---|---|
| 1 | **1.14 無 schema 驗證**：`replicaCounts` 打錯字被默默忽略（部署了 1 副本而非 2） | A/B | install 成功、replicas=1 |
| 2 | **1.14 chart 沒有內建 tokenrequest Role**：ctrl-SA issuer 一開始就 `serviceaccounts/token forbidden` | A/B | issuer Ready=False + 完整錯誤訊息 |
| 3 | **1.14 續期不換私鑰**：canary 續期後序號變、keyhash 不變（`e50508854e50`） | A | snap-A1 |
| 4 | **直跳第一擊被 schema 擋下**（動叢集之前）：兩個暗雷一次列出 | A | `replicaCounts is not allowed` + `targetPort is not allowed`，release 停在 rev1/1.14.7 |
| 5 | **升級不觸發重新簽發**：直跳後 legacy/pinned/approle 序號、notBefore 全部未變 | A/B | snap-A2 |
| 6 | **revisionHistoryLimit=1 生效**：canary 的 CertificateRequest 2 → 1（升級後被 GC） | A | snap-A1 vs A2 |
| 7 | **1.21 上續期會換私鑰**：同一張 canary，keyhash `e50508854e50` → `53e5c7093331` | A | snap-A3；與實證 3 成對 |
| 8 | **#9031 crash 重現**：套 `spec.renewal.policy: Disabled` → 40 秒內 controller CrashLoopBackOff；刪憑證+重建 pod 即復原 | A(1.21) | bonus-crash-9031.log |
| 9 | **1.16 schema 只抓當時非法的 key**：typo 在 1.16 hop 被抓（`targetPort` 通過）；`targetPort` 在 1.21 hop 才被抓 → **分批把每個問題定位在引入它的版本** | B | scenario-B.log |
| 10 | **ctrl-SA issuer 完整弧線**：1.14 壞 → **1.16 出現 `cert-manager-tokenrequest` Role、issuer 翻 Ready=True** → 1.20 仍好 → **1.21 Role 消失、issuer 翻 False**（同一條 forbidden 錯誤回歸） | B | kubectl get role + issuer 狀態逐 hop 記錄 |
| 11 | **helm rollback 可用且 CRD 跟著回**：1.19.0 → 1.18.6 回滾 16 秒完成，CRD 的 issuerRef default 同步消失 | B 支線 | helm history rev7 "Rollback to 5" |

### 加碼：1.19.0 誤重簽機制（比預期更陰險）
- 只缺 `group` 的 cert-legacy 在升上 1.19.0 後 **90 秒內沒有立即重簽**（讀取路徑的 defaulting 對兩邊物件同時生效，比對相等）。
- 但在 CRD schema 轉換邊界（本實驗中是 rollback 時；生產中是任何物件被寫入時），default 值被**非對稱地持久化**，觸發一次性誤重簽，事件記錄：
  > `Issuing — Fields on existing CertificateRequest resource not up to date: [spec.issuerRef]`
- cert-legacy 因此被重簽（serial `23E0…` → `5A25…`），**且因 rotationPolicy=Always 已生效，私鑰一併被換掉**（keyhash `9ca4e83c79f8` → `ac32652ab2bd`）。
- **修正認知**：這不是「升級瞬間的可見風暴」，而是**時點不可預測的逐張誤重簽**——生產數千張憑證時等於一段時間內的隨機重簽+換鑰潮，觀測上更難歸因。`cert-pinned`（完整 issuerRef）全程序號、私鑰皆未動。

### 金鑰連續性總結（情境 B 全程）
| 憑證 | B0 (1.14.7) | B7 (1.21.0) | 結論 |
|---|---|---|---|
| cert-pinned（`Never`） | `08964c8826e3` | `08964c8826e3` | **私鑰全程未變** —「事先明確設 rotationPolicy」策略有效 |
| cert-legacy（未設） | `9ca4e83c79f8` | `ac32652ab2bd` | 被 1.19.0 陷阱誤重簽時連鑰匙一起換 |
| cert-canary（未設，高頻續期） | `5a5fd074209d` | `5226d2bba1be` | 1.18+ 每次續期都換鑰 |

---

## 3. 直跳 vs 分批：實測對比

| 維度 | 情境 A：直跳 | 情境 B：分批（7 hop） |
|---|---|---|
| helm 操作時間 | **24 秒**（2s 失敗 + 22s 成功） | 132 秒（7 hop 合計，含 2 次 schema 失敗） |
| 操作次數 | 2 次（1 失敗 1 成功） | 9 次（7 成功 + 2 次預期內失敗） |
| values 修正 | 1 次（兩個問題一起修） | 2 次（各自在引入問題的版本修） |
| **失敗的可歸因性** | 所有問題一次糊臉：schema 錯誤 2 條同時、行為變更（rotation/RBAC/GC）同時生效——出問題時**無法區分是 7 個版本中哪一個造成** | 每個問題出現在引入它的 hop：typo→1.16、targetPort→1.21、Role 消失→1.21、rotation 翻轉→1.18 hop 後首次續期。**歸因零猜測** |
| **回滾姿態** | 唯一回退點是 EOL 兩年的 1.14.7；且一回就是 7 個版本的行為全部回退 | 每個 hop 都有「一步之遙」的回退點；**實測 16 秒回滾且 CRD 同步回退** |
| 已知地雷 | 天然跳過 1.16.0 / 1.19.0（諷刺的優勢） | 靠「最新 patch」紀律避開；實驗證明踩 1.19.0 的代價 |
| 官方支援 | 明確不在支援範圍（「may be possible」） | 唯一受支援路徑 |
| 最終狀態 | 兩者完全一致（同 CRD schema、同 issuer 狀態、同行為） | 同左 |

### 結論
1. **機械上直跳是可行的**——這歸功於此範圍 CRD 全程 `v1`-only、schema 純增量、無 storage migration。第一次 schema 失敗甚至是「免費的 pre-flight」（在動到任何叢集狀態前擋下）。
2. **但「能成功」不是重點——差異全在風險工程**：
   - 直跳把 7 個版本的行為變更壓進同一個變更窗。本實驗僅 6 張憑證、3 個 issuer 就有 4 類行為同時翻轉（rotation、GC、RBAC、metrics port）；生產規模下若升級後出現異常，**你面對的是 7 個版本的變更疊加的除錯空間**。
   - 分批的真正價值在實證 #9/#10：**每個問題在引入它的版本現身**，且每一步都有近距離、已驗證可用的回退點。
   - 1.19.0 支線證明了「最新 patch」紀律的必要性——而且誤重簽在 1.18+ 會**連私鑰一起換**，對金鑰敏感的消費端是雙重傷害。
3. **對生產環境的建議不變**（與升級計畫一致）：走分批路徑。本實驗中直跳的「快」只省了 108 秒的 helm 時間——生產升級的成本大頭在驗證與觀察窗，不在 helm 指令本身；用 108 秒換掉可歸因性與回退點，不划算。
4. **若真要直跳**（例如拋棄式環境、或叢集重建策略）：實驗確認需要预先做的事與分批完全相同（values 清理、RBAC 補齊、rotationPolicy 明確化）——差別只是你必須**一次全部做對**。

---

## 4. 與升級計畫的對照

| 計畫章節 | 論點 | 實驗結果 |
|---|---|---|
| §4.1 | 1.18 rotation 翻轉，事先設 `Never` 可保鑰 | ✅ 實證 3/7 + cert-pinned 全程鑰匙未變 |
| §4.3 | 1.16 schema 會擋打錯字 | ✅ 實證 9，且錯誤訊息精確列出 key |
| §4.4 | 1.21 移除 tokenrequest RBAC | ✅ 實證 10（完整弧線，含 1.16 才出現該 Role 的細節） |
| §5 (1.19) | 絕不停 1.19.0 | ✅ 誤重簽重現 + 機制釐清（時點不可預測、連鑰帶換） |
| §0.6/§12 | 升級不觸發重簽；rollback 可行且 CRD 跟著回 | ✅ 實證 5/11 |
| §5 (1.21) | #9031 crash，禁用 spec.renewal | ✅ 實證 8（40 秒內 CrashLoop、可復原） |
| §7.2 | installCRDs→crds.enabled 遷移 | ✅ B hop1 平順完成；A 中 `installCRDs: true` 在 1.21 仍可用（deprecated） |
| §9.2 | 1.20 雙 audience 不破壞 Vault 登入 | ✅ dedicated-SA/approle issuer 跨 1.20 全程 Ready |

**計畫需微調的一點**：1.19.0 的風險描述應從「升級時的續期風暴」修正為「**CRD defaulting 造成的延遲性、逐張誤重簽（且連帶換私鑰）**」——時點不可預測反而更難監控，強化了「事先補齊 issuerRef kind+group」的必要性。

---

## 5. 實驗限制（誠實聲明）

1. **K8s 固定 v1.30**：cert-manager 1.19–1.21 的官方測試下限是 K8s 1.31–1.33，本實驗在 1.30 上運行它們一切正常——證明「tested window ≠ 硬性需求」，但生產環境仍應遵守官方相容窗（本實驗不覆蓋計畫 §2.1 的 K8s 交錯升級部分）。
2. **單節點、單副本、無 HA**：升級視窗的 webhook 中斷觀察不在本實驗範圍（計畫 §8 的 HA 建議未驗證）。
3. **規模**：6 張憑證。生產數千張時，1.19.0 誤重簽與 rotation 翻轉的 blast radius 按比例放大。
4. **Vault dev mode（HTTP、單機）**：TLS/serverName/caBundle 路徑未測；audience 行為已由先前實驗（真實 Vault 1.16.3/1.20.4/1.21.4 三版矩陣）覆蓋。
5. **沙箱陷阱**：host 上的 Vault process 會繼承 `HTTPS_PROXY` 導致 TokenReview 失敗——`scripts/vault-setup.sh` 已含修正（清空 proxy 環境變數）。

## 6. 重跑方式

```bash
# 1) k3s（含 runc wrapper，見 .claude/skills/k3s-experiment）+ helm + vault binary
# 2) Vault：
scripts/vault-setup.sh
# 3) 1.14.7 基線：
scripts/reset-to-1.14.sh
# 4) 逐 hop helm upgrade（指令與 values 演進見 manifests/ 與 results/scenario-B.log）
# 快照：scripts/snapshot.sh <label>
```

原始記錄：`results/`（snap-*.txt、scenario-A.log、scenario-B.log、bonus-storm-1190.log、bonus-crash-9031.log、timings.txt）。
