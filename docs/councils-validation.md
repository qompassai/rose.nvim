s/docs/councils-validation.md
# Council/workflow patch verification



## Results

| Check | Result |
| --- | --- |
| Baseline strict whole-repository LuaLS | Passed: 98 files, zero diagnostics |
| Final strict whole-repository LuaLS | Passed: 102 files, zero diagnostics |
| `make test-workflows` | Passed: 11 tests |
| `make test-package-spec` | Passed: static lazy command completeness |
| StyLua check for every changed/new Lua file | Passed |
| `git diff --check` | Passed |
| `make -k test` | Nonzero: four core failures described below |

The new regressions cover actual overlapping asynchronous requests; ordered DAG
results; dependency barriers; proposals/peer critiques/chair routing; invalid graph
and provider preflight; dependency failure propagation; duplicate/late callbacks;
once-only cancellation; whole-run deadlines; four-workflow admission; aggregate
request limits; writer waiting; oversized outputs; rejection of model tool calls;
public command/shutdown lifecycle; model selection and captured editor context;
real Rose writer-entrypoint serialization; and rejection of unverified agent reports.

The final type check initially found optional-result accesses in the new tests.
Those were fixed with explicit assertions before access, then the entire strict
check was rerun successfully. No diagnostics were suppressed and no library,
file-status, type, or workspace strictness settings were weakened.

## Existing broader-suite failures

All four failures also appeared in the pre-change `test-core` baseline:

1. `safe auto HTTP and actual vim.net request signatures work`: the installed
   Neovim `vim.net` API rejects the existing transport's argument signature
   (`opts: expected table, got string`).
2. `Flow passes private native bridge workspace and trust flags`: this host
   rejects the native editor socket with `operation not permitted`.
3. `Flow timeout confirms process exit before completing`: affected by the
   unavailable editor bridge; the fixture misses its callback deadline.
4. `Flow cancellation retains writer ownership until server exit`: the Flow
   process/socket fixture cannot initialize as expected here.

The broad run reported 35 passing core tests and those four failures. Other
suites passed: tooling (91 assertions), DAP (10), Hub Python (27), Hub native (19),
providers (26), speech (39), web UI (20), native nil safety (38), checker-driver
Python regressions (9), legacy nil safety (47), and package command completeness.
The focused new tests were rerun after final test nil-safety/formatting corrections
and the scheduler timer helper extraction; all 11 still pass. The broad suite was
not unnecessarily repeated after those scoped corrections.

These results do not certify live provider endpoint compatibility, model quality,
consensus accuracy, simultaneous GPU capacity, external Flow installations, or
cross-process file locking.

## Scope notes

The existing `register_commands` function remains over the repository's 70-line
function target; its surgical additions register the new commands. The existing
larger entrypoint structure was preserved to avoid an unrelated registration
refactor. New runtime orchestration functions stay within the target after
extracting the timer scheduling helper. No performance speedup is claimed.

## Reproduce locally

Use installed executable paths via the Makefile variables if necessary:

```sh
make test-workflows test-package-spec NVIM=nvim PYTHON=python3
make typecheck-all NVIM=nvim LUALS=lua-language-server PYTHON=python3
make -k test NVIM=nvim PYTHON=python3
stylua --check --config-path .stylua.toml --syntax LuaJIT \
  lua/rose/native/selection.lua lua/rose/native/workflow.lua \
  lua/rose/native/council.lua lua/rose/init.lua lua/rose/types.lua \
  tests/workflows.lua lazy.lua
git diff --check
```