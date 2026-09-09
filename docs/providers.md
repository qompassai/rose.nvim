# Model providers

Rose defaults to the native **[qompassai/rose backend](https://github.com/qompassai/rose)**;
`providers.provider = "ollama"` selects compatibility mode. Both local backends
bypass this cloud registry. Old Ollama-only native configs auto-select Ollama;
see [selection precedence and TLS configuration](configuration.md#rose-default-backend).
No plugin, provider SDK, credential manager, key
prompt, network request, or environment-key check is run during provider
`require`, setup validation, or capability inspection.

## Privacy and explicit consent

**Cloud requests send your task, conversation, selected source context, tool
schemas, and tool output to the configured external endpoint.** Provider billing,
retention, region, and account policy apply. Tool output can contain sensitive
project information: review your workspace and permissions before enabling cloud
use. Both `providers.enabled = true` and `providers.allow_cloud = true` are
required. Selecting a provider or setting an API key alone is not consent.

Credentials are read lazily from the selected environment variable only when
you explicitly make a request. Do not put API keys in setup tables, project
configuration, prompts, tool output, URLs, or issue reports. Inline key fields
are rejected. Health and setup do not verify keys or incur API charges.

## What is implemented

The adapters implement **core JSON text/model APIs, custom function calling,
opaque conversation replay, usage/citation metadata, and an opt-in raw JSON/SSE
API**. They do not implement every feature of every provider or model.

| Provider / `api` | Native route, appended to explicit base | Rose custom tools | Replay preserved |
| --- | --- | --- | --- |
| OpenAI / `responses` | `/responses` | Yes, when the chosen model supports them | All output items, reasoning/encrypted items, function calls, message phase |
| OpenAI / `chat` | `/chat/completions` | Model-dependent compatibility mode | Complete assistant message, including provider extensions |
| Anthropic / `messages` | `/messages` | Yes, model-dependent | All content blocks, thinking signatures and redacted blocks in order |
| xAI / `responses` | `/responses` | Yes, model-dependent | All Responses output items |
| xAI / `chat` | `/chat/completions` | Yes, model-dependent | Complete assistant message including `reasoning_content` |
| NVIDIA NIM / `chat` | `/chat/completions` | Only tool-capable model/deployment | Complete assistant message including reasoning extensions |
| Perplexity / `agent` | `/agent` | Yes, with a tool-capable selected model | All Responses-style output items and call IDs |
| Perplexity / `sonar` | `/sonar` | **No Rose custom tools** | Chat/search response, citations and search results |

OpenAI recommends Responses for reasoning/tool workflows and requires returned
reasoning items to accompany function results; support differs by model, so the
compatibility route is not a substitute for every modern model.
([OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling),
[OpenAI Responses reference](https://developers.openai.com/api/reference/resources/responses/methods/create))

Anthropic tool use uses `tool_use` assistant blocks and user `tool_result`
blocks; thinking/signatures and redacted thinking must be replayed without
modification.
([Anthropic tool definitions](https://platform.claude.com/docs/en/agents-and-tools/tool-use/implement-tool-use),
[Messages reference](https://platform.claude.com/docs/en/api/messages))

xAI exposes an OpenAI-compatible chat route as well as Responses function
calling; its multi-turn documentation requires preserving `reasoning_content`
for reasoning models.
([xAI function calling](https://docs.x.ai/docs/guides/function-calling),
[xAI multi-turn preservation](https://docs.x.ai/developers/advanced-api-usage/prompt-caching/multi-turn))

NIM exposes a chat-completions API, with tool support depending on the model and
deployment; some documented NIM versions require `tools` and `tool_choice`
together. Rose adds `tool_choice = "auto"` when NIM tools are sent without an
explicit choice.
([NVIDIA hosted LLM API](https://docs.api.nvidia.com/nim/reference/llm-apis),
[NIM function calling](https://docs.nvidia.com/nim/large-language-models/1.10.0/function-calling.html))

**Perplexity Agent and Sonar are different API surfaces.** The current Agent
documentation specifies `POST https://api.perplexity.ai/v1/agent` (with
`/v1/responses` as an OpenAI SDK alias) and documents custom function-call/result
loops; Sonar's current quickstart specifies
`https://api.perplexity.ai/v1/sonar` for web-grounded chat. Rose does not infer
generic custom-tool support from Sonar's OpenAI-compatible response shape.
([Agent quickstart](https://docs.perplexity.ai/docs/agent-api/quickstart),
[Function-calling cookbook](https://docs.perplexity.ai/docs/cookbook/articles/function-calling-e2e/README),
[Sonar quickstart](https://docs.perplexity.ai/docs/sonar/quickstart))

Documentation checked **2026-09-08**. No model IDs are guessed or frozen here;
choose a model from your provider account and confirm its tool and option
support. Fake local fixtures verify wire formats, not availability of paid
models or every vendor extension.

### Capability boundaries

| Feature | Normalized `chat` | Raw `request` |
| --- | --- | --- |
| Text turns and function-call/result loops | Implemented | Native JSON retained; caller orchestrates |
| Model-specific reasoning/temperature/output-token/tool-choice options | Explicit `options`, sent unchanged | Native body unchanged |
| Usage, finish reasons, citations | Normalized plus original metadata | Original JSON |
| Thinking/reasoning continuity | Opaque replay; **not public text** | Raw blocks/events; caller must protect them |
| Structured outputs | Native option pass-through; response remains text | Native JSON; caller validates the schema |
| Provider-hosted search/tools, batches, polling, token counting | Not a general orchestration interface | Same-origin JSON endpoints, when supported by provider |
| SSE | Not aggregated into a chat message | Incremental raw events, opt-in callback |
| Image/document inputs encoded as JSON | Not accepted by text-message interface | Pass-through only; no file upload, rendering, or validation |
| Multipart uploads | Only the speech module (`rose.speech`: OpenAI/xAI STT); see [speech](speech.md) | **Not implemented** |
| Audio/video/binary output, realtime/WebSocket | **Not implemented** (speech TTS downloads bounded audio files separately) | **Not implemented** |

Custom `computer_call`, free-form `custom_tool_call`, shell/patch call types,
and approval requests are not mapped to Rose's function executor. Use a separate
explicit raw-API caller where appropriate; the normalized agent rejects those
call types. Raw API access does not grant a model new local tools or permissions.

## Configuration

Use Neovim 0.10+ and `curl`. Native Rose/Ollama use their separate local HTTP transport;
cloud traffic uses a separate bounded authenticated transport.

```lua
require("rose").setup({
  -- Other native workspace/trust/check configuration stays unchanged.
  providers = {
    enabled = true,
    allow_cloud = true, -- explicit consent: task/source/tool output leave device
    provider = "openai",
    openai = {
      api = "responses",
      endpoint = "https://api.openai.com/v1", -- API base, not the full route
      model = "<your-selected-tool-capable-model>",
      key_env = "OPENAI_API_KEY", -- name only; never the value
      capabilities = { tools = true }, -- explicitly affirm this model supports tools
      options = {
        parallel_tool_calls = false,
        -- reasoning = { effort = "<supported-effort>" },
        -- max_output_tokens = <appropriate-number>,
      },
    },
  },
})
```

Select one provider by `providers.provider`; put its settings under the matching
name. All endpoints below are **base URLs**. `api`, `endpoint`, and `model` are
required; there are no automatic provider/model fallbacks.

| Provider | Allowed `api` | Official base | Default `key_env` |
| --- | --- | --- | --- |
| `openai` | `responses`, `chat` | `https://api.openai.com/v1` | `OPENAI_API_KEY` |
| `anthropic` | `messages` | `https://api.anthropic.com/v1` | `ANTHROPIC_API_KEY` |
| `xai` | `responses`, `chat` | `https://api.x.ai/v1` | `XAI_API_KEY` |
| `nvidia` | `chat` | `https://integrate.api.nvidia.com/v1` | `NVIDIA_API_KEY` |
| `perplexity` | `agent`, `sonar` | `https://api.perplexity.ai/v1` | `PERPLEXITY_API_KEY` |

Example replacement settings (place inside `providers`, then select the
corresponding `provider`):

```lua
anthropic = {
  api = "messages",
  endpoint = "https://api.anthropic.com/v1",
  model = "<your-selected-model>",
  capabilities = { tools = true },
  options = {
    max_tokens = 4096, -- mandatory, explicit, positive integer
    -- thinking = { type = "enabled", budget_tokens = 1024 },
    -- Use only the thinking mode/budget supported by your selected model.
  },
  -- headers = { ["anthropic-beta"] = "<documented-feature-beta>" },
},
xai = {
  api = "responses", -- or "chat"
  endpoint = "https://api.x.ai/v1",
  model = "<your-selected-model>",
  capabilities = { tools = true },
  options = { parallel_tool_calls = false },
},
nvidia = {
  api = "chat",
  endpoint = "https://integrate.api.nvidia.com/v1",
  model = "<your-selected-NIM-model>",
  capabilities = { tools = true },
  options = { tool_choice = "auto" },
},
perplexity = {
  api = "agent", -- use "sonar" only for search/chat without Rose custom tools
  endpoint = "https://api.perplexity.ai/v1",
  model = "<your-selected-model>",
  capabilities = { tools = true },
  options = {},
},
```

For Sonar, use `api = "sonar"` and `capabilities = { tools = false }`; pass
documented search options in `options`, not generic `tools`. Rose's agent
requires custom tools and therefore cannot run with Sonar.

Options are **endpoint-native top-level JSON fields**, not Ollama's nested
`options`. Rose does not silently discard unfamiliar option fields; the server
validates them. Reserved fields `model`, `messages`, `input`, `tools`, and
`stream` cannot override the normalized chat structure. Native `n > 1` is not
supported by normalized chat. Use raw requests for those shapes. Unsupported
normalized message/config fields fail explicitly.

For example, OpenAI/xAI document `parallel_tool_calls = false`, whereas
Anthropic documents a native `tool_choice` object such as `{ type = "auto" }.
([OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling),
[xAI function calling](https://docs.x.ai/docs/guides/function-calling),
[Anthropic tool definitions](https://platform.claude.com/docs/en/agents-and-tools/tool-use/implement-tool-use))
Rose does not translate model-specific option names between APIs. Do not copy
an options table between providers without checking that API and selected model.

Two documented OpenAI Responses defaults are intentional: Rose sets `store =
false` unless explicitly configured otherwise, and adds
`reasoning.encrypted_content` to `include` when `store = false`, enabling
stateless reasoning replay. It sets omitted OpenAI function-schema `strict` to
`false` to preserve Rose's genuinely optional parameters; an explicit schema
`strict` value is retained. Other providers' schema/storage defaults are not
guessed. These settings are not a universal zero-retention guarantee.
([OpenAI Responses reference](https://developers.openai.com/api/reference/resources/responses/methods/create),
[OpenAI strict-mode behavior](https://developers.openai.com/api/docs/guides/function-calling))

Allowed optional request headers are `anthropic-version`, `anthropic-beta`,
`anthropic-workspace-id`, `openai-organization`, `openai-project`, and
`x-grok-conv-id`, each on its corresponding provider. Authentication,
Host/routing, cookies, and proxy headers cannot be overridden. Anthropic uses
`x-api-key` and defaults its version header to `2023-06-01`; its API also
documents workspace headers for multi-workspace keys.
([Anthropic API overview](https://platform.claude.com/docs/en/api/overview))

### Self-hosted NIM and explicit endpoint trust

```lua
providers = {
  enabled = true,
  allow_cloud = true, -- the uniform provider opt-in gate is intentionally conservative
  provider = "nvidia",
  nvidia = {
    api = "chat",
    endpoint = "http://127.0.0.1:8000/v1",
    credential_host = "127.0.0.1:8000", -- exact host[:port], no scheme/path
    allow_insecure_local = true,
    auth = false, -- allowed ONLY for loopback NVIDIA NIM; otherwise key required
    model = "<your-deployed-model>",
    capabilities = { tools = true },
    options = { tool_choice = "auto" },
  },
}
```

Custom HTTPS/self-hosted endpoints require `credential_host` to exactly match
the endpoint's lowercase `host[:port]`. This explicitly authorizes sending the
selected provider key to that authority; use a separate `key_env` for a gateway
or deployment. Host suffix matches are not allowed. HTTP is rejected except
for explicitly enabled `127.0.0.1`, `localhost` (pinned to `127.0.0.1`), or
`[::1]`. Non-loopback self-hosted NIM requires HTTPS and authentication. There is
no insecure-TLS switch, remote plain-HTTP override, automatic discovery, or
credential forwarding to redirect targets.

### Transport limits and protections

Per-provider defaults:

```lua
timeout = 120000,                 -- milliseconds; 1..3600000
max_request_bytes = 4 * 1024 * 1024,
max_response_bytes = 8 * 1024 * 1024, -- includes HTTP headers, enforced while reading
max_event_bytes = 1024 * 1024,     -- individual SSE event limit
```

Request/response limits are configurable from 256 bytes to 64 MiB; SSE events
from 128 bytes to the response limit. Curl starts with `--disable` before any
other option. Credentials, URL and encoded JSON body are supplied through a
quoted stdin curl configuration, never command-line arguments or temporary
request files. The child receives a minimal environment, not provider keys or
proxy variables. Redirects, proxy use, curlrc settings and retries are disabled;
TLS verification remains enabled. `localhost` is explicitly pinned to loopback.

Request output is byte/time bounded while it arrives. Cancellation kills the
child and completes the callback once. Errors expose bounded generic diagnostics
and HTTP status, not provider response bodies, key values, source text, stderr,
or complete URLs. This intentionally trades some remote error detail for safety.
If a model does not support an option, check the official schema rather than
logging credentials or full private requests.

## Lua API and conversation contract

```lua
local model = require("rose.native.model")

model.validate(fullconfig)          -- true OR nil,error; no key/environment check
model.describe(fullconfig)          -- { provider, model, cloud }
model.capabilities(fullconfig)      -- feature flags; no key/environment check
local token = model.chat(fullconfig, messages, schemas, function(err, message)
  if err then return end
  -- Only message.content belongs in a plain text UI.
end)
token.cancel()
model.stop()                       -- stop active provider requests
```

`chat` returns a normalized assistant message with:

- `role = "assistant"` and public `content`;
- `tool_calls = { { id, type = "function", ["function"] = { name, arguments } } }`;
- `usage.input_tokens`, `output_tokens`, `total_tokens`, and `usage.raw`;
- `citations`, retaining URLs/annotations without synthesizing citation claims;
- `finish_reason`, mapping ordinary stop, tool use and output limits while
  retaining unrecognized native reason values;
- **`_provider.response`**, the complete native JSON response, plus the provider,
  endpoint, model and API identity required for replay.

Append the **entire** assistant message to history, then append one
`{ role = "tool", tool_call_id = call.id, content = "<result string>" }` per call.
Never regenerate IDs, strip `_provider`, rearrange opaque blocks, or reuse the
history with another endpoint/API/model. Missing/duplicate call IDs and
unmatched/missing results fail before a subsequent request. Anthropic combines
parallel tool results into user `tool_result` blocks; Responses creates
`function_call_output` items; chat compatibility uses tool-role messages.

Only public text is extracted. Separate reasoning fields and thinking blocks
never enter `message.content`; common `<think>`/`<thinking>` tagged sections are
also withheld, including unclosed sections. Opaque metadata can still contain
private reasoning and source: **do not display, log, or serialize `_provider`
into a user-visible report**. No heuristic can identify every possible
unstructured reasoning format emitted by a custom server.

### Generic authenticated JSON and SSE

```lua
local model = require("rose.native.model")
local token = model.request(fullconfig, {
  path = "/responses", -- appended to configured base, never an arbitrary URL
  method = "POST",     -- GET/POST/PUT/PATCH/DELETE
  body = {
    model = "<selected-model>",
    input = "A short request",
    -- Any documented JSON-native endpoint feature belongs here.
  },
}, function(err, response)
  -- Native decoded JSON. Not normalized, rendered, or executed as local tools.
end)
```

`require("rose").model_request(spec, callback)` is the native convenience entry
point when Rose is set up. The same provider consent, authority binding, lazy
authentication and transport limits apply. Body fields are not merged with
configured `options` or `model`: the raw caller supplies the complete native
request. Query strings on safe relative paths are supported. Raw calls are
programmatic only and are not a generic model-invokable tool.

```lua
local token = model.request(fullconfig, {
  path = "/responses",
  stream = true, -- raw transport mode
  body = {
    model = "<selected-model>",
    input = "A short request",
    stream = true, -- actual native API field; both flags are required
  },
  on_event = function(event)
    -- { event = "<SSE event name>", id = optional, data = decoded_JSON }
    -- A [DONE] frame becomes { event = "message", done = true }.
    -- These are RAW events, potentially including private reasoning.
    -- Select only documented public-text delta types for your own UI.
  end,
}, function(err, summary)
  -- On successful HTTP/SSE framing: { stream = true, events = <count> }.
  -- This is NOT an assembled assistant response or an automatic tool loop.
end)
```

SSE supports fragmented chunks, multi-line `data`, comments, named events,
`[DONE]`, and bounded error handling. Events are not automatically retried or
reconnected. A successful raw framing summary is not proof of model-level
completion: inspect the provider's terminal event. JSON error events and
malformed/truncated frames fail without exposing remote error details.

## Offline verification

```sh
nvim --headless -u NONE -l tests/providers.lua
# Optional: ROSE_TEST_PYTHON=/path/to/python3
```

The test runner launches `tests/providers_fixture.py` on an ephemeral loopback
port, uses only fake tokens, and makes no live paid calls. It exercises each
provider's real HTTP wire format, assistant → tool-result → next-assistant
replay, opaque reasoning/signatures, citations, explicit capability rejection,
raw native JSON, split SSE frames, redacted errors, authority/HTTPS validation,
response/request/time limits, cancellation, and absence of key/source values
from process arguments and inherited environment.
