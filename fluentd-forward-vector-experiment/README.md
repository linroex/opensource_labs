# fluentd 1.18.0 `out_forward` → vector:vector 慢 / 掛掉時的行為驗證

原始碼:`../fluentd-1.18.0-src`(tag v1.18.0)。實測版本:fluentd 1.18.0、vector 0.43.1、Ruby 3.3.6。

## 檔案

| 檔案 | 用途 |
|---|---|
| `fluent.conf` | fluentd:`in_forward` → `out_forward`(`require_ack_response false`、`retry_max_times 5`、`drop_oldest_chunk`、file buffer、`total_limit_size 40m`) |
| `vector.toml` | vector:`fluent` source → 很慢的 `http` sink(buffer 1 筆,背壓 source) |
| `slow_sink.py` | 每個請求 sleep 10 秒的 HTTP server |
| `gen.rb` | 產生器,約 10MB/s 送 forward 協定資料到 fluentd |
| `mon.sh` | 輪詢 `monitor_agent`(port 24220)印 queue/retry |
| `dump.rb` | `fluentd -r` 預載;收到 SIGTTIN 時 dump 所有 Ruby 線程 backtrace |

`fluent.conf` 的 `./buf*/forward`、`send_timeout`、`heartbeat_type` 是跑不同實驗時改過的,重跑請自行調整。

## 結果

### 已驗證
1. **重試 5 次後整個 queue 被清空**:vector 斷線後約 30 秒(1+2+4+8+16 秒 backoff),日誌出現
   `Hit limit for retries. dropping all chunks in the buffer queue. retry_times=5 records=4200`,
   之後 `retry_times` 歸零重新開始(下一輪 30 秒後再清一次)。
2. **`drop_oldest_chunk`**:queue 到 40MB 後每次寫入都 `dropping oldest chunk`,兩分鐘內丟 516 個 chunk。
3. **vector 慢但連線存活時,不觸發任何重試**(`retry_count=0`,無 `failed to flush`)。

### 新發現
- `keepalive false`(預設)時每個 chunk 一條新連線;chunk 寫進 kernel socket buffer 就算成功並立刻 purge。
- `close()` 會卡 `send_timeout` 秒(`out_forward.rb:403` 把 `linger_timeout` 設成 `send_timeout`)。
- 卡住期間 fluentd 的 input 線程與 monitor 也停止處理(strace 確認):`send_timeout` 5 → 約每 5 秒 1 個 chunk;改 1 → 約每 1 秒 1 個 chunk。
- 預設 `send_timeout 60` 的影響是依此推算,**未實測**。

### 未解決 / 未測
- 沒重現「vector 慢 → queue 累積幾十 GB」:此環境 input 被上述停滯限速,queue 一直是 0。
- 停滯的根本原因不明(獨立 Ruby 程式測 `close()` + `SO_LINGER` 並不會凍住其他線程)。
- `monitor_agent` 的 `retry_count` 在清空 queue 後沒歸零,與日誌 `retry_times` 不一致,原因未查。
- 未測 `require_ack_response true`、`keepalive true`、`flush_thread_count > 1`。
