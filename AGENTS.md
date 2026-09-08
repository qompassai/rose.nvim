# Rose Agent Guidelines

Read this file before editing and the relevant `SKILLS.md` procedure before verification.
Follow the current task and scoped instructions; this policy grants no extra execution trust.
Do not require Flow or Diver for unrelated Rose development.

## Think before coding

- Inspect relevant code, branch, dirty files and tools. State material assumptions and
  tradeoffs. Ask when ambiguity would change behavior or scope; never choose silently.
- Define observable goals and non-goals. Give a short step-to-check plan for multi-step
  changes. Reproduce bugs first; verify a refactor before and after.
- Suggest simpler approaches when warranted. Keep trivial tasks lightweight.

## Simplicity and surgical changes

- Implement only the requested behavior with minimum code. No speculative features,
  dependencies, single-use frameworks, configurability or impossible-case handling.
- Preserve public APIs, commands, configuration keys, wire formats and unrelated work.
  Every changed line must serve the task. Do not reformat or refactor adjacent code.
- Remove only dead code created by the patch. Report pre-existing debt without deleting it.

## Tiger Style and performance

- Prioritize correctness/safety, performance, then convenience. Prefer native Neovim APIs,
  simple control flow and small scopes. Introduce no recursion.
- Bound input, buffers, output, queued work, retries and time with named limits and units.
  Long-lived event loops need bounded batches, cancellation and backpressure.
- Assert meaningful internal invariants. Validate untrusted inputs explicitly and handle
  real missing-file/tool, I/O, timeout and cancellation errors without false success.
- Own handles/timers/processes explicitly and clean up exactly once on every terminal
  path. Recheck buffer identity, freshness and handle lifetime after async suspension.
- Target changed functions at most 70 physical lines. Preserve `.stylua.toml`:
  two spaces, preferred double quotes and 100 columns. Report scoped exceptions instead
  of minifying code or destabilizing a state machine to meet a count.
- Bound managed-runtime growth; do not claim allocation-free Lua. Avoid blocking editor
  callbacks, unnecessary copies and dependencies. Benchmark before claiming speedups.
- Use targeted reads/tests and disjoint file ownership. After two failed attempts at the
  same hypothesis, investigate or escalate with evidence instead of blindly repeating.

## Strict Lua and nil safety

- Use the strict type/diagnostic contract from
  [Diver LuaLS](https://github.com/qompassai/Diver/blob/main/lsp/lua_ls.lua) and LuaJIT
  parsing from [Diver StyLua](https://github.com/qompassai/Diver/blob/main/lsp/stylua_ls.lua).
  Preserve Rose formatting rather than migrating to the LSP's differing style defaults.
- Keep `weakNilCheck=false`, `weakUnionCheck=false`, `checkTableShape=true`,
  `castNumberToInteger=false`, `inferParamType=true`, type-check Error and
  `undefined-field` Error. Batch type checks must use file status `Any`, not `Opened`.
- Narrow optional results before access: `io.open`, `loadfile`, uv allocation/stat calls,
  missing modules/files, config fields, decoded JSON and asynchronously cleared state.
  Validate shapes as well as non-nilness; preserve error information.
- No blanket `any`, blind casts, diagnostic suppression or fabricated defaults to pass.
  A missing optional dependency returns unavailable/errors; a programmer invariant
  remains an assertion. Do not turn expected operating failures into assertion crashes.
- Keep native mode plugin-independent. Do not silently initialize the user's full Diver
  configuration or require legacy plugins for native functionality.
- Preserve workspace/trust boundaries, provider consent, private/loopback defaults,
  key-at-request-time behavior, bounded transfers and cancellation.

## Verify and hand off

Run focused tests then affected static/integration gates on the final patch. Record
commands, tool versions, coverage, exit results and skips. Separate behavior, strict
diagnostics, formatting and performance. Re-run affected gates after edits.
Empty cached diagnostics, missing libraries and excluded files are not a full pass.
Never suppress diagnostics or remove tests to make results green.

For substantive work with explicitly selected Astra6/Fable5.1, also provide `HANDOFF.md`
and reusable `AGENTS.md`/`SKILL.md` text: exact files/APIs, contracts, bounds, ordered
steps, failure cases, tests and stop rules. Do not infer model identity, promise model parity
or commit additional handoff artifacts unless requested.

This policy adapts the user's
[Karpathy-inspired guidelines](https://github.com/forrestchang/andrej-karpathy-skills/blob/main/CLAUDE.md)
and [Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
