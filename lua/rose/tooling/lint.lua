local M = {}
local discovery = require("rose.tooling.discovery")
local lsp = require("rose.tooling.lsp")
local w = require("rose.tooling.workspace")
local uv = vim.uv or vim.loop
local cached

function M.reset()
  cached = nil
end

local function registry()
  if type(package.loaded.linters) == "table" then
    return package.loaded.linters
  end
  if cached then
    return cached
  end
  local root = discovery.root()
  if not root or not w.state().trusted then
    return nil
  end
  local file = root .. "/lua/linters/init.lua"
  local real = uv.fs_realpath(file)
  if not real or not w.contains(root, real) then
    return nil
  end
  -- Older runners ignore chunk options and would initialize an updater on load.
  -- Require an explicit opt-in marker before executing the embedding entrypoint.
  local fd = uv.fs_open(real, "r", 0)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local text = stat and uv.fs_read(fd, math.min(stat.size, 65536), 0)
  uv.fs_close(fd)
  if not text or not text:find("M.completion_api_version = 1", 1, true) then
    return nil
  end
  -- The additive embedding mode skips both eager definitions and updater setup.
  -- Never call runner.setup(), and do not replace the user's package.loaded value.
  local chunk = loadfile(real)
  if not chunk then
    return nil
  end
  local ok, runner = pcall(chunk, { lazy = true, no_updates = true })
  if not ok or type(runner) ~= "table" then
    return nil
  end
  cached = runner
  return runner
end

local function selected(runner, ft)
  local names, seen = {}, {}
  for _, key in ipairs({ "*", ft, "_" }) do
    if key ~= "_" or #names == 0 then
      for _, name in ipairs((runner.linters_by_ft or {})[key] or {}) do
        if not seen[name] then
          names[#names + 1] = name
          seen[name] = true
        end
      end
    end
  end
  return names
end

local function definition(runner, name)
  if runner.get_definition and w.state().trusted then
    return runner.get_definition(name)
  end
  return (runner.definitions or {})[name]
end

function M.describe(snapshot)
  local runner = registry()
  if not runner then
    return {
      status = "unavailable",
      linters = {},
      reason = "Diver native lint registry is not configured or loaded.",
    }
  end
  local items = {}
  for _, name in ipairs(selected(runner, snapshot.filetype)) do
    local def = definition(runner, name)
    local item = { name = name, status = "unavailable" }
    if def then
      local candidates = type(def.cmd) == "table" and def.cmd or { def.cmd }
      for _, command in ipairs(candidates) do
        if type(command) == "string" and vim.fn.executable(command) == 1 then
          item.executable = command
          break
        end
      end
      item.stdin = def.stdin == true
      item.status = item.executable and "unverified" or "unavailable"
      item.reason = not item.executable and "linter executable is not installed" or nil
    else
      item.reason = (runner.load_errors or {})[name] or "definition is unavailable"
    end
    items[#items + 1] = item
  end
  return {
    status = #items > 0 and "unverified" or "unavailable",
    linters = items,
    completion_api = runner.completion_api_version or 0,
    enabled = (runner.options or {}).enabled ~= false,
  }
end

local lint_timeout_ms_default = 30000

-- Start every selected linter; `state.results[slot]` is filled either by completion or
-- by an immediate start failure, and `state.pending` counts the slots still running.
local function start_linters(runner, names, snapshot, timeout_ms, state)
  for i, name in ipairs(names) do
    local slot = i
    local ok, started, handle = pcall(runner.run_linter, name, snapshot.bufnr, {
      automatic = false,
      notify = false,
      timeout = timeout_ms,
      root = w.state().root,
      validate_context = function(context, _, cwd)
        local actual = uv.fs_realpath(cwd)
        return actual ~= nil
          and w.contains(w.state().root, actual)
          and w.resolve(w.relative(context.filename)) == snapshot.absolute
      end,
      on_complete = function(result)
        if not state.results[slot] then
          state.results[slot] = result
          state.pending = state.pending - 1
        end
      end,
    })
    if not ok or not started and not state.results[slot] then
      if not state.results[slot] then
        state.pending = state.pending - 1
      end
      state.results[slot] = {
        name = name,
        status = ok and "unavailable" or "error",
        error = not ok and tostring(started) or nil,
      }
    elseif handle then
      state.handles[slot] = handle
    end
  end
end

local function cancel_unfinished(names, state)
  for i, name in ipairs(names) do
    if not state.results[i] then
      if state.handles[i] and state.handles[i].cancel then
        state.handles[i].cancel("timeout")
      end
      state.results[i] = state.results[i]
        or { name = name, status = "timeout", reason = "lint completion deadline exceeded" }
    end
  end
end

function M.run(args)
  assert(type(args) == "table", "lint.run: args must be a table")
  w.require_trust()
  local snapshot = w.capture(args)
  local runner = registry()
  if not runner or runner.completion_api_version ~= 1 then
    return {
      status = "unavailable",
      verified = false,
      reason = "Diver completion API v1 is required; asynchronous fire-and-forget lint is not "
        .. "verification.",
    }
  end
  if (runner.options or {}).enabled == false then
    return { status = "unavailable", verified = false, reason = "User disabled native linting." }
  end
  local names = selected(runner, snapshot.filetype)
  if #names == 0 then
    return {
      status = "unavailable",
      verified = false,
      linters = {},
      reason = "No linters configured for " .. snapshot.filetype,
    }
  end
  snapshot = w.load(snapshot)
  local timeout_ms = w.timeout(args.timeout, lint_timeout_ms_default)
  local state = { results = {}, handles = {}, pending = #names }
  local start = uv.hrtime()
  start_linters(runner, names, snapshot, timeout_ms, state)
  local remaining_ms = math.max(1, math.floor(timeout_ms - (uv.hrtime() - start) / 1e6))
  -- Predicate-based completion, not a fixed sleep or a diagnostic-count heuristic.
  local done = state.pending == 0
    or vim.wait(remaining_ms, function()
      return state.pending == 0
    end, 10)
  if not done then
    cancel_unfinished(names, state)
  end
  assert(#state.results == #names, "every selected linter must produce a result")
  for _, result in ipairs(state.results) do
    if result.namespace then
      result.diagnostics = lsp.diagnostic_items(snapshot.bufnr, result.namespace)
    end
  end
  local status = w.aggregate(state.results)
  if not w.unchanged(snapshot) then
    status = "stale"
  end
  return {
    status = status,
    verified = status == "ok",
    path = snapshot.path,
    filetype = snapshot.filetype,
    changedtick = snapshot.changedtick,
    linters = state.results,
    scope = "configured native linters only",
    coordinates = "line: 1-based; column: 0-based bytes",
  }
end

return M
