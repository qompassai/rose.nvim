local M = {}
local w = require("rose.tooling.workspace")
local uv = vim.uv or vim.loop

local function relevant(config, ft)
  if config.filetypes == nil then
    return true
  end
  assert(type(config.filetypes) == "table", "check filetypes must be an array")
  if #config.filetypes == 0 then
    return true
  end
  return vim.tbl_contains(config.filetypes, ft)
end

local function validate(config)
  assert(
    type(config) == "table" and type(config.cmd) == "table" and #config.cmd > 0,
    "check cmd must be a nonempty argv array"
  )
  assert(vim.islist(config.cmd), "check cmd must be an argv array")
  for _, arg in ipairs(config.cmd) do
    assert(type(arg) == "string" and not arg:find("\0", 1, true), "invalid check argv")
  end
  assert(config.cmd[1] ~= "", "empty executable")
  w.timeout(config.timeout, 30000)
end

local function executable(cmd)
  if cmd:find("/", 1, true) then
    if cmd:sub(1, 1) ~= "/" then
      return w.resolve(cmd)
    end
    -- An absolute command is an explicit user-configured executable, not a file
    -- tool path. Tools cannot supply it or any arguments.
    return cmd
  end
  return vim.fn.exepath(cmd)
end

function M.list(ft)
  local list = {}
  for name, config in pairs(w.state().options.checks or {}) do
    local item = { name = name, relevant = false, status = "unavailable" }
    local ok, err = pcall(function()
      validate(config)
      item.filetypes = config.filetypes
      item.relevant = relevant(config, ft)
      item.timeout = w.timeout(config.timeout, 30000)
      item.executable = executable(config.cmd[1])
      item.available = item.executable ~= "" and vim.fn.executable(item.executable) == 1
      item.status = item.available and "unverified" or "unavailable"
      item.reason = not w.state().trusted and "workspace is not trusted"
        or not item.available and "configured executable is not installed"
        or nil
      item.runnable = w.state().trusted and item.relevant and item.available
    end)
    if not ok then
      item.status, item.error = "error", tostring(err)
    end
    list[#list + 1] = item
  end
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  return list
end

local check_timeout_ms_default = 120000
local output_bytes_max = 65536
local exit_code_timeout = 124
local signal_term = 15

-- Changedticks of every loaded workspace buffer, so edits during a check mark it stale.
local function buffer_ticks()
  local ticks = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local ok = pcall(w.relative, vim.api.nvim_buf_get_name(b))
    if ok and vim.api.nvim_buf_is_loaded(b) then
      ticks[b] = vim.api.nvim_buf_get_changedtick(b)
    end
  end
  return ticks
end

local function run_command(command, timeout_ms)
  w.resolve(".")
  local completed
  local process = vim.system(
    command,
    { cwd = w.state().root, text = true, timeout = timeout_ms },
    function(value)
      completed = value
    end
  )
  -- SystemObj:wait() pumps fast events only. A normal predicate wait is
  -- essential here: scheduled user edits/saves must be processed while
  -- the checker runs, then invalidated by the workspace snapshot.
  local ready = vim.wait(timeout_ms, function()
    return completed ~= nil
  end, 10)
  if not ready then
    pcall(process.kill, process, signal_term)
    return { code = exit_code_timeout, signal = signal_term, stdout = "", stderr = "" }
  end
  return completed
end

-- Record the process outcome, then downgrade to "stale" if the workspace moved underneath it.
local function record_completed(result, completed, ticks, workspace_before, snapshot_path)
  result.exit_code, result.signal = completed.code, completed.signal
  local stdout, stderr = completed.stdout or "", completed.stderr or ""
  result.stdout, result.stderr = stdout:sub(1, output_bytes_max), stderr:sub(1, output_bytes_max)
  result.output_truncated = #stdout > output_bytes_max or #stderr > output_bytes_max
  result.status = completed.code == exit_code_timeout and "timeout"
    or completed.code == 0 and (completed.signal or 0) == 0 and "ok"
    or "failed"
  for b, tick in pairs(ticks) do
    if not vim.api.nvim_buf_is_valid(b) or vim.api.nvim_buf_get_changedtick(b) ~= tick then
      result.status, result.reason = "stale", "workspace buffer changed while checking"
    end
  end
  if not vim.deep_equal(workspace_before, w.snapshot(snapshot_path)) then
    result.status, result.reason =
      "stale", "workspace buffer or observed saved file changed while checking"
  end
  if #w.dirty() > 0 then
    result.status, result.reason = "stale", "unsaved workspace buffers changed while checking"
  end
end

local function run_one(item, remaining_ms, workspace_before, snapshot_path)
  local result = { name = item.name, status = item.status }
  if remaining_ms <= 0 then
    result.status, result.reason = "timeout", "aggregate check deadline exceeded"
    return result
  end
  local config = w.state().options.checks[item.name]
  local command = vim.deepcopy(config.cmd)
  command[1] = item.executable
  local ticks = buffer_ticks()
  local ok, completed = pcall(run_command, command, math.min(remaining_ms, item.timeout))
  if not ok then
    result.status, result.error = "error", tostring(completed)
  else
    record_completed(result, completed, ticks, workspace_before, snapshot_path)
  end
  return result
end

function M.run(args)
  assert(type(args) == "table", "checks.run: args must be a table")
  w.require_trust()
  local snapshot = w.capture(args, true)
  local configured = M.list(snapshot.filetype)
  local selected = {}
  for _, item in ipairs(configured) do
    if args.name == item.name or args.name == nil and item.relevant then
      selected[#selected + 1] = item
    end
  end
  if args.name and #selected == 0 then
    return { status = "unavailable", reason = "Unknown configured check name.", checks = {} }
  end
  local dirty = w.dirty()
  local workspace_before = w.snapshot(snapshot.path)
  local results = {}
  local start = uv.hrtime()
  local budget_ms = w.timeout(w.state().options.check_timeout, check_timeout_ms_default)
  for _, item in ipairs(selected) do
    local result
    if not item.relevant then
      result = { name = item.name, status = "unavailable" }
      result.reason = "check is not configured for the captured filetype"
    elseif item.status == "error" or not item.available then
      result = { name = item.name, status = item.status }
      result.reason, result.error = item.reason, item.error
    elseif #dirty > 0 then
      result = { name = item.name, status = "stale" }
      result.reason = "unsaved workspace buffers would not be checked; save them manually first"
    else
      local remaining_ms = math.floor(budget_ms - (uv.hrtime() - start) / 1e6)
      result = run_one(item, remaining_ms, workspace_before, snapshot.path)
    end
    result.verified = result.status == "ok"
    results[#results + 1] = result
  end
  local status = w.aggregate(results)
  return {
    status = status,
    verified = status == "ok",
    checks = results,
    filetype = snapshot.filetype,
    workspace_snapshot = workspace_before,
    workspace_snapshot_version = 1,
    dirty_buffers = dirty,
    scope = "explicitly configured checks against saved workspace files",
    reason = #results == 0 and "No configured checks apply to the captured filetype." or nil,
  }
end

return M
