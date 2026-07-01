# Codex CLI 發送 LLM API request 時實際長怎樣的 curl

分析對象：`openai/codex` main 分支（snapshot commit `db887d03e1f907467e33271572dffb73bceecd6b`，對應最新 release `rust-v0.142.5` 附近），核心邏輯在 `codex-rs/core/src/client.rs` 與 `codex-rs/codex-api/`。

## 結論先講：只剩 Responses API，沒有 Chat Completions

翻到 `codex-rs/model-provider-info/src/lib.rs` 會看到 `wire_api = "chat"` 已經被明確擋掉：

```rust
const CHAT_WIRE_API_REMOVED_ERROR: &str =
    "`wire_api = \"chat\"` is no longer supported.\nHow to fix: set `wire_api = \"responses\"` in your provider config.\nMore info: https://github.com/openai/codex/discussions/7782";
```

所以現在 Codex CLI（不管是內建 OpenAI provider、Azure、Bedrock 還是自架的 Ollama/LM Studio provider）打的都是 **OpenAI Responses API**（`POST /responses`），不是舊版 `/chat/completions`。早期 TypeScript 版 codex-cli 用過 chat completions 格式，但目前 Rust 版已經全面走 Responses。

傳輸層還多了一條路：**Responses-over-WebSocket**（`OpenAI-Beta: responses_websockets=2026-02-06`），會話開始時嘗試建 WS 連線做 prewarm，失敗才 fallback 回一般 HTTP streaming POST。以下 curl 還原的是最常見、也是唯一能用 curl 模擬的路徑：HTTP POST + SSE streaming。

## Base URL 怎麼決定的

`codex-rs/model-provider-info/src/lib.rs` 的 `to_api_provider()`：

```rust
let default_base_url = if matches!(
    auth_mode,
    Some(AuthMode::Chatgpt | AuthMode::ChatgptAuthTokens | AuthMode::AgentIdentity | AuthMode::PersonalAccessToken)
) {
    CHATGPT_CODEX_BASE_URL   // "https://chatgpt.com/backend-api/codex"
} else {
    "https://api.openai.com/v1"
};
```

也就是說：

- 用 `codex login`（ChatGPT 帳號登入，一般使用者預設路徑）→ 打 `https://chatgpt.com/backend-api/codex/responses`
- 用 `OPENAI_API_KEY` 環境變數 → 打 `https://api.openai.com/v1/responses`

`path` 固定是 `"responses"`（`codex-rs/core/src/client.rs: RESPONSES_ENDPOINT = "/responses"`），由 `Provider::url_for_path` 跟 base_url 拼起來。

## Headers 從哪裡來

彙整 `client.rs`（`build_responses_headers` / `build_responses_compatibility_headers` / `add_originator_header`）、`codex-api/src/requests/headers.rs`（`build_session_headers`）、`codex-login/src/auth/default_client.rs`（`default_headers`、`get_codex_user_agent`）、`codex-api/src/auth.rs` + `model-provider/src/bearer_auth_provider.rs`（`Authorization`）、`codex-client/src/request.rs`（`Content-Type` / `Content-Encoding`）：

| Header | 來源 / 內容 |
|---|---|
| `Authorization` | `Bearer <access_token 或 OPENAI_API_KEY>`（`BearerAuthProvider::add_auth_headers`） |
| `ChatGPT-Account-ID` | 只有 ChatGPT 登入模式才有，帶 workspace/account id |
| `Content-Type` | `application/json`（body 沒設定時由 transport 自動補） |
| `Accept` | `text/event-stream`（因為 `stream: true`，走 SSE） |
| `originator` | 預設 `codex_cli_rs`（可被 `CODEX_INTERNAL_ORIGINATOR_OVERRIDE` 覆寫） |
| `User-Agent` | `codex_cli_rs/<CARGO_PKG_VERSION> (<OS> <version>; <arch>) <terminal 資訊，例如 iTerm.app 3.5>` |
| `session-id`, `thread-id` | 這次 Codex session / conversation 的 UUID |
| `x-codex-installation-id` | 本機安裝識別碼 |
| `x-codex-turn-state` | 同一個 turn 內做 sticky routing 用的 token（第一個 request 沒有，之後從 response header 拿到再回帶） |
| `x-codex-beta-features` | 有開 beta feature 才會帶，逗號分隔的 feature key |
| `x-codex-window-id` | TUI 視窗識別碼 |
| `x-openai-subagent` | 只有 sub-agent（review/compact/memory_consolidation）呼叫時才有 |
| `OpenAI-Organization` / `OpenAI-Project` | 只有走 `OPENAI_API_KEY`（`api.openai.com`）模式，且對應環境變數有設才會帶 |
| `version` | 內建 OpenAI provider 固定帶自己的 CLI 版本號 |
| `Content-Encoding: zstd` | 選配：只有 ChatGPT-backend + OpenAI provider + 開啟 request compression 時才會壓縮 body |

WebSocket 專屬的 `OpenAI-Beta: responses_websockets=2026-02-06` 在純 HTTP streaming 這條路徑不會出現，只在建 WS 連線時才加。

## Request body（`ResponsesApiRequest`）

`codex-rs/codex-api/src/common.rs`：

```rust
pub struct ResponsesApiRequest {
    pub model: String,
    pub instructions: String,          // system/base instructions
    pub input: Vec<ResponseItem>,      // 對話歷史 + 這次的 user/tool 輸入
    pub tools: Option<Vec<Value>>,     // function/shell 等工具的 JSON schema
    pub tool_choice: String,           // 固定 "auto"
    pub parallel_tool_calls: bool,
    pub reasoning: Option<Reasoning>,  // effort/summary，reasoning 模型才有
    pub store: bool,                   // 一般是 false，只有 Azure Responses 端點是 true
    pub stream: bool,                  // 一律 true
    pub include: Vec<String>,          // 有 reasoning 就會塞 "reasoning.encrypted_content"
    pub service_tier: Option<String>,
    pub prompt_cache_key: Option<String>, // = thread id，讓 prompt caching 命中
    pub text: Option<TextControls>,    // verbosity / output schema
    pub client_metadata: Option<HashMap<String, String>>,
}
```

`input` 裡每個 `ResponseItem`／`ContentItem` 都是 `#[serde(tag = "type", rename_all = "snake_case")]`，所以序列化出來會長這樣：

```json
{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "..."}]}
```

`tools` 的每個項目（`ResponsesApiTool` 序列化結果）長這樣：

```json
{
  "type": "function",
  "name": "shell",
  "description": "Runs a shell command",
  "strict": false,
  "parameters": {"type": "object", "properties": {"command": {"type": "string"}}}
}
```

## 還原成 curl

以「用 `OPENAI_API_KEY` 直接打 api.openai.com、單輪對話、開一個 shell 工具、gpt-5.1 之類的 reasoning 模型」為例：

```bash
curl -sS https://api.openai.com/v1/responses \
  -X POST \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -H "originator: codex_cli_rs" \
  -H "User-Agent: codex_cli_rs/0.142.5 (Mac OS 14.5; arm64) iTerm.app 3.5" \
  -H "session-id: 7c9b8f2e-0000-4c00-8000-000000000001" \
  -H "thread-id: 7c9b8f2e-0000-4c00-8000-000000000002" \
  -H "x-codex-installation-id: 9c1a2b3c-...-installation" \
  -d '{
    "model": "gpt-5.1-codex",
    "instructions": "You are Codex, based on GPT-5.1. You are running as a coding agent in the Codex CLI...",
    "input": [
      {
        "type": "message",
        "role": "user",
        "content": [{"type": "input_text", "text": "幫我把 foo.py 裡的 bug 修好"}]
      }
    ],
    "tools": [
      {
        "type": "function",
        "name": "shell",
        "description": "Runs a shell command and returns its output",
        "strict": false,
        "parameters": {
          "type": "object",
          "properties": {
            "command": {"type": "array", "items": {"type": "string"}}
          },
          "required": ["command"]
        }
      }
    ],
    "tool_choice": "auto",
    "parallel_tool_calls": true,
    "reasoning": {"effort": "medium", "summary": "auto"},
    "store": false,
    "stream": true,
    "include": ["reasoning.encrypted_content"],
    "prompt_cache_key": "7c9b8f2e-0000-4c00-8000-000000000002",
    "client_metadata": {
      "x-codex-installation-id": "9c1a2b3c-...-installation",
      "session_id": "7c9b8f2e-0000-4c00-8000-000000000001",
      "thread_id": "7c9b8f2e-0000-4c00-8000-000000000002"
    }
  }'
```

若是一般使用者常見的「用 `codex login` 登入 ChatGPT 帳號」路徑，差異只在：

```bash
curl -sS https://chatgpt.com/backend-api/codex/responses \
  -X POST \
  -H "Authorization: Bearer $CHATGPT_ACCESS_TOKEN" \
  -H "ChatGPT-Account-ID: $CHATGPT_ACCOUNT_ID" \
  ... (其餘 header/body 相同)
```

第二次以後的 request 若還在同一個 turn 內，會多帶一個從上一個 response header 學來的 `x-codex-turn-state: <token>`，讓後端做 sticky routing。

## 檔案索引（想深入看原始碼可以直接開這幾支）

- `codex-rs/core/src/client.rs`：`ModelClient` / `ModelClientSession`，組 request、決定 HTTP 還是 WebSocket、retry/auth-refresh 邏輯全在這
- `codex-rs/codex-api/src/common.rs`：`ResponsesApiRequest` / `TextControls` 等 body 型別
- `codex-rs/codex-api/src/endpoint/responses.rs`：實際送出 POST + SSE 的 `ResponsesClient`
- `codex-rs/codex-api/src/endpoint/session.rs`：`EndpointSession`，組出最終 `Request`（method/url/headers/body）並套用 auth
- `codex-rs/codex-api/src/provider.rs`：`Provider::url_for_path` / `build_request`
- `codex-rs/model-provider-info/src/lib.rs`：各 provider 的 base_url、env_key、`to_api_provider()`
- `codex-rs/model-provider/src/bearer_auth_provider.rs`：`Authorization: Bearer ...` 怎麼加上去
- `codex-rs/login/src/auth/default_client.rs`：`User-Agent` / `originator` 怎麼組
- `codex-rs/protocol/src/models.rs`：`ResponseItem` / `ContentItem` 的 serde tag，決定 `input` 陣列的 JSON 長相
- `codex-rs/tools/src/tool_spec.rs`：`tools` 陣列怎麼序列化
