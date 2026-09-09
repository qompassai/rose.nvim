# Native Rose reference

## Public Lua API

```lua
local rose = require("rose")
rose.setup(opts) -- returns module on success, nil,error on invalid config
rose.ask("Explain this algorithm", function(err, text) end)
rose.agent("Add tests", function(err, report) end)
rose.check("unit", function(err, report) end)
rose.flow("Review this module", function(err, report) end)
rose.mcp("docs", "search_docs", { query = "API" }, function(err, mcp_result) end)
rose.model_request({ path = "/models", method = "GET" }, function(err, data) end)
rose.hub_download({ repo_id = "org/model", repo_type = "model", files = { "config.json" },
  destination = "models/example", dry_run = true }, function(err, preview) end)
rose.hub_upload({ repo_id = "org/model", repo_type = "model", files = { "assets/model.bin" } },
  function(err, report) end) -- exact preview approval still required
rose.hub_paper({ id = "2501.00001" }, function(err, metadata) end)
rose.stop()
rose.shutdown()
```

Operations return a token with `cancel()` when started. Error-first callbacks
receive actual failures, never a synthetic pass. Callbacks suppress the scratch
UI, making the API useful in automation. Prompt omission uses `vim.ui.input`.
Only one writing Agent/Flow run can be active in a Rose instance; planner and
reviewer are sequential and read-only. Independent Neovim/Flow processes are
outside this instance's lock.
The core Hub command/wrapper APIs also occupy the writing slot until their
operation completes/cancels; low-level direct module callers manage their own
concurrency. Hub transfers are never added to model tool schemas.

The reviewer returns the same canonical JSON shape as Flow:
`{"approved":boolean,"issues":[...],"summary":string}`. The earlier `findings`
field is accepted as an input alias for `issues`; invalid/prose verdicts remain
unverified. Rejection can trigger one bounded repair cycle by default. Reports
retain `attempts`, `review`, `changed_files` (also `changed_paths`) and the
host-owned `verification` evidence. `verified` mirrors the final gate and is
false on request errors.
Workspace snapshots (loaded-buffer identities/changedticks and observed saved
file hashes/stat evidence) are compared immediately after review. User edits,
including noncurrent saved-file edits, make prior evidence stale. These
snapshots cover observed paths and named buffers, not an implicit whole-repo scan.

Every affected path needs a successful applicable named check plus completed
static evidence: `editor_lint` must return `status="ok",verified=true`, or an
explicit matching named check must have `kind="lint"`, `"typecheck"` or
`"diagnostics"` and pass. A generic green test is not a substitute. Empty cached
diagnostics remain advisory; errors veto success. The gate records lint
completion results rather than inferring completion from empty diagnostics.

`rose.tools.setup(opts)` receives the same resolved configuration. Tools are
OpenAI function schemas from `.schemas()` and serializable objects from
`.call(name,args)`; failures have `status="error",error=...`. The native agent
only exposes an allowlisted subset of these schemas per role.

The standard editor tools are `editor_context`, `editor_diagnostics`,
`editor_symbols`, `editor_references`, `editor_lint`, `editor_check`, `editor_scip`
and `editor_debug`. File tools are `file_read`, `file_write`, `file_list`, using
relative paths. `editor_check` takes a configured `name` and optional `path`
to capture the correct saved-buffer/filetype context. There is no model-selected
shell command. Statuses include `ok`, `failed`, `unavailable`, `timeout`, `stale`,
`error` and `unverified`.

### Configuration

For every supported setup field, its precise LuaCATS type, default and purpose,
see the [complete configuration reference](configuration.md). The following is
a selection, not an exhaustive defaults table. Use `---@type Rose.Config` on
your partial options table with either vim.pack or lazy.nvim.

```lua
{
  workspace = "/absolute/project", -- default resolved cwd; no config discovery
  trusted = false,
  ollama = {
    base_url = "http://127.0.0.1:11434",
    model = "qwen2.5-coder:7b",
    timeout = 120000,
    allow_remote = false,
    transport = "auto", -- safe auto/curl; explicit native has trust caveats
    -- options = { num_ctx = 8192 }, -- optional Ollama model settings
  },
  providers = { enabled = false, allow_cloud = false, provider = "ollama" },
  hub = { python = "python3", max_workers = 4, xet = "auto", high_performance = false },
  agent = {
    max_iterations = 6, -- coder rounds, 1..30; planner/reviewer each <=2
    max_repair_rounds = 1, -- 0..3; coder/check/reviewer attempts = this + 1
    -- max_cycles = 1, -- Flow-compatible alias: 1 cycle means no repairs
    max_tool_calls = 8, -- per response, 1..32
    max_tool_result = 24000, -- bytes, truncated output explicitly marked
    max_context = 120000, -- bytes of model messages; overflow stops the run
  },
  checks = {
    python_lint = { cmd = { "ruff", "check", "--isolated", "." }, kind = "lint", filetypes = { "python" }, timeout = 30000 },
    unit = { cmd = { "python3", "-m", "unittest", "discover" }, filetypes = { "python" }, timeout = 60000 },
  },
  diver = { path = "/absolute/diver", lsp = {} }, -- optional; executable trust
  scip = { path = "index.scip.json" },
  debug = {}, -- optional named stdio DAP adapter/probe configurations
  flow = { cmd = { "flow", "serve" }, bridge = true, timeout = 600000 },
  mcp = { servers = {} },
  speech = { enabled = false }, -- dictation/read-aloud; see docs/speech.md
  webui = { enabled = false, host = "127.0.0.1", port = 0 }, -- loopback web UI; see docs/webui.md
}
```

Optional `speech` (`:RoseDictate`, `:RoseSpeak`, `:RoseSpeechStop`,
`:RoseSpeechStatus`) and `webui` (`:RoseWebUI`, `:RoseWebUIStop`,
`:RoseWebUIStatus`) sections are validated with the rest of the configuration
and stopped by `rose.stop()`/`rose.shutdown()`. Their full keys and limits are
documented in [speech](speech.md) and [web UI](webui.md).

Rose timeouts are milliseconds. Flow's own Ollama HTTP timeout is seconds.
Empty or omitted `checks.<name>.filetypes` means all filetypes. Omitted `kind`
is a generic check, not a claim of lint/type/diagnostic coverage. Install the
chosen check executables separately (the example uses Ruff and Python).
`max_cycles` is a Flow-compatible alias for `max_repair_rounds + 1`; if both
are supplied, explicit `max_repair_rounds` takes precedence.
No project configuration is sourced. `workspace` is resolved to a real existing
directory. Repeated setup cancels running operations, so make trust/config
changes between workflows.

Cloud selection requires explicit `providers.enabled=true`,
`providers.allow_cloud=true`, API, endpoint and model. `key_env` selects the
environment-variable name; its provider default is documented separately.
The native model router receives the full configuration; injected internal
agent test backends retain their historical `config.ollama` first argument.
Opaque normalized assistant replay data is preserved privately for provider
tool-call correctness, never copied into user-visible reports.
See [providers.md](providers.md) for the supported JSON/tool/SSE surfaces.
Hub setup receives only `hub` options plus the resolved top-level workspace and
trust, so a nested `hub.trusted` value cannot elevate the workspace's permission.
See [huggingface.md](huggingface.md) for exact file manifests and approval.

## Third-party MCP

```lua
require("rose").setup({
  mcp = {
    servers = {
      docs = {
        cmd = { "/absolute/path/to/known-docs-server", "--stdio" },
        trusted = true, -- authorization to execute this server program
        read_only = true, -- your assessment, not a sandbox or server hint
        allow_tools = { "search_docs" },
        timeout = 10000,
      },
    },
  },
})
require("rose").mcp("docs", "search_docs", { query = "API" }, function(err, result)
  vim.print(err or result)
end)
```

This API lazily starts an explicitly configured server. These third-party tools
are not automatically injected into the standalone agent's schema. No
project-provided executable is discovered and no server's `readOnlyHint` grants
permission. `isError=true` becomes a callback error while preserving the result.
MCP's protocol output must be stdout-only JSON lines; logs go to stderr.

### Low-level transport

```lua
local client = require("rose.native.mcp").start({
  cmd = { "flow", "serve", "--workspace", "/absolute/project" },
  cwd = "/absolute/project",
  timeout = 30000,
  initialize_timeout = 10000,
}, function(err, ready_client)
  if err then vim.notify(err); return end
  ready_client:list_tools(function(list_err, result) vim.print(list_err or result) end)
end)
-- client:request(method, params, callback, timeout) -> cancel token
-- client:call_tool(name, args, callback, timeout) -> cancel token
-- client:close()
```

Protocol version offered: `2025-11-25`; compatible supported negotiation dates:
`2025-06-18`, `2025-03-26`, `2024-11-05`. Unsupported dates fail initialization.
The client supports server `ping` but rejects other server requests with
JSON-RPC `-32601`. It does not grant sampling, roots, elicitation or editor-code
execution to a server. Request cancellation sends `notifications/cancelled`;
shutdown closes stdin and terminates the process, then escalates if necessary.
There is no invented MCP `shutdown` method.

## Debug probes

The `rose.debug` adapter uses native `vim.system` and DAP stdio
framing. This is a bounded launch/breakpoint/stack/stop probe, not an interactive
debugger, variable explorer or plugin replacement. It assumes no native
`vim.debug` API.

For an explicitly trusted Python project with debugpy installed:

```lua
require("rose").setup({
  workspace = "/absolute/project",
  trusted = true,
  debug = {
    adapters = {
      python = { cmd = { "python3", "-m", "debugpy.adapter" } },
    },
    configurations = {
      probe = {
        adapter = "python",
        launch = { program = "${workspaceFolder}/main.py", console = "internalConsole" },
        breakpoints = { ["main.py"] = { 10 } },
        timeout = 30000,
      },
    },
  },
})
vim.print(require("rose.tools").call("editor_debug", { action = "status" }))
-- Execution is explicit and requires trusted configuration:
vim.print(require("rose.tools").call("editor_debug", { action = "run", name = "probe" }))
```

Adapters/debuggees are arbitrary local code outside an OS sandbox; adapter
installation and named launch configuration are the operator's responsibility.
Missing/failed/timed-out adapters return explicit status, not a debugging pass.
The model-facing debug schema is narrowed to `action="status"` and a call-time
guard rejects model-triggered launch even if the model ignores the schema.
Run probes manually through the explicit Lua API.

## HTTP capabilities

This build's API is `vim.net.request(method,url,{body,headers,retry},callback)`,
where the callback receives `(err,{body=...})` and the returned handle has
`close()`. Rose tested that actual signature, HTTP callbacks and cancellation.

This implementation invokes curl with redirects enabled and reads curl's local
configuration, without a supported option to turn those off. Therefore safe
`auto` cannot choose it merely because the function exists. `auto` and `curl`
use argv-only `vim.system` with `--disable`, `--noproxy '*'`, HTTP(S)-only
protocols, no redirects, JSON body on stdin, and a deadline. Explicit `native`
selects the real API only when you trust those extra transport boundaries.
Neither mode is a built-in TLS/HTTP engine independent of curl on this nightly.

## Testing scope

`nvim --headless -u NONE -l tests/core.lua` uses only Neovim, Python 3 stdlib
fixtures and curl. It covers real subprocess MCP lifecycle, actual `vim.net`
and fallback HTTP, role boundaries, required checks, source-path coverage,
private Flow socket creation and cleanup, and default dependency isolation.
No live Ollama model, GPU or cloud service is used. Tooling tests and the
cross-repository Flow/pynvim roundtrip harness provide additional integration
coverage; DAP tests are separate under `tests/integration_dap.lua`.

`make test NVIM=nvim PYTHON=python3` runs core, tooling, DAP, Hub, provider,
speech and web UI offline suites without Plenary or a plugin manager. Hub
fixtures perform no remote writes or model downloads; provider and speech
fixtures use a loopback HTTP server and fake credentials, not paid APIs; the web
UI suite talks to the loopback server from a Python client. Optional `make test-live` checks installed
language tooling; configure the executables and `DIVER_ROOT` as documented by
that test. Historical Plenary tests require the explicit `make test-legacy`
target and are not part of native verification.
