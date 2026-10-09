# k3d + cert-manager 1.20.3 + Vault (PKI)

k3d 測試環境：Kubernetes 1.34、cert-manager、Vault，cert-manager 透過 Vault PKI 簽發憑證。

| 元件 | 版本 |
|---|---|
| Kubernetes (k3s) | `rancher/k3s:v1.34.12-k3s1` |
| cert-manager | chart / app `v1.20.3` |
| Vault | chart `0.34.1`（Vault 2.0.4，**dev mode**） |
| k3d | v5.8.3 |

## 使用

```bash
scripts/up.sh      # 建立叢集、安裝 Vault / cert-manager、設定 PKI 與 ClusterIssuer（可重複執行）
scripts/test.sh    # 在 demo namespace 簽一張憑證並用 Vault root CA 驗證
scripts/down.sh    # 刪除叢集
```

需求：docker、k3d、kubectl、helm、openssl。

### 在受限環境（本 repo 的雲端沙箱）

若 Docker host 沒有 `CAP_SYS_RESOURCE`，且出口經 TLS 攔截的 proxy，需要：

```bash
EXTRA_CA_BUNDLE=/root/.ccr/ca-bundle.crt PATCH_RUNC=1 scripts/up.sh
```

- `EXTRA_CA_BUNDLE`：把 CA bundle 掛進節點，containerd 才能拉 image（否則 `x509: certificate signed by unknown authority`）。
- `PATCH_RUNC=1`：包裝節點內的 runc，將 `oomScoreAdj` 重設為 0（否則 pod 全部卡在 `failed to update /proc/self/oom_score_adj`）。
- 沙箱內需先手動啟動 `dockerd`（沒有 systemd）。

一般機器不需要這兩個變數。

## 架構

```
Certificate (demo) ──> ClusterIssuer/vault-issuer ──> Vault  pki/sign/example-dot-com
                         │  cert-manager 以 SA cert-manager/vault-issuer 申請 token（audience=vault）
                         └─> Vault Kubernetes auth (role cert-manager, policy cert-manager)
```

- Vault PKI：內部 root CA `Lab Root CA`；role `example-dot-com` 僅允許 `example.com` 及子網域（`key_type=any`，max TTL 72h）。
- Vault policy `cert-manager` 只允許 `pki/sign/example-dot-com`。
- 認證用 Kubernetes auth，非靜態 token；cert-manager 控制器需有 `serviceaccounts/token` create 權限（見 `manifests/cert-manager-vault-auth.yaml`）。

## 注意事項

- Vault 是 dev mode：in-memory、HTTP、root token 為 `root`，**重啟 `vault-0` 會遺失所有設定**，需重跑 `scripts/configure-vault.sh`（以及既有憑證會失效）。
- 存取 Vault UI/CLI：`kubectl -n vault port-forward svc/vault 8200` 後用 `VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root`。
- 若簽發失敗，cert-manager 會對該 Certificate 做指數退避；修好 Vault 設定後請刪除並重建 Certificate 才會立即重試。
- 叢集使用 cgroup v1 的 host 時 kubelet 會警告 `CgroupV1`，1.34 仍可運作。
