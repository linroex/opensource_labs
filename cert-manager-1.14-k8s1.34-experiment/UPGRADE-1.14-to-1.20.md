# cert-manager 1.14.7 → 1.20.3 升級實測(on k8s 1.34.9）

在同一個 k3s **1.34.9** 叢集上,把既有的 cert-manager **1.14.7** 用 `helm upgrade` 直接升到 **1.20.3**
(跨 6 個 minor),並驗證升級後 self-signed / Vault issuer 的簽發與續期仍正常。

## 結論:可直接一次升上去,只有「一個」必改設定

直接從 1.14 跳到 1.20 的 `helm upgrade` 成功,既有憑證不中斷、可正常續期。
過程中 Helm 只回報**一個**需要調整的 values 設定。

## 需要調整的設定

### 1.（必改)`installCRDs` → `crds.enabled` / `crds.keep`

舊版用的 `--set installCRDs=true` 在新版 chart 會跳:

```
⚠️  WARNING: `installCRDs` is deprecated, use `crds.enabled` instead.
```

改成:

```diff
- --set installCRDs=true
+ --set crds.enabled=true
+ --set crds.keep=true     # 建議:讓 CRD 帶 helm.sh/resource-policy: keep,
                           # 避免日後 helm uninstall 連同 CRD 一起刪掉(會連帶刪光所有憑證)
```

升級後實測 CRD 狀態:

```
served:v1 | helm-managed-by:Helm | keep-annotation:keep
```

> 註:`installCRDs=true` 仍可運作(只是 deprecated),但建議趁這次改掉。
> `crds.keep=true` 是新版才有的安全網,強烈建議開。

### 其他:本次測試的 values 沒有其他需要改的

本實驗只用到 `installCRDs` 與 `startupapicheck.timeout`,後者在 1.20 仍有效。
若你的正式 `values.yaml` 還用了下列項目,升級前請逐一對照 1.15→1.20 各版 release notes:

- `featureGates`(格式仍為逗號字串,但部分 gate 已 GA/移除,傳已移除的 gate 會讓 pod 啟動失敗)
- `extraArgs` 內的 `--` flags(個別 flag 可能在某版被移除)
- `prometheus.*`、`webhook.*`、`cainjector.*` 的巢狀結構(大方向不變,但建議 `helm upgrade --dry-run` 先比對)

**通用做法**:升級前一定先跑 `helm upgrade ... --dry-run` 把所有 deprecation/error 撈出來再正式升。

## 升級指令(實測通過版本)

```bash
helm upgrade cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.20.3 \
  --set crds.enabled=true \
  --set crds.keep=true \
  --set startupapicheck.timeout=4m \
  --wait --timeout 5m
```

## 升級後驗證結果

| 項目 | 結果 |
|---|---|
| helm release | revision 2,chart `cert-manager-v1.20.3`,status deployed |
| controller / webhook / cainjector pod | 全部 `v1.20.3`、Ready、**0 重啟** |
| 既有 `root-ca` / `leaf-selfsigned` / `leaf-vault` 憑證 | 升級後仍 `Ready=True`,不中斷 |
| CRD | `served: v1`、`managed-by: Helm`、`resource-policy: keep` |
| controller log | 無 error / 棄用 / 版本警告 |
| **self-signed leaf 升級後續期** | ✅ 新 serial `5B046C0B…`、鏈驗證 OK |
| **vault leaf 升級後續期** | ✅ 新 serial `228CFD82…`、鏈驗證 OK,issuer `VaultVerified` |

> 註:本實驗的 Vault 是 dev(in-memory)模式,叢集重啟後其 PKI/auth 設定會清空,
> 已在升級後重新套用同一份設定再驗證——這與 cert-manager 升級本身無關,正式環境的
> Vault(持久化儲存)不受影響。

## 升級路徑建議

- **跨 6 個 minor 一次直升 1.14 → 1.20 在本實驗可行**且憑證不中斷。
- 仍建議正式環境:先在測試叢集 `--dry-run` + 實跑一遍,確認自家 `values.yaml` 沒有用到被移除的 flag/feature-gate;
  並在升級後盯一個續期週期確認 renew 正常。
