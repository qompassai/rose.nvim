# Strict Lua validation

## Commands

Install Neovim, LuaLS, Python 3 and StyLua locally, then run from the repository:

```sh
make typecheck
make typecheck-all
make test-nil-safety
make test-legacy-nil-safety
make test DIVER_ROOT=/path/to/Diver
```

Override `NVIM`, `LUALS`, `PYTHON` and `STYLUA` with executable paths when they are
not on `PATH`. These commands do not install tools or download LuaLS addons.

`typecheck` gates **all runtime Lua**, including legacy code, extensions and
root-level Lua configuration. `typecheck-all` also gates tests and scripts.
Both commands always check the whole repository; the default gate excludes only
diagnostics under `tests/` and `scripts/`. Neither command suppresses those
diagnostics: the complete report and both scope counts are saved and printed.
**Every finding, including Warning, Information and Hint, fails its selected
gate**, not just Error.

To choose a persistent evidence directory:

```sh
NVIM=nvim LUALS=lua-language-server \
  python3 scripts/check_lua.py --scope all --output /tmp/rose-lua-check
```

The driver saves `settings.json`, `files.json`, `diagnostics.json`, `summary.json`,
`console.log` and LuaLS logs. Otherwise it creates a fresh temporary evidence
directory and prints its location.

## Profile origin and deliberate adaptations

`.luarc.json` snapshots the diagnostic, type, runtime and workspace settings from
[Diver's `lsp/lua_ls.lua` at `d8eabd5`](https://github.com/qompassai/Diver/blob/d8eabd5/lsp/lua_ls.lua).
The complete disable list, globals,
individual severities, group severities and needed-file statuses are preserved,
including upstream's `unused-varar` spelling. No diagnostic was added to the
disable list to make Rose pass.

Required type settings remain:

| Setting | Value |
| --- | --- |
| `type.weakNilCheck` | `false` |
| `type.weakUnionCheck` | `false` |
| `type.checkTableShape` | `true` |
| `type.castNumberToInteger` | `false` |
| `type.inferParamType` | `true` |
| `type.inferTableSize` | `200` |
| `diagnostics.groupSeverity.type-check` | `Error` |
| `diagnostics.severity.undefined-field` | `Error` |

Runtime is `LuaJIT`, UTF-8, with paths `lua/?.lua` and `lua/?/init.lua`;
`pathStrict` and `unicodeName` remain false. The upstream nonstandard symbols
`//`, `/**/` and `continue`, and the metadata template, are retained.

The batch profile changes only `diagnostics.groupFileStatus.type-check` from
`Opened` to `Any`. This is **stronger coverage**, not a relaxation: closed files
must not escape type checking. LuaLS 3.19.1's `--check` implementation itself opens
the enumerated files, but the persistent profile does not rely on that detail.

Diver's machine-specific workspace libraries are replaced with the runtime of
the selected clean Neovim (`-u NONE`). No user config is loaded. Current Neovim
supplies `lua/uv/_meta.lua`, including nullable UV constructors and filesystem
returns; older runtimes without that file use LuaLS's locally installed
`${3rd}/luv/library` instead. Do not load both UV libraries together.

Workspace limits remain 5,000 preloaded files and 500 KiB per file. Git ignores,
submodule exclusion, and ignored directories `build`, `node_modules`, `.vscode`
remain as in Diver. Ignored files and library files are not diagnosed. The driver
refuses an empty scope, oversized files or excessive file counts instead of
claiming a truncated pass. Repository Lua files are enumerated through Git
(tracked plus nonignored untracked files), and their count must match LuaLS's
final completed `N/N` count.

The driver additionally requires the expected process exit status, the completed
diagnosis message and a newly generated JSON report. Missing, stale, partial or
unexpected-exit results cannot pass. Runtime discovery and Git commands have
15-second deadlines; LuaLS has a 120-second process-group deadline. Python tests
exercise these failure paths. LuaLS's human-readable completion message is
version-sensitive: an unsupported output format fails closed, not green.

Editor-only LuaLS formatting, completion, hover, spelling and Hyprland attach
settings are not copied into Rose's batch validation profile.

## Preserve Rose formatting

The semantic flags follow
[Diver's `lsp/stylua_ls.lua` at `d8eabd5`](https://github.com/qompassai/Diver/blob/d8eabd5/lsp/stylua_ls.lua):

```sh
stylua --search-parent-directories --respect-ignores --sort-requires \
  --syntax=LuaJIT --check lua/rose/native
```

Rose's `.stylua.toml` remains authoritative: **2 spaces, AutoPreferDouble quotes,
Unix newlines, 100 columns**. Do not import Diver's tabs, forced single quotes or
120-column editor defaults. The configuration now explicitly selects LuaJIT and
sorted requires. `make format` retains its existing native-code target list and
applies these flags; it is not a whole-repository formatter gate.

Legacy files already contain four-space indentation and overlong lines. This
audit does not reformat entire unrelated legacy bodies. Use range formatting or
format the edited native files, and report baseline formatting differences rather
than describing a partial formatter check as a repository-wide pass.

StyLua 2.5.2's `--verify` may report AST differences when `--sort-requires`
reorders imports. Inspect those require-only diffs separately, then run the
ordinary `--check`; do not mistake that verification message for a LuaLS error.

## Nil boundaries and regression scope

New offline tests cover vanished filesystem entries, failed reads/writes, JSON
shape validation, unavailable optional modules/registries, UV timer/TCP creation,
missing native HTTP handles/responses, accepted-socket failures and callback
completion/cleanup. Audio tests use fake executables/processes and never activate
a microphone. Provider and Hub fault tests do not contact a cloud service.

Ordinary operating failures use the existing return/callback error path.
Assertions remain for configuration/API preconditions and proven invariants;
integer annotations describe actual Neovim IDs and line indices. Numeric casts
are used only after range/integrality checks, not to bypass nullable outcomes.

The legacy extension referenced nonexistent `rose.utils.ui`; argument collection
now uses `vim.ui.input` and its cancellation callback. This uses the installed
native UI provider rather than promising a missing multiline widget. Legacy
Plenary/CodeCompanion integrations still require their documented dependencies;
the strict type pass does not prove those external integrations work.

`make test-legacy-nil-safety` runs isolated legacy regression cases with stubbed
plugin dependencies and no network access. It is included in `make test`, but
does not claim compatibility with actual third-party plugins.

`make test` runs offline native and isolated legacy regressions, not the
historical real-Plenary `make test-legacy` suite. Optional installed-executable
integration checks are:

```sh
make test-live DIVER_ROOT=/path/to/Diver \
  ROSE_TEST_LSP=/path/to/basedpyright-langserver ROSE_TEST_RUFF=/path/to/ruff
make test-dap ROSE_TEST_DEBUGPY=1 PYTHON=/path/to/python
```

No live model, cloud API, microphone or automatic package installation is needed
for this validation.
