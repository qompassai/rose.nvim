# Rose: local, native Neovim coding workflows

Rose runs local Ollama chat and a bounded **planner → coder → validation → reviewer**
workflow inside Neovim. It also connects to Flow over MCP stdio, with an optional
private native Neovim socket for Flow's editor tools. Cloud model APIs and
Hugging Face transfers are separate, explicitly configured opt-ins.

**Native mode is the default.** Setup does not load Plenary, fzf-lua, provider
plugins, Rust libraries, secret stores, or project-local configuration. No plugin
manager, cloud key, Diver installation, or Rose binary is required.

## Install

Neovim **0.13 nightly** is the primary target. Native operations require
`vim.system` (0.10+); older or missing APIs are reported as unavailable rather
than successful. The core is tested on `v0.13.0-dev-1558+g8d5ebdf986`.

Choose **one** installation method. Native mode needs no build step or plugin
dependencies; both managers use the same `require("rose").setup(opts)` API.

### vim.pack

Put this in `init.lua` on a Neovim build with `vim.pack` available
(`:help vim.pack.add`). Git is needed for installation. Rose can be required
immediately after [`vim.pack.add`](https://neovim.io/doc/user/pack/).

```lua
vim.pack.add({
  { src = "https://github.com/qompassai/rose.nvim", version = "main" },
})

---@type Rose.Config
local opts = {
  workspace = vim.fn.getcwd(),
  trusted = false, -- enable only for project code/checks you trust
  ollama = { model = "qwen2.5-coder:7b" },
}
require("rose").setup(opts)
```

### lazy.nvim

With [lazy.nvim installed](https://lazy.folke.io/installation), add this spec to
your plugin list, or return it from `lua/plugins/rose.lua` when using
`{ import = "plugins" }`:

```lua
return {
  "qompassai/rose.nvim",
  main = "rose",
  lazy = false, -- simple startup loading; no service starts during setup
  ---@type Rose.Config
  opts = {
    workspace = vim.fn.getcwd(),
    trusted = false,
    ollama = { model = "qwen2.5-coder:7b" },
  },
}
```

[`opts` invokes `require("rose").setup(opts)`](https://lazy.folke.io/spec)
automatically; do not call setup a second time in `init` or `config`. The
repository's [optional lazy specification](lazy.lua) also lists every Rose
command for command-triggered loading, including speech and Web UI commands.
Use `lazy = false` as above if you want all commands and health checks available
at startup.

### Native packages without vim.pack

Put the repository in a `pack/*/start` directory on `'packpath'`, or use
`vim.opt.rtp:append("/absolute/path/to/rose.nvim")`, then call `setup`.
This is also an option on Neovim builds without `vim.pack`; no third-party
plugin manager or build step is necessary.

### Optional runtime tools

Install [Ollama](https://ollama.com/), run `ollama serve` if it is not already
running, and pull a model with tool support:

```sh
ollama pull qwen2.5-coder:7b
```

The model is configurable; choose one your machine can run. Setup and health
checks never pull a model or contact a service. `curl` must also be on `PATH`,
including when using this nightly's curl-backed `vim.net.request`.

## Configuration

All native setup options have one [complete reference](docs/configuration.md):
names, nested fields, defaults, purpose, types, valid choices, units and trust
requirements. In Neovim, start at `:help rose-config`.

- **Types:** [LuaCATS configuration definitions](lua/rose/types.lua) provide
  `Rose.Config` completion and field descriptions for partial user options.
  Fixed choices use literal unions; commands use argv arrays, maps have typed
  values, and integer limits describe their units.
- **Defaults and resolution:** [lua/rose/config.lua](lua/rose/config.lua)
  contains native defaults and merges/validates setup. Some optional keys have
  no default entry, so use the reference rather than treating that table as
  an exhaustive schema.
- **Inspection:** After setup, `:lua vim.print(require("rose").options)` shows
  the resolved configuration. Change options in your own Neovim config, not
  in the installed plugin. Repeating setup cancels active work.

Both install methods accept the same options. For a trusted Python project,
add named checks to the `opts` table:

```lua
---@type Rose.Config
local opts = {
  trusted = true, -- executable project/check trust, not a sandbox
  checks = {
    python_lint = {
      cmd = { "ruff", "check", "--isolated", "." },
      kind = "lint",
      filetypes = { "python" },
      timeout = 30000, -- milliseconds
    },
    unit = {
      cmd = { "python3", "-m", "unittest", "discover" },
      filetypes = { "python" },
      timeout = 60000,
    },
  },
}
```

Use that table as lazy.nvim's `opts`, or pass it to `require("rose").setup(opts)`
after `vim.pack.add`. The named checks require Ruff and Python; replace them
with commands appropriate for your project. Historical `legacy = true`
configuration is separate and unsupported; see [legacy notes](docs/legacy.md).

## Use

Run commands from a project file. The scratch transcript does not steal focus;
native agent/check calls retain the source buffer and validate written paths.

| Command | Behavior |
| --- | --- |
| `:RoseAsk [question]` | Chat with the configured model (local by default), no tool execution; prompts with `vim.ui.input` if omitted. |
| `:RoseAgent [task]` | Sequential isolated planner/coder/reviewer contexts and a required host-owned validation gate. |
| `:RoseCheck [name]` | Run one configured named check or all checks applicable to the source file. |
| `:RoseFlow [task]` | Lazily start Flow and call `flow_run`. |
| `:RoseStop` | Cancel model/Hub requests; stop MCP processes, Flow socket and active DAP probes. |
| `:RoseDictate` / `:RoseSpeechStop` | Record from the microphone with a local tool, transcribe, and insert the text at the cursor (or ask Rose from the chat buffer). |
| `:[range]RoseSpeak [text]` | Speak a range, given text or the last Rose response with OpenAI, xAI or local piper, then play it. |
| `:RoseSpeechStatus` | Show which speech providers are usable and why others are not; never contacts a provider. |
| `:RoseWebUI` / `:RoseWebUIStop` / `:RoseWebUIStatus` | Start, stop, or inspect the local loopback web UI. |
| `:RoseHubDownload` / `:RoseHubUpload` | Prompt for an explicit Hugging Face file manifest, then show a transfer preview for approval. |
| `:RoseHubPaper` | Paper metadata or explicit PDF/Markdown/BibTeX repository assets; not arXiv publication. |
| `:RoseHubStatus` / `:RoseHubStop` | Inspect or cancel an explicit Hub operation. |
| `:checkhealth rose` | Report native capabilities and missing executables, without contacting a model. |

The scratch chat buffer has `q` to hide, `i` to ask, and `<C-c>` to stop.
Chat history is in memory only and bounded. Setup is idempotent: repeating it
cancels old work and replaces commands/autocommands, sockets and UI state.
`require("rose").shutdown()` performs the same cleanup without reinitializing.

Only the coder receives `file_write`. Tool arguments are validated by
`require("rose.tools").call`; no shell tool or deletion tool exists. Tool-call
IDs and errors are retained. Defaults allow at most six coder model rounds,
two each for planner and reviewer, and eight tool calls per response. Context
and tool-result size limits are configurable under `agent`. One bounded repair
cycle reruns coder → validation → reviewer if evidence or approval is missing;
set `agent.max_cycles=1` (or `max_repair_rounds=0`) to disable repairs.

### Verification means evidence, not model confidence

Each changed path must have an applicable named check; every selected check
must return `status="ok"`. Rose also runs `editor_lint` for each affected path:
it requires completed, verified lint evidence, or a passing explicit named
static check with `kind="lint"`, `"typecheck"` or `"diagnostics"`. A generic
smoke/unit check cannot stand in for unavailable language validation.
Empty diagnostics never count as a passed check.
Missing tools/checks, uncovered languages, timeouts, stale buffers and exhausted
workflow rounds remain **unverified**; failed checks or error diagnostics fail
the gate. Cached diagnostics are reported separately and can veto a pass; their
absence does not erase successful explicit checks. Results describe the scope
of the configured checks, not proof that all code is correct. The independent
reviewer must return `{"approved":true,"issues":[],"summary":"..."}`; prose or a
rejected verdict cannot approve a run, and approval cannot override host checks.

Save unsaved project buffers before checking. Rose does not silently save user
edits to make a check pass. Check executables and arguments come only from your
trusted setup configuration; models select names, never arbitrary argv.

## Flow bridge

Install the Flow CLI separately. Configure a fixed argv prefix if it is not
available as `flow serve`:

```lua
require("rose").setup({
  workspace = vim.fn.getcwd(),
  trusted = true,
  flow = {
    cmd = { "flow", "serve" },
    -- An explicit operator config can be passed using:
    -- cmd = { "flow", "serve", "--config", "/absolute/operator-config.toml" },
    bridge = true,
    timeout = 600000, -- milliseconds (Flow's own Ollama config uses seconds)
  },
})
```

Rose adds `--workspace /resolved/root`, `--trusted` only when enabled, and
`--nvim /private/directory/nvim.sock` when a private Unix bridge is available.
The bridge uses `vim.fn.serverstart`, not TCP or a plugin. It is cleaned up on
stop, re-setup and editor exit. If a requested private bridge is unavailable,
the Flow operation fails closed rather than silently permitting disk-only writes
behind unsaved buffers. The reason is available in
`require("rose.native.flow").bridge_error`. Explicit `flow.bridge=false` is an
operator opt-out from editor-buffer protection, not an automatic fallback.
Cancellation/timeouts revoke the socket and retain writer ownership until the
owned Flow process exits, including termination escalation for an unresponsive
server. Configured checks remain executable code; child-process cleanup inside
Flow is also necessary and is not an OS sandbox.

Flow requires optional `pynvim` for its reverse editor attachment. It calls fixed
Lua expressions with allowlisted `editor_*` tool names and arguments, not
model-generated Lua or Ex. The MCP transport implements newline JSON-RPC,
initialization, `tools/list`, `tools/call`, request deadlines, cancellation,
unsupported server-request errors and process shutdown. `flow_status` does not
contact a cloud provider. Rose and Flow are independent: **RoseAgent does not
require Flow**, and Flow can operate without Neovim.

Rose and Flow have separate, explicit operator configurations; Rose does not
write or auto-discover Flow configuration. Configure Flow's named checks/model
in its operator config when using `:RoseFlow`.

## Opt-in cloud model APIs

The shared native router supports **OpenAI Responses/Chat**, **Anthropic
Messages**, **xAI Grok Responses/Chat**, **NVIDIA hosted inference or explicitly
configured local NIM**, and **Perplexity Agent/Sonar**. Sonar chat does not gain
custom Rose tools by being OpenAI-shaped; use Perplexity's Agent API for those.
Tool capability is an explicit per-model setting, not assumed for every model.
This is not a full NGC container/deployment client or a replacement for every
provider SDK.

**Enabling cloud mode sends task text, source context and tool output off the
device.** Both switches below are required; selecting a provider alone is not
consent. Setup/health never read API-key values or contact the service.

```lua
require("rose").setup({
  workspace = vim.fn.getcwd(),
  trusted = true,
  -- Also configure real lint/test checks as in the local example.
  providers = {
    enabled = true,
    allow_cloud = true,
    provider = "openai",
    openai = {
      api = "responses",
      endpoint = "https://api.openai.com/v1",
      model = "YOUR_CHOSEN_TOOL_CAPABLE_MODEL",
      key_env = "OPENAI_API_KEY", -- value read only when a request executes
      capabilities = { tools = true },
    },
  },
})
```

`RoseAsk` and `RoseAgent` use that selection; switching back to
`providers.provider="ollama"` restores local routing. The same required static
gate, reviewer approval, iteration limits and trust rules apply to cloud agents.
Private provider replay data stays in memory, not the visible transcript/report.

`require("rose").model_request(spec, callback)` additionally provides bounded
authenticated JSON requests and explicit raw SSE events for supported
provider-origin paths. Normalized chat remains non-streaming. Multipart upload
exists only for speech (below); binary media, realtime sessions and every other
provider-specific workflow are **not** claimed to be supported. See [provider configuration and API limits](docs/providers.md)
for exact endpoints, models, auth and local NIM settings.

## Optional speech (dictation and read-aloud)

Speech is off by default. `speech.enabled = true` allows local engines
(whisper.cpp server at `speech.whisper.url`, piper at `speech.piper.cmd`);
cloud speech additionally requires `providers.enabled` **and**
`providers.allow_cloud`, because recorded audio and spoken text leave the
device. Supported cloud providers are **OpenAI** (`gpt-4o-mini-transcribe`,
`gpt-4o-mini-tts`) and **xAI** (`/v1/stt`, `/v1/tts`); Anthropic and Perplexity
have no speech API and NVIDIA speech needs a self-hosted Speech NIM, so those
report unavailable with a reason. Recording and playback use an existing tool
(`pw-record`/`arecord`/`ffmpeg`, `pw-play`/`paplay`/`aplay`/`mpv`/`ffplay`) and
are bounded (`record.max_seconds`, `max_audio_bytes`, `max_text_chars`).
Temporary audio lives in `stdpath("cache")/rose/speech` and is removed after
use. There is no realtime/streaming audio. See [speech guide](docs/speech.md).

## Hugging Face models, datasets and paper assets

Install the optional official Python client in an environment you control:

```sh
python3 -m pip install huggingface_hub hf-xet
```

Then configure `hub.python` if that environment is not your default Python.
Transfers use the official cache, runtime-detected Xet support and bounded
parallelism, with conservative HTTP fallback where appropriate. Performance
depends on the files, cache, connection and service; there is no "fastest"
guarantee or automatic all-file repository download.

```lua
require("rose").setup({
  workspace = vim.fn.getcwd(),
  trusted = true, -- uploads require this plus exact-preview approval
  hub = {
    python = "/absolute/venv/bin/python",
    max_workers = 4,
    xet = "auto", -- or "disabled"
    high_performance = false,
  },
})
require("rose").hub_download({
  repo_id = "organization/model",
  repo_type = "model", -- or "dataset"
  revision = "main",
  files = { "config.json", "model.safetensors" },
  destination = "models/example", -- workspace-relative
  dry_run = true, -- metadata/cache/size preview, not a payload transfer
}, function(err, preview) vim.print(err or preview) end)
```

Omit `dry_run` to review and approve the exact selected transfer in native UI.
Uploads similarly require exact file paths, destination repository visibility,
revision and content hashes in a preview; no model, JSON boolean or default
configuration can approve them. Tokens are inherited/read by the official SDK
only during explicit execution, never put into argv or Rose configuration.
Stopping cannot undo already committed remote uploads.

These operations are **not model tools**. Core commands coordinate transfers
with the writing workflow lock; callers of the low-level `rose.hub` module own
their own concurrency. Paper metadata is capability-detected; uploading a PDF
as a Hub repository asset does not publish to arXiv or a journal. See the
[Hub guide](docs/huggingface.md) for upload/paper examples, Xet tuning, cache
boundaries and fallback behavior.

## Local web UI

Rose can serve a small browser front end from inside Neovim over plain HTTP on
the loopback interface. It is off by default: set `webui = { enabled = true }`
and run `:RoseWebUI`. The command prints (and, when `webui.open` is true, opens)
a URL of the form `http://127.0.0.1:PORT/?token=...`; the random per-session
token is required on every API call. The page is a single self-contained HTML
document using the Rose palette, with chat, Flow run, Dictate/Speak buttons
(available when `rose.speech` is installed), and a health drawer.

Boundaries: loopback only, no TLS, one Neovim instance per server, no
streaming, no persistence, no file serving. Limits (`max_request_bytes`,
`max_clients`, `idle_timeout_ms`) are configurable and validated. Chat goes
through the same provider path as `:RoseAsk`, so cloud consent settings apply.
See `docs/webui.md`.

## Optional editor capabilities

- **LSP:** native `vim.lsp` clients and `vim.diagnostic` snapshots; no automatic
  downloads or language-server setup. Configure/enable servers yourself. Missing
  capabilities return `unavailable`, not invented symbols or references.
- **Diver linting:** opt-in `diver={path="/path/to/diver",lsp={...}}`; project
  plugins are executable trust boundaries. Rose does not require Diver.
- **SCIP:** `scip={path="index.scip.json"}` reads explicitly decoded SCIP JSON.
  Raw protobuf `index.scip` is not interpreted as JSON. Generate/export an index
  with your language's external indexing tools.
- **Debug:** an optional plugin-free **stdio DAP probe**, not a full debugger UI.
  No `vim.debug` API is assumed. Install an adapter and configure named trusted
  launch settings; launch is manual and the model-facing debug tool allows only
  status queries. See [native reference](docs/native.md#debug-probes).

## Security and dependencies

`trusted` defaults to **false**. Trusted workspaces permit bounded file edits
and configured checks; this is **not an OS sandbox**. Tests, language servers,
debug adapters, Flow and configured MCP servers can execute code with your user
account's permissions. Native workspace tools reject outside-root paths and
symlink escapes; they do not confer trust on executable project code.

Ollama defaults to loopback; remote base URLs require explicit
`ollama.allow_remote=true`. No keys, password-store helpers or environment
secrets are read during setup to configure providers. Explicit cloud requests
look up only their configured environment-key name and use a restricted child
environment. Other subprocesses normally inherit the user environment; do not
run untrusted executables in an environment containing secrets.

The `auto` HTTP adapter uses safe argv + stdin through `vim.system`: ignores
curl configuration, does not follow redirects, bypasses proxies, and enforces a
deadline. The installed `vim.net.request` cannot enforce those controls yet,
so it is not automatically selected. Explicit `ollama.transport="native"` uses
the real API but **trusts local curl configuration and endpoint redirects**;
those may send traffic beyond the configured host. See `:help rose-http`.

A Neovim RPC socket gives **arbitrary editor-code access to other same-user
clients**, not just the allowlisted Flow tools. The private directory (0700)
and socket (0600) protect against other users, not malicious same-user processes.
Disable `flow.bridge` when this boundary is inappropriate.

Third-party MCP processes are never auto-started or implicitly trusted. They
require per-server `trusted=true`, `read_only=true`, and an exact `allow_tools`
list. Read-only is the operator's assessment, **not enforcement of a subprocess
sandbox**, and server annotations are not accepted as authorization. See the
[MCP example](docs/native.md#third-party-mcp).

**External binaries still needed:** Ollama + model and curl for local chat; installed
language servers/checkers/indexers for those features; Flow and optional pynvim
for integration; a configured DAP adapter for debug probes. No Rust/CMake build
is needed for native Rose. Optional Hub transfers need Python and
`huggingface_hub`; `hf-xet` supplies the Xet acceleration path. Cloud API calls
use curl and explicitly supplied environment credentials, not provider SDK plugins.

## Migration and tests

Old provider menus, fzf chat pickers, binary downloads and Rust helpers are not
part of the native path. Their historical files remain behind explicit
`legacy=true`; that snapshot has known defects and is not claimed to work on
nightly. See [migration guide](docs/legacy.md) before enabling it.

```sh
nvim --headless -u NONE -l tests/core.lua
# Run native core, tooling, DAP, Hub, provider, speech and web UI fixture suites together:
make test NVIM=nvim PYTHON=python3

# Real package managers, isolated from your Neovim config; no remote fetches:
make test-packages NVIM=nvim PYTHON=python3 LAZY_ROOT=/path/to/lazy.nvim

# Strict LuaCATS/LuaLS validation of runtime code and tests:
make typecheck-all NVIM=nvim LUALS=lua-language-server PYTHON=python3
```

`make test` includes the root lazy specification's command-completeness check.
`test-packages` requires an already installed lazy.nvim checkout and a Neovim
build with `vim.pack`; missing prerequisites fail rather than count as passes.
It installs Rose from a local Git source, overlays the current working tree
before loading, and tests both managers in isolated XDG directories. Nothing is
committed, and your real Neovim configuration is not changed.

`make test-speech` runs the offline speech suite against a loopback fixture that
emulates the OpenAI, xAI and whisper.cpp wire formats with fake recorder, player
and piper executables; it does not use a microphone or any live API.
`make test-webui` starts the loopback web UI in headless Neovim and exercises
token checks, request limits and every route with stubbed provider, Flow and
speech backends.

Core tests use local Python stdlib HTTP/MCP fixtures and a deterministic fake
model, exercising the real Neovim transport and subprocess APIs without a GPU.
They do **not** establish live Ollama/model quality, paid-provider availability,
or Hub transfer throughput. The default suite performs no remote uploads or
model downloads. Optional installed-language-tool and cross-repository Flow
integration tests provide separate coverage. See [native API reference](docs/native.md)
and `:help rose`.
