# Native configuration reference

This reference covers `require("rose").setup(opts)` in native mode, including
options consumed outside `config.defaults`; the editor declarations are in
[`lua/rose/types.lua`](../lua/rose/types.lua), and the core merge/validation is in
[`lua/rose/config.lua`](../lua/rose/config.lua).

```lua
---@type Rose.Config
local opts = {
  workspace = vim.fn.getcwd(),
  ollama = { model = "qwen2.5-coder:7b" },
  agent = { max_repair_rounds = 1 },
}
local rose, err = require("rose").setup(opts)
if not rose then
  vim.notify(tostring(err), vim.log.levels.ERROR)
end
```

`Rose.Config` is **partial input**: sections and their defaulted nested fields
may be omitted; an explicitly configured command still needs its required argv.
`Rose.Config.Defaults` describes the setup default table, and
`Rose.Config.Resolved` adds a canonical workspace and derived `agent.max_cycles`.
Adapter-only defaults are **not** promised as materialized fields on the resolved
configuration. See the [type declarations](../lua/rose/types.lua).

For editor completion outside the plugin repository, include the plugin's `lua`
directory in LuaLS `settings.Lua.workspace.library`, preserving your existing
library entries. Once the plugin is on runtimepath,
`vim.api.nvim_get_runtime_file("lua/rose/types.lua", false)[1]` locates the file;
check for nil, then take its parent twice to get that `lua` directory.
Do **not** `require("rose.types")`: it is annotation-only metadata, not a runtime
module. The public setup parameter is annotated in
[`lua/rose/init.lua`](../lua/rose/init.lua).

Types describe supported inputs; they do not introduce new runtime validation.
Some checks occur only when an adapter is used, and some legacy consumer
coercions remain in place. In particular, setup success does not prove that
every optional executable, endpoint, model or debug configuration is usable.
See [core resolution](../lua/rose/config.lua) and
[optional-module setup](../lua/rose/init.lua).

`config.resolve(opts)` and `config.setup(opts)` return resolved configuration
or raise on invalid input; `rose.setup(opts)` returns the Rose module on success,
or `nil, error` for caught configuration/provider failures. It is not the resolved
configuration table: read `rose.options` after success. Errors propagated by
`pcall` can be non-string Lua values, so use `tostring(err)` for display.
See the [configuration module](../lua/rose/config.lua) and
[public entrypoint](../lua/rose/init.lua).

## How to read the tables

- **Setup default** is stored in `config.defaults` (or, for `workspace` and
  `agent.max_cycles`, computed by resolution).
- **Adapter default** is applied only when an integration consumes the option;
  `absent` in Setup means the field remains absent unless supplied.
- Numeric limits below are inclusive; timeouts are **milliseconds** unless
  explicitly marked seconds. `integer` excludes fractional values in the public
  contract, even where an older consumer coerces/floors numbers.
- Paths, executable names, model IDs, voices, filetypes and environment variable
  names are open strings, not invented closed enumerations.
- Argv is a nonempty `string[]`, with the executable first; Rose does not perform
  shell interpolation. Dictionaries are string-keyed records, not arrays.

The distinction between setup and operational defaults follows
[`config.lua`](../lua/rose/config.lua) and the linked consumers in each section.

## Top-level options and trust

| Option | Type | Setup default | Purpose, range and operational behavior |
| --- | --- | --- | --- |
| `legacy` | `boolean` | `false` | `true` switches to the separate historical implementation; not a native compatibility merge. |
| `workspace` | `string` | current working directory, resolved | Existing directory, resolved through realpath to an absolute path without a trailing slash except `/`. |
| `trusted` | `boolean` | `false` | Allow configured workspace writes/checks/lint/debug and trusted Flow work. Not an OS sandbox and not cloud consent. |
| `max_file_bytes` | `integer` | absent | File-tool read/write/snapshot byte budget; adapter default `1048576` (1 MiB), capped at `16777216` (16 MiB). Use positive integers; current consumer does not validate a lower bound. |
| `check_timeout` | `integer` | absent | Aggregate `editor_check` deadline; adapter default `120000`, range `1..120000` ms. This is not a single deadline for the entire agent workflow. |
| `ollama` | `Rose.Config.Ollama` | table below | Local model adapter. |
| `providers` | `Rose.Config.Providers` | table below | Explicit cloud chat/speech consent and endpoint configuration. |
| `speech` | `Rose.Config.Speech` | table below | Explicit dictation/read-aloud configuration. |
| `hub` | `Rose.Config.Hub` | table below | Explicit Hugging Face operations. |
| `agent` | `Rose.Config.Agent` | table below | Bounded native agent loop. |
| `diver` | `Rose.Config.Diver` | `{ lsp = {} }` | Optional explicitly selected native tooling. |
| `debug` | `Rose.Config.Debug` | `{}` | Named stdio DAP launch probes. |
| `checks` | `table<string, Rose.Config.Check>` | `{}` | At most 256 explicitly named check definitions. |
| `scip` | `Rose.Config.SCIP` | `{ path = "index.scip.json" }` | Existing decoded SCIP JSON; no index generation. |
| `flow` | `Rose.Config.Flow` | table below | Explicit external Flow process and editor bridge. |
| `mcp` | `Rose.Config.MCP` | `{ servers = {} }` | Explicit external stdio servers. |
| `webui` | `Rose.Config.WebUI` | table below | Explicit loopback web UI. |

The core resolver, file budget and aggregate check deadline are implemented in
[`config.lua`](../lua/rose/config.lua),
[`tooling/workspace.lua`](../lua/rose/tooling/workspace.lua) and
[`tooling/checks.lua`](../lua/rose/tooling/checks.lua).

**Opt-in boundaries are independent:** `trusted=true` is not permission for
cloud providers; cloud chat requires both provider flags, cloud speech requires
both flags plus speech enablement, and third-party MCP calls require each
server's own trust/read-only/tool allowlist. Hub uploads additionally require
explicit approval of the complete manifest. Setup itself does not start a
model request, microphone, Flow/MCP process, transfer or web listener.
See [model routing](../lua/rose/native/model.lua),
[speech consent](../lua/rose/speech/http.lua),
[MCP calls](../lua/rose/native/servers.lua),
[Hub approval](../lua/rose/hub.lua) and [setup](../lua/rose/init.lua).

## Ollama

| Option | Type | Setup default | Purpose / allowed values |
| --- | --- | --- | --- |
| `ollama.base_url` | `string` | `"http://127.0.0.1:11434"` | HTTP(S) base URL; Rose appends `/api/chat`. No userinfo; non-loopback requires `allow_remote`. |
| `ollama.model` | `string` | `"qwen2.5-coder:7b"` | Nonempty installed model ID; Rose does not install it. |
| `ollama.timeout` | `integer` | `120000` | Request deadline, `1..3600000` ms. |
| `ollama.allow_remote` | `boolean` | `false` | Explicitly permit a non-loopback endpoint; independent of `providers.allow_cloud`. |
| `ollama.transport` | `"auto" \| "curl" \| "native"` | `"auto"` | `auto` currently uses the bounded safe curl adapter; `curl` selects it explicitly. `native` opts into `vim.net.request` when available. |
| `ollama.options` | `Rose.OllamaOptions` | absent | String-keyed Ollama JSON options passed unchanged as request `options`. No sampling defaults are set by Rose. |

The typed Ollama pass-through fields include `temperature:number`, `top_p:number`,
`top_k:integer`, `num_ctx:integer` (tokens), `num_predict:integer` (tokens or
Ollama-defined negative sentinels), `seed:integer`, and `stop:string[]`; additional
JSON-valued options remain valid. Values/ranges belong to the selected server
and model. See the [Ollama request adapter](../lua/rose/native/ollama.lua).

`native` is **not** equivalent to the safe curl policy: the current native HTTP
API cannot enforce all redirect/curlrc restrictions, while `auto` stays with the
safe adapter. The HTTP adapter currently still requires `vim.system` and an
installed `curl`, including before native selection; its 8 MiB response cap is
not an `ollama.max_response` setup option. See
[`native/http.lua`](../lua/rose/native/http.lua).

## Cloud providers

| Option | Type | Setup default | Purpose / opt-in |
| --- | --- | --- | --- |
| `providers.enabled` | `boolean` | `false` | Cloud adapter gate; must be exactly `true` for cloud calls. |
| `providers.allow_cloud` | `boolean` | `false` | Explicit consent for task/source/tool output and, when enabled, speech audio/text to leave the device. |
| `providers.provider` | `"ollama" \| "openai" \| "anthropic" \| "xai" \| "nvidia" \| "perplexity"` | `"ollama"` | Chat provider selection; not an arbitrary extension registry. |
| `providers.openai` | `Rose.Config.OpenAI` | absent | OpenAI configuration. |
| `providers.anthropic` | `Rose.Config.Anthropic` | absent | Anthropic configuration. |
| `providers.xai` | `Rose.Config.XAI` | absent | xAI configuration. |
| `providers.nvidia` | `Rose.Config.NVIDIA` | absent | NVIDIA hosted API or explicit local NIM. |
| `providers.perplexity` | `Rose.Config.Perplexity` | absent | Perplexity Agent or Sonar API. |

The [provider resolver](../lua/rose/providers/init.lua) requires explicit
`api`, `endpoint` and `model` for the **selected cloud chat provider**; partial
tables remain useful for inactive providers and speech-only endpoint overrides.

### Supported API choices and credential defaults

No cloud chat `api`, `model` or `endpoint` has a setup default; the base URLs
below are configuration examples, not silently selected chat endpoints.
The hosts and key environment names are adapter defaults from the
[registry](../lua/rose/providers/init.lua) and provider descriptors.

| Provider | `api` literal choices | Example base URL | Default `key_env` | Default credential authority |
| --- | --- | --- | --- | --- |
| OpenAI | `"responses"`, `"chat"` | `https://api.openai.com/v1` | `OPENAI_API_KEY` | `api.openai.com` |
| Anthropic | `"messages"` | `https://api.anthropic.com/v1` | `ANTHROPIC_API_KEY` | `api.anthropic.com` |
| xAI | `"responses"`, `"chat"` | `https://api.x.ai/v1` | `XAI_API_KEY` | `api.x.ai` |
| NVIDIA | `"chat"` | `https://integrate.api.nvidia.com/v1` | `NVIDIA_API_KEY` | `integrate.api.nvidia.com` |
| Perplexity | `"agent"`, `"sonar"` | `https://api.perplexity.ai/v1` | `PERPLEXITY_API_KEY` | `api.perplexity.ai` |

API paths are `/responses` or `/chat/completions`, Anthropic `/messages`, and
Perplexity `/agent` or `/sonar`; Sonar is a search/chat API and cannot provide
Rose's custom tools. See the [OpenAI](../lua/rose/providers/openai.lua),
[xAI](../lua/rose/providers/xai.lua), [NVIDIA](../lua/rose/providers/nvidia.lua),
[Perplexity](../lua/rose/providers/perplexity.lua) descriptors and
[Anthropic registry entry](../lua/rose/providers/init.lua).

### Fields of `providers.<name>`

All these fields are absent from setup defaults; their operational defaults
and validation come from the [provider resolver](../lua/rose/providers/init.lua).

| Field | Type | Adapter default | Purpose / range / restrictions |
| --- | --- | --- | --- |
| `api` | provider-specific literal above | none | Required for selected cloud chat. |
| `endpoint` | `string` | none for chat | HTTPS base URL; custom authority requires explicit credential binding. Speech defaults are listed separately. |
| `model` | `string` | none | Nonblank chat model ID without control characters; choose one available to your account/deployment. |
| `key_env` | `string` | provider table above | Environment-variable **name**, matching `^[A-Z_][A-Z0-9_]*$`; keys read only at request time, not inline config. |
| `credential_host` | `string` | provider table above | Must exactly equal endpoint `host[:port]`; custom endpoints must specify this themselves. |
| `allow_insecure_local` | `boolean` | effectively `false` | Permit HTTP only at loopback; never remote plaintext credentials. |
| `auth` | `boolean` | effectively `true` | `false` allowed only for explicitly configured loopback NVIDIA NIM chat. Cloud speech always authenticates. |
| `options` | `Rose.ProviderOptions` | `{}` | Provider-native normalized-chat JSON options; detailed below. |
| `capabilities` | `Rose.Config.ProviderCapabilities` | `{}` | Capability declaration, not automatic model discovery. |
| `capabilities.tools` | `boolean` | not enabled | Explicitly declare model supports custom functions; required for cloud agent tools. Cannot enable Sonar tools. |
| `headers` | provider-specific header record | `{}` | Allowed headers below; values <=4096 bytes, no control characters. |
| `timeout` | `integer` | `120000` | `1..3600000` ms. Also used by cloud speech. |
| `max_request_bytes` | `integer` | `4194304` | `256..67108864` bytes (64 MiB ceiling), cloud JSON request bound. |
| `max_response_bytes` | `integer` | `8388608` | `256..67108864` bytes, includes response headers. |
| `max_event_bytes` | `integer` | `min(1048576, max_response_bytes)` | `128..max_response_bytes` bytes per SSE event. |

Allowed header names are case-insensitive; canonical lowercase names are exposed
in the [types](../lua/rose/types.lua): OpenAI `openai-organization`,
`openai-project`; Anthropic `anthropic-version`, `anthropic-beta`,
`anthropic-workspace-id`; xAI `x-grok-conv-id`; NVIDIA and Perplexity accept only
an empty extra-header table. Anthropic's omitted version header becomes
`2023-06-01`; routing/authentication/cookie overrides are not accepted.
See [header validation and request construction](../lua/rose/providers/init.lua).

### Provider-native JSON options

`Rose.ProviderOptions` explicitly types the common fields below **and** admits
additional string-keyed `Rose.JSONValue` fields, because Rose intentionally
passes unfamiliar provider-native options through rather than translating them.
`Rose.JSONValue` is a recursive **type alias**, not runtime recursion: finite
JSON numbers, booleans, strings, arrays, objects and `vim.NIL` for JSON null;
functions, arbitrary userdata and cyclic tables are not JSON data.
See the [types](../lua/rose/types.lua) and
[option merger](../lua/rose/providers/common.lua).

| Known option | Type | Default / purpose / constraints |
| --- | --- | --- |
| `temperature`, `top_p` | `number` | None; sampling, range/model support defined by the provider. |
| `max_tokens` | `integer` | None; positive and explicitly required for normalized Anthropic Messages. |
| `max_completion_tokens` | `integer` | None; Chat API token budget where supported. |
| `max_output_tokens` | `integer` | None; Responses API token budget where supported. |
| `n` | `1` | Omitted; normalized chat accepts only one completion. |
| `parallel_tool_calls` | `boolean` | None; provider-native concurrency setting, not translated across APIs. |
| `tool_choice` | `string \| Rose.JSONObject` | None generally; API-native literal/object. NIM inserts `"auto"` when Rose tools are supplied and no choice was set. |
| `reasoning`, `thinking` | `Rose.JSONObject` | None; provider-specific reasoning/thinking options. |
| `response_format`, `text` | `Rose.JSONObject` | None; native structured-output/text options; Rose does not validate the returned application schema. |
| `stop` | `string \| string[]` | None; provider-native stop sequences. |
| `stop_sequences` | `string[]` | None; Anthropic-native stop sequences. |
| `metadata` | `Rose.JSONObject` | None; provider-specific metadata restrictions still apply. |
| `store` | `boolean` | OpenAI Responses encoder supplies `false` if omitted; not a setup default. |
| `include` | `string[]` | OpenAI adds `"reasoning.encrypted_content"` when `store=false`; preserves existing entries. |
| `system` | `string \| Rose.JSONObject[]` | Anthropic-native text/blocks; conflicts with system messages in normalized history. |

`model`, `messages`, `input`, `tools` and `stream` are reserved and cannot be
overridden through normalized `options`. For arbitrary native request bodies,
use `rose.model_request`; its raw body is separate from setup and does not
automatically merge the configured `model` or `options`. Sonar additionally
rejects `tool_choice` and `parallel_tool_calls` on normalized requests.
See [common encoding](../lua/rose/providers/common.lua),
[Chat encoding](../lua/rose/providers/chat.lua),
[Responses encoding](../lua/rose/providers/responses.lua),
[Anthropic encoding](../lua/rose/providers/anthropic.lua) and
[raw requests](providers.md).

## Speech

| Option | Type | Setup default | Purpose / allowed values / limits |
| --- | --- | --- | --- |
| `speech.enabled` | `boolean` | `false` | Master gate; local engines need this; cloud additionally needs both provider flags. |
| `speech.stt` | `Rose.Config.STT` | table below | Speech-to-text selection. |
| `speech.stt.provider` | `"auto" \| "openai" \| "xai" \| "whisper" \| "anthropic" \| "perplexity" \| "nvidia"` | `"auto"` | Last three are recognized but report unavailable, not implemented STT backends. |
| `speech.stt.model` | `string` | absent | OpenAI model override only when `stt.provider="openai"`; leave absent for xAI/Whisper, whose servers select the model. |
| `speech.stt.language` | `string` | `"auto"` | `auto` omits the language field; otherwise 1..16 ASCII letters/hyphens, starting with a letter. |
| `speech.tts` | `Rose.Config.TTS` | table below | Text-to-speech selection. |
| `speech.tts.provider` | `"auto" \| "openai" \| "xai" \| "piper" \| "anthropic" \| "perplexity" \| "nvidia"` | `"auto"` | Last three report unavailable, not implemented TTS backends. |
| `speech.tts.model` | `string` | absent | OpenAI model override only for explicit OpenAI selection; xAI does not accept one. Piper uses `piper.model`, not this field. |
| `speech.tts.voice` | `string` | absent | Cloud voice ID for explicitly selected provider; at request time 1..64 ASCII word/hyphen characters. Piper ignores it. |
| `speech.tts.format` | `"mp3" \| "wav"` | `"mp3"` | Cloud output codec; Piper always produces WAV and reports that real MIME type. |
| `speech.record` | `Rose.Config.Record` | table below | External recorder selection and duration. |
| `speech.record.cmd` | `string[]` argv | absent | Nil detects a recorder; explicit 1..64 nonempty NUL-free strings. Output file path is appended. |
| `speech.record.max_seconds` | `integer` | `60` | Recording duration, `1..600` **seconds**. |
| `speech.play` | `Rose.Config.Play` | `{}` | Playback configuration. |
| `speech.play.cmd` | `string[]` argv | absent | Nil detects a codec-compatible player; explicit 1..64 nonempty NUL-free strings. Input file path is appended. |
| `speech.whisper` | `Rose.Config.Whisper` | `{}` | No local server configured by default. |
| `speech.whisper.url` | `string` | absent | Explicit loopback **HTTP** base URL for a separately running whisper.cpp server; `/inference` is appended. |
| `speech.whisper.timeout` | `integer` | absent | Adapter default `120000`; request deadline `1..3600000` ms. |
| `speech.piper` | `Rose.Config.Piper` | `{}` | No local executable configured by default. |
| `speech.piper.cmd` | `string[]` argv | absent | Explicit 1..64 nonempty strings; installed executable required. Rose does not download it or its voices. |
| `speech.piper.model` | `string` | absent | Absolute local model path, appended as `--model`; omit if the explicit command supplies the model. |
| `speech.max_audio_bytes` | `integer` | `26214400` | `1024..268435456` bytes; checks STT upload size and bounds cloud TTS output. Not a byte cap on recorder/Piper disk output. |
| `speech.max_text_chars` | `integer` | `4096` | `1..100000`; implementation uses Lua `#text`, so this is a **byte** count despite the name. Provider limits may be tighter. |

These fields are consumed by [speech selection](../lua/rose/speech/init.lua),
[speech HTTP](../lua/rose/speech/http.lua),
[audio processes](../lua/rose/speech/audio.lua) and [Piper](../lua/rose/speech/piper.lua).

`auto` first selects a configured local engine (Whisper URL or Piper command),
then the selected chat provider if it is OpenAI/xAI and cloud consent is present.
A broken configured local engine fails rather than silently sending audio to a
cloud fallback. `auto` ignores configured model/voice overrides so one provider's
IDs cannot be sent to another. Optional STT/TTS model, language, voice and Whisper
URL strings are checked at setup for nonblank text, no controls and <=256 bytes;
operation-specific constraints above can be tighter. See
[speech selection and validation](../lua/rose/speech/init.lua).

### Speech operational defaults (not setup values)

| Backend | STT default | TTS default | Endpoint / additional behavior |
| --- | --- | --- | --- |
| OpenAI | `gpt-4o-mini-transcribe` | model `gpt-4o-mini-tts`, voice `marin` | Base `https://api.openai.com/v1`; TTS input <=4096 bytes as implemented. |
| xAI | server-selected; no model field | server-selected; voice `eve` | Base `https://api.x.ai/v1`; TTS <=15000 bytes as implemented, language `"auto"`, sample rate 24000 Hz. |
| Whisper | chosen when server starts | absent | No default URL; no per-request model field. |
| Piper | absent | configured model/argv | WAV only; fixed 120000 ms process deadline. |

Cloud speech reuses `providers.openai`/`providers.xai` endpoint,
`credential_host`, `allow_insecure_local`, `key_env` and `timeout`; it does not
require cloud-chat `api`, `model`, `capabilities` or `options`, and does not use
the cloud JSON size limits. See [speech HTTP](../lua/rose/speech/http.lua),
[OpenAI speech](../lua/rose/speech/openai.lua),
[xAI speech](../lua/rose/speech/xai.lua),
[Whisper](../lua/rose/speech/whisper.lua) and [Piper](../lua/rose/speech/piper.lua).

Recorder discovery tries `pw-record`, `arecord`, then `ffmpeg` with 16 kHz mono
PCM WAV arguments. WAV playback tries `pw-play`, `paplay`, `aplay`, `mpv`,
`ffplay`; MP3 playback tries only `mpv`, `ffplay`. Playback has a fixed 600-second
limit, and recorder stop has a fixed 3000 ms graceful-stop window; neither is a
setup option. See [audio adapters](../lua/rose/speech/audio.lua) and
[speech usage](speech.md).

## Hugging Face Hub

| Option | Type | Setup default | Adapter default / purpose / limits |
| --- | --- | --- | --- |
| `hub.python` | `string` | `"python3"` | Installed executable/path containing `huggingface_hub`; no automatic installation. |
| `hub.cache_dir` | `string` | absent | `stdpath("cache") .. "/rose/huggingface"`; absolute private cache outside workspace, no symlink ancestry. |
| `hub.xet_cache` | `string` | absent | `cache_dir .. "/xet"`; absolute Xet cache, no symlink ancestry. |
| `hub.max_workers` | `integer` | `4` | `1..16` concurrent file workers; also configures supported Xet concurrency controls. |
| `hub.max_files` | `integer` | absent | `256`; selected-file limit `1..4096`. |
| `hub.max_total_bytes` | `integer` | absent | `10737418240` (10 GiB); selected bytes `1..9007199254740991`. |
| `hub.xet` | `"auto" \| "disabled"` | `"auto"` | Use available Xet or explicit HTTP; inherited explicit Xet disable is respected. |
| `hub.high_performance` | `boolean` | `false` | Explicit higher-resource Xet mode; does not remove limits. |
| `hub.timeout_ms` | `integer` | absent | `0`; overall operation deadline `0..2147483647` ms, including confirmation; zero means none, cancellation still works. |
| `hub.on_progress` | `Rose.HubProgressCallback` | absent | Trusted UI callback receiving capability events or file-count/phase progress. No synthetic throughput guarantees. |
| `hub.approve_upload` | `Rose.HubUploadApproval` | absent | Trusted confirmation callback; default is the native preview/selection UI. |

Native setup forwards only the `hub` section plus **top-level** resolved
`workspace` and `trusted`; do not set `hub.workspace` or `hub.trusted` as native
overrides. The standalone `require("rose.hub").setup(...)` API accepts those
fields separately. A nested `hub.trusted=true` cannot elevate workspace trust.
See [native Hub setup](../lua/rose/init.lua), [Hub configuration](../lua/rose/hub.lua)
and [worker filesystem checks](../scripts/rose_hub.py).

`on_progress(event)` receives either `event="capabilities"` with installed
versions, `"http"|"xet"` transport and feature flags, or `event="progress"` with
phase `"hashing"|"staging"|"uploading"|"downloading"|"http-fallback"`.
`completed`/`total` count files where supplied; they are absent for fallback.
The callback types also name the complete upload preview, source snapshots and
destination records. See [Hub types](../lua/rose/types.lua) and
[emitted events](../scripts/rose_hub.py).

`approve_upload(preview, respond)` must present the **entire exact manifest**,
obtain approval, and call `respond(vim.deepcopy(preview))`; call `respond(nil)`
to decline. `respond(true)` is not authorization. This callback is a trusted
application capability, not a model tool or JSON option. Uploads still require
`trusted=true`; downloads and metadata are explicit user operations but do not
require that upload trust flag. See [Hub approval implementation](../lua/rose/hub.lua)
and [transfer/approval guide](huggingface.md).

## Agent, checks and workspace tooling

| Option | Type | Setup default | Purpose / range |
| --- | --- | --- | --- |
| `agent.max_iterations` | `integer` | `6` | `1..30` coder model rounds per cycle; planner/reviewer are capped at `min(2, max_iterations)`. |
| `agent.max_repair_rounds` | `integer` | `1` | `0..3` repair rounds after the initial coder/validation/reviewer cycle. |
| `agent.max_cycles` | `integer` | derived `2` | Compatibility input `1..4`; translates to `max_repair_rounds=max_cycles-1` only if explicit repair rounds are absent. Resolved value is always repair rounds + 1. |
| `agent.max_tool_calls` | `integer` | `8` | `1..32` tool calls per model response. |
| `agent.max_tool_result` | `integer` | `24000` | `256..1048576` bytes; encoded tool-result excerpt bound. The JSON truncation wrapper can add bytes; this is not a strict final-envelope byte cap. |
| `agent.max_context` | `integer` | `120000` | `1024..4194304` bytes of encoded message JSON, not a model token count; also bounds native chat history. |
| `checks.<name>.cmd` | `string[]` argv | required when defined | Explicit nonempty argv; NUL-free arguments; nonempty executable. Executed in workspace, not via a shell. |
| `checks.<name>.filetypes` | `string[]` | absent | Nil/empty means all filetypes; otherwise exact native filetype names. |
| `checks.<name>.timeout` | `integer` | absent | Adapter default `30000`; `1..120000` ms per check, also bounded by remaining aggregate budget. |
| `checks.<name>.kind` | `"lint" \| "typecheck" \| "diagnostics"` | absent | These supported gate tags count completed checks as static evidence. Omit for ordinary tests; arbitrary labels do not add static evidence. |
| `diver.path` | `string` | absent | Existing explicit Diver directory; needed before its tooling can be discovered. |
| `diver.lsp` | `string[]` | `{}` | Explicit native LSP config names matching `^[%w_-]+$`; no automatic enablement list. |
| `scip.path` | `string` | `"index.scip.json"` | Workspace-relative existing decoded `.json` index; not raw SCIP protobuf and not an indexing command. |

Execution/writes require top-level trust and checks require saved workspace
buffers; no applicable checks or merely empty cached diagnostics do not prove
verification. Completed static evidence comes from live native lint or a
matching named check with one of the three gate kinds. See
[agent loop](../lua/rose/native/agent.lua),
[host validation](../lua/rose/native/validation.lua),
[check execution](../lua/rose/tooling/checks.lua) and
[file tools](../lua/rose/tooling/files.lua).

With `trusted=true`, an explicit Diver path is appended to runtimepath and only
the selected LSP configs are enabled, requiring native `vim.lsp.config/enable`
(Neovim 0.11+). Rose does not source Diver `init.lua`, initialize its full plugin
configuration, or provide a native `lint` setup table: lint comes from the
optional configured/loaded Diver runner. See
[discovery](../lua/rose/tooling/discovery.lua),
[lint integration](../lua/rose/tooling/lint.lua) and
[SCIP reader](../lua/rose/tooling/scip.lua).

## Debug probes

| Option | Type | Setup default | Operational behavior |
| --- | --- | --- | --- |
| `debug.adapters` | `table<string, Rose.Config.DebugAdapter>` | absent | Named stdio adapters; effectively no adapters. |
| `debug.adapters.<name>.cmd` | `string[]` argv | required when defined | Installed explicit adapter executable/args; `${workspaceFolder}` expansion. |
| `debug.configurations` | `table<string, Rose.Config.DebugProbe>` | absent | Named launch probes; effectively no probes. |
| `debug.configurations.<name>.adapter` | `string` | required when defined | Exact key in `debug.adapters`. |
| `debug.configurations.<name>.launch` | `Rose.Config.DebugLaunch` | absent | Adapter default `{}`, then `cwd=workspace`; string-keyed JSON object with adapter-specific extensions. |
| `debug.configurations.<name>.launch.request` | `"launch"` | absent | Only launch is supported; removed before sending the DAP launch request. |
| `debug.configurations.<name>.launch.cwd` | `string` | absent | Defaults to workspace; must resolve to an existing directory inside it. |
| `debug.configurations.<name>.launch.program` | `string` | absent | Adapter-native target program path; `${workspaceFolder}` expansion. |
| `debug.configurations.<name>.launch.args` | `string[]` | absent | Adapter-native debuggee arguments; not shell text. |
| `debug.configurations.<name>.launch.env` | `table<string, string>` | absent | Adapter-native debuggee environment. |
| `debug.configurations.<name>.launch.console` | `string` | absent | Adapter-defined console name, not a Rose-wide enum. |
| `debug.configurations.<name>.launch.stopOnEntry` | `boolean` | absent | Adapter-native stop-on-entry flag. |
| `debug.configurations.<name>.breakpoints` | `table<string, integer[]>` | absent | Adapter default `{}`; workspace-relative existing source paths to positive 1-based line numbers. |
| `debug.configurations.<name>.timeout` | `integer` | absent | Adapter default `30000` ms; capped at `120000`; use positive integers (no explicit lower-bound/integrality validation here). |

Debug is opt-in trusted local code, not sandboxing or test proof; only named
stdio launch probes are implemented, not TCP adapters, attach, evaluate or a
full interactive debugger. Extra `launch` JSON fields are passed through, and
string values expand `${workspaceFolder}` with a maximum nesting depth of 16.
Rose confines launch cwd and breakpoint paths; it does not assert that all
adapter-specific program/argument behavior is confined. See
[`rose/debug.lua`](../lua/rose/debug.lua) and
[debug usage](native.md#debug-probes).

## Flow and third-party MCP

| Option | Type | Setup default | Purpose / restrictions |
| --- | --- | --- | --- |
| `flow.cmd` | `string[]` argv | `{ "flow", "serve" }` | Explicit installed Flow command; Rose appends `--workspace`, conditional `--trusted`, and bridge `--nvim` arguments. |
| `flow.timeout` | `integer` | `600000` | Flow call deadline, `1..3600000` ms; not Flow's model-server timeout. |
| `flow.bridge` | `boolean` | `true` | Require a private native-editor bridge; failure stops rather than downgrades. `false` explicitly disables this bridge protection. |
| `mcp.servers` | `table<string, Rose.Config.MCPServer>` | `{}` | Named explicit stdio servers; no discovery/startup execution. |
| `mcp.servers.<name>.cmd` | `string[]` argv | required when defined | Explicit NUL-free executable/args. |
| `mcp.servers.<name>.trusted` | `boolean` | absent | Must be exactly `true`; executable trust independent of workspace trust. |
| `mcp.servers.<name>.read_only` | `boolean` | absent | Must be exactly `true`; declaration is not an OS sandbox. |
| `mcp.servers.<name>.allow_tools` | `string[]` | absent | Exact tool allowlist; nil/empty permits nothing. |
| `mcp.servers.<name>.env` | `table<string, string>` | absent | Environment overrides passed to `vim.system`; otherwise inherit environment. |
| `mcp.servers.<name>.timeout` | `integer` | absent | Adapter default `30000` ms; use positive integers, no Rose setup range validation. |

MCP servers always run with the **top-level workspace** as cwd; nested server
`cwd`, `initialize_timeout` and `max_message` are **not forwarded setup options**.
The low-level `rose.native.mcp.start` API accepts its own options, but native
server/Flow setup uses fixed initialization `10000` ms and message limit
`8388608` bytes. No setup `mcp.transport` exists: this integration is stdio.
See [Flow process wiring](../lua/rose/native/flow.lua),
[server forwarding](../lua/rose/native/servers.lua) and
[low-level MCP](../lua/rose/native/mcp.lua).

## Loopback web UI

| Option | Type | Setup default | Purpose / range |
| --- | --- | --- | --- |
| `webui.enabled` | `boolean` | `false` | Permit explicit `:RoseWebUI`; setup only registers commands and does not listen. |
| `webui.host` | `"127.0.0.1" \| "::1" \| "localhost"` | `"127.0.0.1"` | Native setup accepts exactly these hosts; `localhost` maps to IPv4 loopback. |
| `webui.port` | `integer` | `0` | `0..65535`; zero chooses an ephemeral TCP port. |
| `webui.open` | `boolean` | `true` | Open the browser when explicitly starting a new listener. |
| `webui.max_request_bytes` | `integer` | `16777216` | `4096..268435456` body bytes; route-specific fixed limits can be tighter. |
| `webui.max_clients` | `integer` | `8` | `1..64` simultaneous clients. |
| `webui.idle_timeout_ms` | `integer` | `30000` | `100..600000` ms per idle client. |

The standalone server's loopback helper also recognizes other `127.x.x.x`
addresses, but **native setup does not**; the public input type follows the
stricter core contract. Session tokens, fixed header/route limits and listen
backlog are not user setup options. Enabling the UI does not grant provider,
microphone or transfer consent. See [core validation](../lua/rose/config.lua),
[UI start](../lua/rose/webui/init.lua), [server limits](../lua/rose/webui/server.lua)
and [web UI guide](webui.md).

## Historical schema is separate

`legacy=true` routes to the unsupported historical implementation documented in
[`docs/legacy.md`](legacy.md); its `RoseOptions` class is not `Rose.Config`.
Old provider/API-key/UI/plugin options do **not** become native options merely
because the deep merge retains unknown fields. Use the native keys above;
there is no claim that historical model/provider/menu settings work in native
mode. See the [mode switch](../lua/rose/init.lua) and
[legacy configuration](../lua/rose/legacy/config.lua).
