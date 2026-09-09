# Rose Engineering Playbook

This plural `SKILLS.md` is a repository playbook referenced by `AGENTS.md` and `CLAUDE.md`,
not an automatically installed Agent Skill. Use only the applicable section.
Resolve tool paths on the current machine; do not assume the author's workspace exists.

## Native change or nil-safety fix

1. Inspect the affected function, caller and contract. Record baseline diagnostics and behavior.
2. Add an isolated regression for the real failure: missing file/module, nil uv result,
   malformed input, timeout, cancellation or stale state as appropriate.
3. Apply the smallest fix. Narrow optionals before access; validate external shapes and
   preserve original error information. Own resources and clean up exactly once.
4. Run the focused test and affected formatter/strict LuaLS/integration checks.
5. Review the final diff and report exact scope, results, skips and unresolved diagnostics.

With the required tools already installed, run from the repository root:

```sh
make test NVIM=nvim PYTHON=python3
git diff --check
```

Select the focused target from `Makefile`: `test-core`, `test-tooling`, `test-dap`,
`test-hub`, `test-rose`, `test-providers`, `test-speech`, `test-webui`, `test-nil-safety`
or `test-legacy-nil-safety`. The last target uses isolated plugin stubs, not the
historical real-Plenary suite.
Supply actual executable paths
for `NVIM` and `PYTHON` when needed. Python fixture dependencies must be available in
the selected environment. Native tests do not require the historical Plenary suite.

## Strict Lua and formatting

Read `.luarc.json`, `scripts/check_lua.py` and `docs/lua-validation.md`.
Use the reproducible gates rather than substituting a weaker default LuaLS run:

```sh
make typecheck NVIM=nvim LUALS=lua-language-server PYTHON=python3
make typecheck-all NVIM=nvim LUALS=lua-language-server PYTHON=python3
```

`typecheck` gates runtime Lua, including legacy modules; `typecheck-all` gates the whole
repository, including tests. The driver checks the whole repository in both cases and
retains full diagnostics. A runtime-only pass must not be described as a whole-repo pass.
The source strictness is
[Diver's LuaLS profile](https://github.com/qompassai/Diver/blob/main/lsp/lua_ls.lua):

```text
runtime.version = "LuaJIT"
type.weakNilCheck = false
type.weakUnionCheck = false
type.checkTableShape = true
type.castNumberToInteger = false
type.inferParamType = true
diagnostics.groupSeverity["type-check"] = "Error"
diagnostics.severity["undefined-field"] = "Error"
diagnostics.groupFileStatus["type-check"] = "Any"  # batch override of Opened
```

Preserve diagnostic settings and resolve Neovim/luv libraries on the actual machine.
Confirm the checker completed and record covered files; report native, tests and legacy
scope separately when needed. Missing libraries and unresolved baseline errors must be
reported, not hidden with exclusions, blanket `any`, blind casts or disabled diagnostics.

For a selected Lua file, set `FILE` to its actual repository-relative path:

```sh
stylua --check --config-path .stylua.toml --syntax LuaJIT "$FILE"
```

Keep Rose's two-space/preferred-double-quote/100-column format. LuaJIT parsing follows
[Diver's StyLua profile](https://github.com/qompassai/Diver/blob/main/lsp/stylua_ls.lua),
but its differing tabs/single-quotes defaults do not authorize a formatting migration.
StyLua verifies formatting/parsing, not nil safety or type correctness.

## Optional integrations

Use offline fixtures for providers, speech, web UI and protocol boundaries. Do not enable
microphone recording, send private data, call paid APIs or download models for routine tests.
Label fixture-only validation honestly.

If changing Diver integration, supply an actual authorized `DIVER_ROOT` to `test-tooling`.
For installed real language tools, use executable paths, not `1`:

```sh
ROSE_TEST_LSP="$(command -v basedpyright-langserver)" \
ROSE_TEST_RUFF="$(command -v ruff)" \
  make test-live NVIM=nvim DIVER_ROOT="$DIVER_ROOT"
```

Check both executables exist before running; empty variables may skip coverage.
Missing optional integrations remain explicitly unverified. No Flow/Diver installation
is required for unrelated native Rose work.

## Model-transfer packet

For substantive Astra6/Fable5.1 work or requested delegation, provide revision, allowed
files, verified APIs, goal/non-goals, nil/error contracts, limits, ordered steps, failure
cases, commands and expected behavior. Separate observed evidence from expected output.

The receiver verifies the revision, executes one bounded step and runs its gate.
It stops for stale context, conflicting contracts or missing permissions instead of
inventing APIs, weakening diagnostics or expanding scope. Reusable lessons need a trigger,
procedure, concrete failure/remedy and acceptance condition.
