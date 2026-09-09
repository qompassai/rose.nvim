---@meta

-- Native setup types. Historical RoseOptions belongs to rose.legacy.config.
-- No runtime code: recursive JSON aliases describe wire data, not a traversal.

---@alias Rose.Provider "rose"|"ollama"|"openai"|"anthropic"|"xai"|"nvidia"|"perplexity"
---@alias Rose.HTTPTransport "auto"|"curl"|"native"
---@alias Rose.ResponsesAPI "responses"|"chat"
---@alias Rose.PerplexityAPI "agent"|"sonar"
---@alias Rose.SpeechSTTProvider "auto"|"openai"|"xai"|"whisper"|"anthropic"|"perplexity"|"nvidia"
---@alias Rose.SpeechTTSProvider "auto"|"openai"|"xai"|"piper"|"anthropic"|"perplexity"|"nvidia"
---@alias Rose.AudioFormat "mp3"|"wav"
---@alias Rose.CheckKind "lint"|"typecheck"|"diagnostics"
---@alias Rose.LoopbackHost "127.0.0.1"|"::1"|"localhost"
---@alias Rose.XetMode "auto"|"disabled"
---@alias Rose.HubTransport "http"|"xet"
---@alias Rose.Argv string[] Nonempty executable-and-arguments array; never a shell command string.
---@alias Rose.Environment table<string, string> Environment variable names mapped to values.

-- JSON null is vim.NIL (Neovim's nil sentinel), not a Lua nil table entry.
---@alias Rose.JSONValue boolean|number|string|vim.NIL
---| Rose.JSONValue[]|table<string, Rose.JSONValue>
---@alias Rose.JSONObject table<string, Rose.JSONValue>

-- Open records are deliberate only at provider/DAP JSON extension boundaries.
-- Known fields have concrete types; additional fields must still be JSON values.
---@class Rose.ProviderOptions
---@field [string] Rose.JSONValue
---@field temperature? number Sampling temperature; model/API-defined range, no Rose default.
---@field top_p? number Nucleus sampling; model/API-defined range, no Rose default.
---@field max_tokens? integer Positive token budget; explicit for normalized Anthropic Messages.
---@field max_completion_tokens? integer Chat completion token budget; model/API-defined range.
---@field max_output_tokens? integer Responses output token budget; model/API-defined range.
---@field n? 1 Normalized chat supports one completion only.
---@field parallel_tool_calls? boolean Provider-native tool concurrency option; no Rose default.
---@field tool_choice? string|Rose.JSONObject API-native value/object, not a cross-provider enum.
---@field reasoning? Rose.JSONObject Provider-native reasoning fields; no translation by Rose.
---@field thinking? Rose.JSONObject Anthropic-native thinking fields; no translation by Rose.
---@field response_format? Rose.JSONObject Provider-native structured-output configuration.
---@field text? Rose.JSONObject Responses-native text/format configuration.
---@field stop? string|string[] Provider-native stop sequences.
---@field stop_sequences? string[] Anthropic-native stop sequences.
---@field metadata? Rose.JSONObject Provider-native metadata; subject to API-specific constraints.
---@field store? boolean OpenAI Responses defaults false at encoding, not in setup options.
---@field include? string[] OpenAI adds reasoning.encrypted_content when store=false.
---@field system? string|Rose.JSONObject[] Anthropic system text/blocks; not with system messages.

---@class Rose.LocalOptions
---@field [string] Rose.JSONValue Shared /api/chat model options, passed through unchanged.
---@field temperature? number Model sampling temperature; no Rose default.
---@field top_p? number Model nucleus sampling probability; no Rose default.
---@field top_k? integer Model top-k sampling count; no Rose default.
---@field num_ctx? integer Context-window tokens; model/server determines supported range.
---@field num_predict? integer Generation-token limit; Ollama defines special negative values.
---@field seed? integer Random seed; server-defined semantics, no Rose default.
---@field stop? string[] Stop sequences; no Rose default.

---@class Rose.OllamaOptions: Rose.LocalOptions

---@class (exact) Rose.Config.TLS
---@field ca_file? string Absolute POSIX PEM CA path; absent uses system trust store.
---@field cert_file? string Absolute POSIX PEM client certificate path, paired with key_file.
---@field key_file? string Absolute POSIX PEM private key path, paired with cert_file.
---Paths: 1..4096 bytes, no controls/colons/passwords; read only by curl at request time.

---@class Rose.Config.Rose
---@field base_url? string Default http://127.0.0.1:11434; remote requires HTTPS and allow_remote.
---@field model? string Nonempty installed model ID; default qwen2.5-coder:7b.
---@field timeout? integer Request deadline in ms, 1..3600000; default 120000.
---@field allow_remote? boolean Permit a non-loopback HTTPS endpoint; default false.
---@field transport? "auto"|"curl" Default auto; all Rose requests require hardened curl.
---@field options? Rose.LocalOptions Shared /api/chat JSON options; absent by default.
---@field tls? Rose.Config.TLS Default {}; HTTPS requires paired client cert/key, optional CA.
---Rose HTTPS requires TLS1.3-only and X25519MLKEM768-only support in curl's TLS backend.

---@class Rose.Config.Rose.Resolved: Rose.Config.Rose
---@field base_url string
---@field model string
---@field timeout integer
---@field allow_remote boolean
---@field transport "auto"|"curl"
---@field tls Rose.Config.TLS

---@class Rose.Config.Ollama
---@field base_url? string HTTP(S) endpoint; default http://127.0.0.1:11434.
---@field model? string Nonempty installed model ID; default qwen2.5-coder:7b.
---@field timeout? integer Request deadline in ms, 1..3600000; default 120000.
---@field allow_remote? boolean Permit a non-loopback Ollama endpoint; default false.
---@field transport? Rose.HTTPTransport Default auto (safe curl adapter); native is explicit opt-in.
---@field options? Rose.OllamaOptions Ollama-native JSON options; absent by default.

---@class Rose.Config.Ollama.Resolved: Rose.Config.Ollama
---@field base_url string
---@field model string
---@field timeout integer
---@field allow_remote boolean
---@field transport Rose.HTTPTransport

---@class Rose.Config.ProviderCapabilities
---@field tools? boolean Explicit model supports custom tools; absent means not enabled.

---@class Rose.Config.OpenAIHeaders
---@field ["openai-organization"]? string At most 4096 bytes, no control characters.
---@field ["openai-project"]? string At most 4096 bytes, no control characters.

---@class Rose.Config.AnthropicHeaders
---@field ["anthropic-version"]? string Adapter default 2023-06-01; <=4096 bytes, no controls.
---@field ["anthropic-beta"]? string At most 4096 bytes, no control characters.
---@field ["anthropic-workspace-id"]? string At most 4096 bytes, no control characters.

---@class Rose.Config.XAIHeaders
---@field ["x-grok-conv-id"]? string At most 4096 bytes, no control characters.

---@class (exact) Rose.Config.NoHeaders

-- Fields may be partial for inactive providers or speech-only overrides.
-- Selecting a cloud chat provider requires its api, model and endpoint explicitly.
---@class Rose.Config.Provider
---@field endpoint? string HTTPS base URL, explicit for chat; speech has provider-specific defaults.
---@field model? string Explicit nonblank chat model ID, no control characters; no setup default.
---@field key_env? string Environment variable name matching ^[A-Z_][A-Z0-9_]*$; never a key.
---@field options? Rose.ProviderOptions Normalized-chat JSON options; adapter default {}.
---@field capabilities? Rose.Config.ProviderCapabilities Adapter default {}; tools opt-in.
---@field credential_host? string Exact endpoint host[:port]; required for a custom authority.
---@field allow_insecure_local? boolean Permit HTTP only at loopback; default effectively false.
---@field auth? boolean Default effectively true; false only for loopback NVIDIA NIM chat.
---@field timeout? integer Request ms, 1..3600000; adapter default 120000.
---@field max_request_bytes? integer Encoded request bytes, 256..67108864; adapter default 4194304.
---@field max_response_bytes? integer Response bytes incl. headers, 256..67108864; default 8388608.
---@field max_event_bytes? integer SSE bytes, 128..max_response_bytes.
---Default: min(1048576, max_response_bytes).

---@class Rose.Config.OpenAI: Rose.Config.Provider
---@field api? Rose.ResponsesAPI Explicit chat API; no setup default.
---@field headers? Rose.Config.OpenAIHeaders Header names are case-insensitive at runtime.

---@class Rose.Config.Anthropic: Rose.Config.Provider
---@field api? "messages" Explicit chat API; no setup default.
---@field headers? Rose.Config.AnthropicHeaders Header names are case-insensitive at runtime.

---@class Rose.Config.XAI: Rose.Config.Provider
---@field api? Rose.ResponsesAPI Explicit chat API; no setup default.
---@field headers? Rose.Config.XAIHeaders Header names are case-insensitive at runtime.

---@class Rose.Config.NVIDIA: Rose.Config.Provider
---@field api? "chat" Explicit chat API; no setup default.
---@field headers? Rose.Config.NoHeaders Must be empty: NVIDIA has no allowed extra headers.

---@class Rose.Config.Perplexity: Rose.Config.Provider
---@field api? Rose.PerplexityAPI Explicit chat API; sonar cannot use Rose custom tools.
---@field headers? Rose.Config.NoHeaders Must be empty: Perplexity has no allowed extra headers.

---@class Rose.Config.Providers
---@field enabled? boolean Cloud adapter gate; default false.
---@field allow_cloud? boolean Consent to send task/source/tool/audio/text data; default false.
---@field provider? Rose.Provider Default rose; legacy ollama-only input auto-selects ollama.
---@field openai? Rose.Config.OpenAI No setup default.
---@field anthropic? Rose.Config.Anthropic No setup default.
---@field xai? Rose.Config.XAI No setup default.
---@field nvidia? Rose.Config.NVIDIA No setup default.
---@field perplexity? Rose.Config.Perplexity No setup default.

---@class Rose.Config.Providers.Resolved: Rose.Config.Providers
---@field enabled boolean
---@field allow_cloud boolean
---@field provider Rose.Provider

---@class Rose.Config.STT
---@field provider? Rose.SpeechSTTProvider Default auto.
---Anthropic, Perplexity and NVIDIA report unavailable.
---@field model? string OpenAI model override only for an explicitly selected provider; default nil.
---@field language? string Default auto; otherwise language code of 1..16 letters/hyphens.

---@class Rose.Config.STT.Resolved: Rose.Config.STT
---@field provider Rose.SpeechSTTProvider
---@field language string

---@class Rose.Config.TTS
---@field provider? Rose.SpeechTTSProvider Default auto.
---Anthropic, Perplexity and NVIDIA report unavailable.
---@field model? string OpenAI model override for explicitly selected provider; default nil.
---@field voice? string Provider voice ID, not a closed enum; default nil (adapter chooses).
---@field format? Rose.AudioFormat Default mp3; Piper always returns WAV.

---@class Rose.Config.TTS.Resolved: Rose.Config.TTS
---@field provider Rose.SpeechTTSProvider
---@field format Rose.AudioFormat

---@class Rose.Config.Record
---@field cmd? Rose.Argv 1..64 nonempty NUL-free args; nil detects pw-record/arecord/ffmpeg.
---@field max_seconds? integer Recording seconds, 1..600; default 60.

---@class Rose.Config.Record.Resolved: Rose.Config.Record
---@field max_seconds integer

---@class Rose.Config.Play
---@field cmd? Rose.Argv 1..64 nonempty NUL-free args; nil detects a format-compatible player.

---@class Rose.Config.Whisper
---@field url? string Explicit loopback HTTP whisper.cpp base URL; nil disables local STT.
---@field timeout? integer Request ms, 1..3600000; adapter default 120000 (absent in setup).

---@class Rose.Config.Piper
---@field cmd? Rose.Argv 1..64 nonempty arguments; nil disables local TTS, no auto-install.
---@field model? string Absolute local model path appended as --model; default nil.

---@class Rose.Config.Speech
---@field enabled? boolean Speech master gate; default false.
---@field stt? Rose.Config.STT Default auto selection and language, no model override.
---@field tts? Rose.Config.TTS Default auto selection, mp3, no model/voice override.
---@field record? Rose.Config.Record Default detected recorder, 60-second limit.
---@field play? Rose.Config.Play Default detected player.
---@field whisper? Rose.Config.Whisper No server is configured by default.
---@field piper? Rose.Config.Piper No executable/model is configured by default.
---@field max_audio_bytes? integer STT upload/cloud-TTS bytes, 1024..268435456; default 26214400.
---@field max_text_chars? integer Despite its name, Lua byte limit, 1..100000; default 4096.

---@class Rose.Config.Speech.Resolved: Rose.Config.Speech
---@field enabled boolean
---@field stt Rose.Config.STT.Resolved
---@field tts Rose.Config.TTS.Resolved
---@field record Rose.Config.Record.Resolved
---@field play Rose.Config.Play
---@field whisper Rose.Config.Whisper
---@field piper Rose.Config.Piper
---@field max_audio_bytes integer
---@field max_text_chars integer

---@class Rose.HubCapabilities
---@field hub_version string
---@field xet_version string|vim.NIL Installed hf_xet version or JSON null.
---@field transport Rose.HubTransport
---@field download_dry_run boolean
---@field upload_folder boolean
---@field paper_info boolean
---@field max_workers integer

---@class Rose.HubCapabilityEvent: Rose.HubCapabilities
---@field event "capabilities"

---@class Rose.HubProgressEvent
---@field event "progress"
---@field phase "hashing"|"staging"|"uploading"|"downloading"|"http-fallback"
---@field completed? integer Completed files, not bytes; absent for http-fallback.
---@field total? integer Selected files; absent for http-fallback.
---@field transport? Rose.HubTransport Present on upload phase start.
---@field message? string Present on http-fallback.

---@class Rose.HubFileIdentity
---@field dev integer Device ID.
---@field ino integer Inode.

---@class Rose.HubFileSnapshot: Rose.HubFileIdentity
---@field size integer File bytes.
---@field mtime_ns integer Modification timestamp, nanoseconds.
---@field ctime_ns integer Metadata-change timestamp, nanoseconds.
---@field sha256 string Exact content digest.

---@class Rose.HubUploadFile
---@field path string Workspace-relative source.
---@field remote_path string Repository-relative destination.
---@field size integer Bytes.
---@field snapshot Rose.HubFileSnapshot

---@class Rose.HubUploadPreview
---@field direction "upload"
---@field repo_id string
---@field repo_type "model"|"dataset"
---@field revision string Requested branch, tag or commit.
---@field commit string Pinned parent commit.
---@field private boolean
---@field visibility "private"|"public"
---@field workspace string Absolute canonical workspace.
---@field workspace_identity Rose.HubFileIdentity
---@field cache_dir string Absolute cache path.
---@field capabilities Rose.HubCapabilities
---@field files Rose.HubUploadFile[]
---@field path_in_repo string Repository-relative prefix; empty means root.
---@field total_bytes integer

---@alias Rose.HubProgressCallback fun(event: Rose.HubProgressEvent|Rose.HubCapabilityEvent)
---@alias Rose.HubUploadApproval
---| fun(preview: Rose.HubUploadPreview, respond: fun(approved: Rose.HubUploadPreview?))

---@class Rose.Config.Hub
---@field python? string Python executable name/path; setup default python3.
---@field cache_dir? string Absolute private cache outside workspace.
---Adapter default: stdpath("cache")/rose/huggingface.
---@field xet_cache? string Absolute Xet cache; operational default cache_dir/xet.
---@field max_workers? integer Concurrent file workers, 1..16; setup default 4.
---@field max_files? integer Selected files, 1..4096; adapter default 256.
---@field max_total_bytes? integer Selected bytes, 1..9007199254740991; adapter default 10737418240.
---@field xet? Rose.XetMode Setup default auto; inherited explicit Xet disable is respected.
---@field high_performance? boolean Explicit resource-intensive Xet mode; setup default false.
---@field timeout_ms? integer Overall operation deadline, 0..2147483647; adapter default 0 (none).
---@field on_progress? Rose.HubProgressCallback Trusted UI callback; no default.
---@field approve_upload? Rose.HubUploadApproval Show full preview; respond with exact copy or nil.

---@class Rose.Config.Hub.Resolved: Rose.Config.Hub
---@field python string
---@field max_workers integer
---@field xet Rose.XetMode
---@field high_performance boolean

---@class Rose.Config.Agent
---@field max_iterations? integer Coder rounds/cycle, 1..30; default 6; other roles cap at 2.
---@field max_repair_rounds? integer Repair retries after initial cycle, 0..3; default 1.
---@field max_cycles? integer Compatibility input, 1..4; used only if max_repair_rounds is absent.
---@field max_tool_calls? integer Calls per model response, 1..32; default 8.
---@field max_tool_result? integer Tool-result excerpt bytes, 256..1048576; default 24000.
---@field max_context? integer Encoded message JSON bytes, 1024..4194304; default 120000.

---@class Rose.Config.Agent.Defaults: Rose.Config.Agent
---@field max_iterations integer
---@field max_repair_rounds integer
---@field max_tool_calls integer
---@field max_tool_result integer
---@field max_context integer

---@class Rose.Config.Agent.Resolved: Rose.Config.Agent.Defaults
---@field max_cycles integer Always max_repair_rounds + 1 after resolution.

---@class Rose.Config.Diver
---@field path? string Existing Diver directory; nil by default, never auto-discovered.
---@field lsp? string[] Named native LSP configs matching ^[%w_-]+$; default {}.

---@class Rose.Config.Diver.Resolved: Rose.Config.Diver
---@field lsp string[]

---@class Rose.Config.Check
---@field cmd Rose.Argv Explicit argv; NUL-free; nonempty executable, no shell interpolation.
---@field filetypes? string[] Nil/empty matches all filetypes.
---@field timeout? integer Per-check ms, 1..120000; adapter default 30000.
---@field kind? Rose.CheckKind Mark completed checks as static evidence; nil is an ordinary check.

---@class Rose.Config.DebugAdapter
---@field cmd Rose.Argv Explicit stdio DAP executable/args; expands ${workspaceFolder}.

---@class Rose.Config.DebugLaunch
---@field [string] Rose.JSONValue Adapter-native launch arguments; nesting limited to 16 levels.
---@field request? "launch" Only launch probes; field removed before the DAP request.
---@field cwd? string Existing directory inside workspace; operational default workspace.
---@field program? string Adapter-native program path; expands ${workspaceFolder}.
---@field args? string[] Adapter-native debuggee arguments.
---@field env? Rose.Environment Adapter-native environment overrides.
---@field console? string Adapter-specific console ID, not a Rose enum.
---@field stopOnEntry? boolean Adapter-native stop-at-entry flag.

---@class Rose.Config.DebugProbe
---@field adapter string Key in debug.adapters, no default.
---@field launch? Rose.Config.DebugLaunch Operational default {} plus cwd=workspace.
---@field breakpoints? table<string, integer[]> Workspace-relative files to positive 1-based lines.
---Default: {}.
---@field timeout? integer Probe ms; adapter default 30000, capped at 120000; use positive integers.

---@class Rose.Config.Debug
---@field adapters? table<string, Rose.Config.DebugAdapter> Named stdio adapters; default absent.
---@field configurations? table<string, Rose.Config.DebugProbe> Named launch probes; default absent.

---@class Rose.Config.SCIP
---@field path? string Workspace-relative decoded JSON index; setup default index.scip.json.

---@class Rose.Config.SCIP.Resolved: Rose.Config.SCIP
---@field path string

---@class Rose.Config.Flow
---@field cmd? Rose.Argv Default {"flow", "serve"}; Rose appends workspace/trust/bridge args.
---@field timeout? integer Flow call ms, 1..3600000; default 600000.
---@field bridge? boolean Require private native-editor bridge; default true.

---@class Rose.Config.Flow.Resolved: Rose.Config.Flow
---@field cmd Rose.Argv
---@field timeout integer
---@field bridge boolean

---@class Rose.Config.MCPServer
---@field cmd Rose.Argv Explicit stdio server executable/args; no shell interpolation.
---@field trusted? boolean Independent executable trust gate; must be true to call.
---@field read_only? boolean Explicit read-only declaration; must be true to call.
---@field allow_tools? string[] Exact permitted tool names; nil/empty denies every call.
---@field env? Rose.Environment Environment overrides for vim.system; default inherited environment.
---@field timeout? integer Tool-call ms; default 30000; positive integer (no Rose range check).

---@class Rose.Config.MCP
---@field servers? table<string, Rose.Config.MCPServer> Named server configurations; default {}.

---@class Rose.Config.MCP.Resolved: Rose.Config.MCP
---@field servers table<string, Rose.Config.MCPServer>

---@class Rose.Config.WebUI
---@field enabled? boolean Allow explicit :RoseWebUI start; default false (setup never listens).
---@field host? Rose.LoopbackHost Default 127.0.0.1; localhost maps to IPv4.
---@field port? integer TCP port, 0..65535; default 0 selects an ephemeral port.
---@field open? boolean Open browser on explicit start; default true.
---@field max_request_bytes? integer Request body bytes, 4096..268435456; default 16777216.
---@field max_clients? integer Simultaneous clients, 1..64; default 8.
---@field idle_timeout_ms? integer Idle client ms, 100..600000; default 30000.

---@class Rose.Config.WebUI.Resolved: Rose.Config.WebUI
---@field enabled boolean
---@field host Rose.LoopbackHost
---@field port integer
---@field open boolean
---@field max_request_bytes integer
---@field max_clients integer
---@field idle_timeout_ms integer

---Partial native setup input; every section and defaulted nested field may be omitted.
---Unrecognized historical options are not supported by native mode. See docs/legacy.md.
---@class Rose.Config
---@field legacy? boolean Default false; true switches to the separate historical schema.
---@field workspace? string Existing directory, default current cwd; resolved to absolute real path.
---@field trusted? boolean Permit configured local code/writes; default false, not an OS sandbox.
---@field max_file_bytes? integer File-tool bytes; adapter default 1048576, capped at 16777216.
---@field check_timeout? integer Aggregate editor_check ms, 1..120000; adapter default 120000.
---@field rose? Rose.Config.Rose Native qompassai/rose backend, selected by default.
---@field ollama? Rose.Config.Ollama
---@field providers? Rose.Config.Providers
---@field speech? Rose.Config.Speech
---@field hub? Rose.Config.Hub
---@field agent? Rose.Config.Agent
---@field diver? Rose.Config.Diver
---@field debug? Rose.Config.Debug
---@field checks? table<string, Rose.Config.Check> Up to 256 named checks; default {}.
---@field scip? Rose.Config.SCIP
---@field flow? Rose.Config.Flow
---@field mcp? Rose.Config.MCP
---@field webui? Rose.Config.WebUI

---Exactly the setup-time defaults. Adapter operational fallbacks remain optional.
---@class Rose.Config.Defaults: Rose.Config
---@field legacy boolean
---@field trusted boolean
---@field rose Rose.Config.Rose.Resolved
---@field ollama Rose.Config.Ollama.Resolved
---@field providers Rose.Config.Providers.Resolved
---@field speech Rose.Config.Speech.Resolved
---@field hub Rose.Config.Hub.Resolved
---@field agent Rose.Config.Agent.Defaults
---@field diver Rose.Config.Diver.Resolved
---@field debug Rose.Config.Debug
---@field checks table<string, Rose.Config.Check>
---@field scip Rose.Config.SCIP.Resolved
---@field flow Rose.Config.Flow.Resolved
---@field mcp Rose.Config.MCP.Resolved
---@field webui Rose.Config.WebUI.Resolved

---Native setup result, not a claim that every optional adapter is configured/available.
---@class Rose.Config.Resolved: Rose.Config.Defaults
---@field workspace string Existing absolute canonical directory.
---@field agent Rose.Config.Agent.Resolved
