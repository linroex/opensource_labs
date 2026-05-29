# Fluentd → Vector 實驗（k3s）

用單節點 k3s 實測 **Fluentd 透過 Forward 協定把 log 送到 Vector**，並找出
「哪些設定參數可以送成功」。

## 架構

```
┌─────────────────────────┐         Fluentd Forward Protocol         ┌─────────────────────────┐
│ fluentd (deploy)        │            (TCP, port 24224)             │ vector (deploy)         │
│  in_sample 產生測試 log  │ ───────────────────────────────────────▶ │  source type=fluent     │
│  out_forward            │                                          │  sink   type=console    │
└─────────────────────────┘                                          │  + prometheus_exporter  │
                                                                      └─────────────────────────┘
```

- Fluentd 端用 `in_sample`（舊名 `in_dummy`）每秒產生 5 筆測試 log，
  再用 `out_forward` 送出。
- Vector 端用 `fluent` source 接收（它實作了 Fluentd Forward 協定的 wire format），
  `console` sink 把收到的事件印成 JSON 方便驗證，另開 `prometheus_exporter`
  暴露 `component_received_events_total` 計數器做客觀計量。

## 結論：成功送出的關鍵參數

| 設定（Fluentd `out_forward`）         | 必要性 | 原因 |
|---------------------------------------|--------|------|
| `heartbeat_type transport`（或 `none`）| **必要** | Vector 的 `fluent` source 只聽 **TCP**。`out_forward` 預設的 **UDP** heartbeat（`heartbeat_type udp`）Vector 不會回應，fluentd 的 phi-accrual 故障偵測器會把節點判為 dead 並 `detached`，送出歸零。 |
| **不要**設 `<security>` / `shared_key` | **必要** | Vector `fluent` source **不實作** forward 協定的 shared-key 握手（HELO/PING/PONG）。一旦設了 `<security>`，fluentd 會等待 server 發起握手，Vector 不會發，連線靜默卡住、0 筆送達。 |
| `transport tcp`                        | 建議   | 明確走 TCP（非 TLS）。與 Vector `fluent` source 的純 TCP 監聽相符。 |
| `require_ack_response true`            | 可選   | Vector `fluent` source **支援** ack，開啟可得到 at-least-once 的送達確認；不開也能送。 |
| `<server> host / port 24224`           | 必要   | 指向 Vector Service。port 需與 Vector source 的 `address` 相同。 |

Vector 端最小可用設定：

```yaml
sources:
  fluent_in:
    type: fluent
    address: 0.0.0.0:24224   # TCP only
sinks:
  stdout:
    type: console
    inputs: [fluent_in]
    encoding: { codec: json }
```

## 實測數據（驗證）

| 設定 | 送達 Vector 的事件數 |
|------|----------------------|
| ✅ 正確設定（`heartbeat_type transport`、無 security） | **1370+ 筆，計數器持續增加**（1340 → 1370 / 6 秒，符合 5/s） |
| ❌ `heartbeat_type udp` | **0**（fluentd `detached forwarding server ... phi=16.12 > phi_threshold=16`） |
| ❌ `<security> shared_key` | **0**（握手靜默卡住，兩端皆無 error log） |

Vector prometheus 計量印證了端到端：`fluent_in` source 收到的事件數
== `stdout` console sink 送出的事件數（無 drop）。

證據檔在 `results/`：
- `vector-received-sample.log` — Vector 實際收到的 JSON 事件
- `vector-metrics.txt` — Vector source/sink 計數器
- `fluentd-good.log` — 正確設定的 fluentd 啟動 log（無錯誤）
- `fluentd-bad-udp-detached.log` — UDP heartbeat 導致 server 被 detach 的 warn log

## 如何重現

前置：本 repo 的 `.claude/skills/k3s-experiment` 描述了此沙盒環境啟動
單節點 k3s 的步驟（含 runc oom_score_adj wrapper 與 `mirror.gcr.io`
鏡像繞過 Docker Hub 限流）。叢集起來後：

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/10-vector.yaml
kubectl -n logpipe rollout status deploy/vector
kubectl apply -f manifests/20-fluentd.yaml
kubectl -n logpipe rollout status deploy/fluentd

# 驗證：應看到 message=hello from fluentd 持續滾動
kubectl -n logpipe logs -f deploy/vector | grep '"svc":"demo"'

# 負向對照（會看到 0 筆送達 + detached 警告）
kubectl apply -f manifests/30-fluentd-negative.yaml
kubectl -n logpipe logs deploy/fluentd-bad | grep -i detached
```

## 檔案

```
manifests/
  00-namespace.yaml          logpipe namespace
  10-vector.yaml             Vector ConfigMap + Deployment + Service（接收端）
  20-fluentd.yaml            Fluentd ConfigMap + Deployment（✅ 正確參數）
  30-fluentd-negative.yaml   Fluentd（❌ 錯誤參數：udp heartbeat + shared_key）
results/                     擷取的驗證證據
```

## 備註：映像拉取

Docker Hub 對匿名拉取有 6 小時速率限制（本次實驗中 `timberio/vector`
觸發 HTTP 429）。解法是在 `/etc/rancher/k3s/registries.yaml` 設定
`docker.io` 走 Google 的 pull-through 鏡像 `mirror.gcr.io`，即可繞過限流。
