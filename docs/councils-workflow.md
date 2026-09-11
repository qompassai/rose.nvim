# Model councils and asynchronous workflows

## Review of the original plugin

Reviewed `main` at `b65a2b8` (`feat: document package installs and type native configuration`).

| Capability | Before this patch |
| --- | --- |
| Multiple provider adapters | Yes: local Ollama and opt-in cloud adapters |
| Async provider requests with cancellation | Yes |
| Planner, coder, reviewer roles | Yes, sequential, using one selected model configuration |
| Required host validation and bounded repairs | Yes |
| Concurrent file-changing agent runs | Explicitly rejected by the entrypoint's writer lease |
| Independent multi-model proposals and cross-review | No built-in council |
| Dependency-based concurrent task workflows | No native scheduler |

The evidence is in `lua/rose/native/agent.lua` (`resolve_runtime`, `run`),
`lua/rose/native/model.lua` (model routing), and `lua/rose/init.lua` (`operation`,
`ask`, `agent`). Provider `parallel_tool_calls` options describe wire behavior;
they are not a multi-agent scheduler. Flow is an external integration, not an
in-plugin council implementation. This implements the council behavior requested;
it does not claim to reproduce the private internals of Odysseus or Perplexity.

## Configure a council

Use at least two distinct installed model IDs. The names below are examples;
check `ollama list` and replace them with models available on your machine.
Rose never downloads models or contacts providers during setup.

```lua
require("rose").setup({
  workspace = vim.fn.getcwd(),
  trusted = false,
  council = {
    members = {
      { provider = "ollama", model = "qwen2.5-coder:7b" },
      { provider = "ollama", model = "llama3.1:8b" },
    },
    chair = { provider = "ollama", model = "qwen2.5-coder:7b" },
    max_parallel = 2,
    timeout_ms = 600000,
  },
})
```

Run:

```vim
:RoseCouncil Compare these two designs and identify failure modes: ...
:RoseWorkflows
:RoseWorkflowStop 1
```

`RoseCouncil` with no argument prompts for the question. `RoseWorkflows` shows
active IDs and task states. `RoseWorkflowStop <id>` cancels one run. `RoseStop`
and shutdown cancel all runs using Rose's normal cancellation path.

For N members, a successful council makes **2N + 1 model requests**:

1. Independent proposals, without seeing other proposals.
2. Each member critiques the other members' proposals; its own proposal is
   excluded from its review input. Reviews become eligible when their peers
   have finished; they do not share other reviewers' outputs.
3. The explicitly selected chair sees every proposal and critique and produces
   a synthesis that identifies unresolved disagreements and uncertainty.

A failed member blocks any dependent review or synthesis. Independent branches
can finish, and the callback still receives a partial report. There is no
silent fallback to a smaller council. More models increase requests and local
memory/GPU demand or cloud costs; concurrency does not promise faster inference.
The model server determines actual hardware parallelism.

Councils have **no tools** and do not automatically read the current buffer,
files, or chat history. Include the context you intend to share in the prompt.
Member outputs are passed to peers and the chair as untrusted evidence. A
council's successful completion is not proof of correctness: `verified` remains
`false`, and model agreement never bypasses host checks.

## Lua council API

```lua
local rose = require("rose")
local handle = rose.council("Review the following algorithm: ...", function(err, report)
  if err then
    vim.notify(err, vim.log.levels.ERROR)
    -- report may still contain completed proposals/reviews.
    return
  end
  local synthesis = report.tasks[#report.tasks]
  vim.notify(synthesis.text)
end)
-- handle.id identifies the active run; handle.cancel() cancels just this run.
```

An optional third argument supplies `{ members, chair, max_parallel, timeout_ms }`
for this call instead of the configured council. Missing/invalid options fail
before inference. There is no default council silently calling your current
model several times.

## Concurrent workflows

The public API is `rose.workflow(spec, callback)`. Tasks must appear in
**topological order**: dependencies name unique earlier IDs. This makes cycles,
forward references, duplicate IDs and missing dependencies explicit validation
errors before any task starts.

```lua
local rose = require("rose")
local handle = rose.workflow({
  prompt = "Evaluate the following proposed cache design: ...",
  max_parallel = 2,
  timeout_ms = 180000,
  tasks = {
    {
      id = "correctness",
      prompt = "Analyze consistency and invalidation failures.",
      model = { provider = "ollama", model = "qwen2.5-coder:7b" },
    },
    {
      id = "performance",
      prompt = "Analyze latency, memory bounds and contention.",
      model = { provider = "ollama", model = "llama3.1:8b" },
    },
    {
      id = "decision",
      prompt = "Compare both analyses and produce a concrete implementation plan.",
      depends_on = { "correctness", "performance" },
    },
  },
}, function(err, report)
  vim.notify(err or vim.inspect(report))
end)
```

Submit additional workflows while this one is running. Their state, messages,
results, cancellation handles and callbacks are separate. Tasks with no `model`
selection use the model configured for Rose when the run is submitted.

Each task has:

- `id`: unique alphanumeric/underscore/hyphen identifier, up to 64 bytes.
- `prompt`: this task's assignment.
- `kind`: `"model"` (default, one no-tool model request) or `"agent"`.
- `model`: optional `{ provider, model }` selection.
- `depends_on`: optional list of earlier task IDs. Only those outputs are supplied.

A model task attempting tool calls fails explicitly. Model tasks are independent
analysis workers, not autonomous repository-editing agents.

## Tool-enabled agents

Use `kind = "agent"` to invoke the existing full planner/coder/validation/reviewer
pipeline. For example, append to a workflow:

```lua
{
  id = "implementation",
  kind = "agent",
  prompt = "Implement the agreed plan in the configured workspace and pass the required checks.",
  depends_on = { "decision" },
  model = { provider = "ollama", model = "qwen2.5-coder:7b" },
}
```

Enable `trusted` and configure checks exactly as required for your existing
`RoseAgent` workflow. This patch does not grant trust. The original model tool
allowlist, workspace restrictions, required checks, freshness checks, reviewer
verdict and repair limits stay authoritative. A tool-enabled task only succeeds
if the existing agent report has `verified == true`. Its bounded JSON report
becomes dependency evidence; a report over 32 KiB fails the task instead of
silently dropping validation details.

All writing agents, including manually started `RoseAgent`/Flow/Hub operations,
share the existing writer lease. A scheduled agent waits while it is occupied;
independent model tasks may continue. **Concurrent independent workflows are
supported; simultaneous file-changing agents in the same Rose instance remain
serialized.** There is no worktree isolation or cross-process writer locking in
this patch. Read-only model evidence can become stale; the tool-enabled agent
must inspect the workspace and pass its normal fresh validation.

For direct model selection, `rose.agent(task, callback, selection)` is also
supported. Existing calls and `RoseAgent` behavior remain compatible.

## Provider consent and configuration

Per-task selections can change only `provider` and `model`. They cannot change
workspace, trust, endpoints, credential environment variables, or consent flags.
All selections are validated before any inference is started. Credentials remain
resolved by the existing provider adapter at request time.

A cloud member must already have a complete provider configuration in Rose and
requires both existing `providers.enabled` and `providers.allow_cloud` gates.
A council may mix configured local and cloud providers, but peer outputs will
then be transmitted to the chosen reviewers/chair. There is no cloud fallback.
The new code adds no provider, model-list request, credential storage, or API key.

## Lifecycle and bounds

| Bound | Value |
| --- | --- |
| Active councils/workflows per Rose instance | 4 |
| Active tasks across the new scheduler | 4 |
| Active tasks per workflow | Configurable 1–4, default 4 |
| Tasks per workflow | 1–32 |
| Council members | 2–6 distinct provider/model pairs |
| Whole-workflow deadline, including writer wait | 1–600000 ms, default 600000 |
| Shared prompt / each task prompt | 32768 bytes each |
| Each task result | 32768 bytes |
| Dependency-augmented context | Existing `agent.max_context` byte limit |
| Scheduler tick | 50 ms; at most one queued tick per workflow |

Admission beyond four active workflows fails explicitly rather than building an
unbounded queue. Existing standalone Ask/Agent/MCP operations are outside the
scheduler's four-task cap. Provider transport response limits remain in force;
the 32 KiB task-result check happens after the provider receives a response.

Results are ordered by task submission, not completion time. Task states are
`pending`, `running`, `ok`, `failed`, `blocked`, or `cancelled`; terminal run
states are `ok`, `failed`, `timeout`, or `cancelled`. A deadline or cancellation
cancels owned task handles, closes the timer, releases scheduler slots and calls
the callback once. Late and duplicate callbacks cannot revive tasks. Active
registry entries are removed on completion; no persistent history is introduced.
`verified=false` on the workflow report means orchestration is not itself a
validation claim; an individual successful `agent` task has passed its existing
gate and includes its agent report as JSON text.

## Development checks

```sh
make test-workflows
make test-package-spec
make typecheck-all
stylua --check --config-path .stylua.toml --syntax LuaJIT \
  lua/rose/native/selection.lua lua/rose/native/workflow.lua \
  lua/rose/native/council.lua lua/rose/init.lua lua/rose/types.lua \
  tests/workflows.lua lazy.lua
git diff --check
```

Tests are offline provider/agent fixtures and never read real API credentials or
invoke paid models. See the accompanying validation report for exact tool versions,
results, baseline failures and environment limitations.