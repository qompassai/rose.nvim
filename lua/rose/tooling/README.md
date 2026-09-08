# Native tooling bridge API

This directory is the additive native bridge; it does not load legacy Rose plugins,
Diver's top-level configuration, or Diver's DAP setup. Neovim 0.11+ native APIs are
required for `vim.system`, native LSP configurations, and UTF position conversion.

## Rose boundary

```lua
local tools = require('rose.tools')
tools.setup({
  workspace = '/absolute/project',
  trusted = true, -- false by default: disables writes, checks, lint and debug probes
  diver = {
    path = '/absolute/diver',
    lsp = { 'lua_ls' }, -- optional, explicit native config names only
  },
  checks = {
    tests = { cmd = { 'python3', '-m', 'unittest', 'discover' }, timeout = 30000 },
    lua = { cmd = { 'luacheck', '.' }, filetypes = { 'lua' } },
  },
  scip = { path = 'index.scip.json' },
})
local openai_tools = tools.schemas()
local result = tools.call('editor_check', { path = 'src/example.lua' })
```

`schemas()` returns OpenAI function tools. `call(name, args)` is synchronous,
bounded, and returns only JSON/msgpack-serializable data. Unknown tools, unknown
arguments, invalid types and path violations return `{status='error', error=...}`.
It does not accept model-supplied Lua, Ex, shell commands, executable arguments,
or arbitrary check commands.

All editor tools accept optional workspace-relative `path`; omitted means the
buffer captured at call entry. `editor_check({})` aggregates the configured checks
relevant to that filetype, and `editor_check({name='tests',path='...'})` runs one.
Omitted **or empty** `filetypes` applies to every filetype. No relevant check means
`unavailable`, not pass. `editor_context().checks` lists names, relevance,
executable availability, and `runnable`. Capture/pass the original path if a chat
UI changes the current buffer before verification.

### Workspace freshness contract

`editor_context().dirty_buffers` lists **all** modified named workspace buffers,
not just the current one. `workspace_snapshot_version=1` identifies a stable
`workspace_snapshot` object keyed by canonical relative path:

```lua
{
  ['src/example.py'] = {
    path = 'src/example.py',
    buffers = { { bufnr = 12, changedtick = 17, modified = false, loaded = true } },
    disk = {
      exists = true, type = 'file', size = 123, ino = 456, dev = 789,
      mtime = { sec = 1, nsec = 2 }, ctime = { sec = 1, nsec = 2 },
      sha256 = '...',
    },
  },
}
```

This covers normal named workspace buffers and paths explicitly observed through
file read/write, context, or check calls—not a recursive repository scan.
Buffer identities are sorted. Missing files use `disk={exists=false}`; oversized,
unreadable or non-UTF8 files retain stat evidence with `hash_status='unavailable'`.
The snapshot excludes atime, wall-clock timestamps and current-window state.
Callers should compare snapshots with `vim.deep_equal` or JSON-dictionary equality
across checks and reviewer inference, invalidating final verification on any
difference or missing required freshness fields. Saved edits still change disk
hash/stat evidence or a buffer's changedtick even when `modified=false`.

`editor_check` performs this comparison itself and returns its baseline snapshot.
Its completion wait processes scheduled editor events; it does not use the
fast-event-only `SystemObj:wait()` path that can defer edits until after checking.

Tools:

- `editor_context`: dynamic native filetype, attached LSP capabilities, lint and
  check discovery, SCIP and debug capabilities. Config filenames are discovery,
  never evidence of an installed executable.
- `editor_diagnostics`: native diagnostic snapshot, `verified=false` always.
  Errors are `failed`; even an attached client with no diagnostics is `unverified`.
- `editor_symbols`: synchronous document-symbol requests to capable live clients.
- `editor_references`: input `line` is 1-based, `column` is a 0-based UTF-8 byte
  offset. Each client receives its own encoding. Returned LSP ranges remain
  0-based in that client's `encoding`. External-workspace locations are omitted.
- `editor_lint`: configured Diver linters only; completed exit/parser results,
  not a diagnostic-count polling heuristic. `timeout` is the total deadline.
- `editor_check`: explicit user-configured argv through `vim.system`; no shell
  interpolation. Unsaved workspace buffers make disk checks `stale`.
- `editor_scip`: `action='status'|'symbols'|'query'`; literal `query` substring or
  exact `symbol`, optional document `path` and bounded `limit`. Only decoded JSON
  is read; protobuf `index.scip` is unavailable. Document encodings and ranges are
  preserved; missing encodings are unspecified. Local symbols are scoped to each
  document. Static index freshness/completeness is never verified.
- `editor_debug`: read-only loaded Diver registry discovery, with no calls to
  guessed `vim.debug` methods. If the separate `rose.debug` module is available,
  calls and setup are forwarded to it; that module owns optional explicitly named,
  trusted native DAP probes (`action='run'`, `name=...`). Debug is never test proof.
- `file_read`: text from an existing live buffer (including unsaved edits), else
  disk; includes SHA-256, source, and optional changedtick.
- `file_write`: trusted atomic replacement, with optional `expected_sha256` and
  `expected_changedtick`. Refuses unsaved, read-only, stale, BOM/non-UTF8 loaded
  buffers and missing parent directories. Updates already loaded clean buffers.
- `file_list`: bounded, one directory only; unsafe symlinks are omitted.

Read-only LSP tools do not open arbitrary files or start servers on demand: no
attached capable client means `unavailable`. Explicit lint of an unopened file
loads only that text into a buffer without BufRead/FileType events or modelines.
Selected native `diver.lsp` names may be enabled at setup only with trust. Existing
native user configurations are not replaced. No other LSP configs are evaluated.

`ok` for a completed check means only that selected checker completed cleanly; it
is not a proof of overall program correctness. Partial/missing/failed/timed-out,
cancelled, superseded and changed-buffer checks never become verified. LSP symbol
or reference success is observational and carries `verified=false`.

## Additive Diver lint embedding/completion API (version 1)

Existing `require('linters')`, registration, setup and boolean `run_linter` return
behavior remain compatible. The following additions are optional:

```lua
-- Explicit embedding skips eager definitions, updater and user setup.
local runner = assert(loadfile('/absolute/diver/lua/linters/init.lua'))({
  lazy = true,
  no_updates = true,
})
assert(runner.completion_api_version == 1)
local definition = runner.get_definition('luacheck') -- lazy, named definition only
local started, handle = runner.run_linter('luacheck', bufnr, {
  automatic = false,
  notify = false,
  timeout = 5000,
  root = '/absolute/project',
  validate_context = function(context, argv, cwd)
    return true -- caller must enforce its own workspace policy
  end,
  on_complete = function(result)
    -- Exactly one terminal result, even if rejected, cancelled, superseded,
    -- timed out, parser fails, or buffer changes.
    -- status, name, bufnr, verified; optional exit_code, signal, changedtick,
    -- diagnostics, namespace, stdout/stderr (bounded), reason.
  end,
})
if handle then handle.cancel('timeout') end -- only this run, not unrelated jobs
```

`root` supplies the context root/cwd before definition functions execute;
`validate_context` runs before spawning and must return exactly true.
`timeout` overrides the definition deadline for that run only.
The completion callback runs synchronously for immediate rejection, otherwise on
Neovim's scheduled event loop after parsing/publishing. Cancellation is idempotent.
A parsed diagnostic array plus zero process exit is required for a clean result;
an accepted nonzero exit with no diagnostics remains `unverified`.

Rose reuses an already loaded `linters` registry without calling `setup`, or uses
the explicit embedding mode only if the version marker is present. An older
runner without completion support is unavailable rather than guessed complete.
The runner's configured filetype map and user's enabled/disabled state are honored.

## Security and limits

Tool file paths are relative; parent traversal, absolute paths, NUL/backslashes,
escaping/dangling symlinks and non-directory parents are rejected. Existing parent
components are resolved even when later descendants do not exist. Reads/writes
recheck canonical paths; atomic replacement does not modify hard-linked aliases.
No project-local configuration is sourced. Trusted executable checks/linters and
explicit Diver configuration are executable code, **not an OS sandbox**; they may
access files or execute project code independently of the file-tool boundary.
Portable libuv path operations are not protection against a hostile same-user
process racing filesystem renames; use OS isolation for that threat model.

Text input is bounded to 1 MiB by default (`max_file_bytes`, capped at 16 MiB).
Binary text containing NUL is unsupported; large decoded SCIP indexes therefore
need an explicit size increase or an external index service. Check/lint captured
stdout/stderr are capped at 64 KiB each. Check aggregate deadline defaults to
120 seconds (`check_timeout`); individual default is 30 seconds. LSP queries use
one shared deadline, default 5 seconds, and preserve captured buffer changedtick.

## Tests

```sh
nvim --headless -u NONE -l tests/tooling.lua /absolute/diver
DIVER_ROOT=/absolute/diver \
ROSE_TEST_LSP=/path/basedpyright-langserver \
ROSE_TEST_RUFF=/path/ruff \
nvim --headless -u NONE -l tests/tooling_live.lua
```

The first suite uses deterministic local subprocesses and encoding-aware mock
clients; it needs only native Neovim and Python 3. The optional live suite uses
real basedpyright and real Ruff through Diver's actual completion runner. Missing
optional executables are reported as skips, not successful verification.
