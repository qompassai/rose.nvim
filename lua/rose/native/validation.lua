-- Verification is host-owned, not a model assertion.
local M = {}

local function workspace_buffers(config)
  local snapshots = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buffer)
    if
      vim.api.nvim_buf_is_loaded(buffer)
      and name:sub(1, #config.workspace + 1) == config.workspace .. "/"
    then
      snapshots[buffer] = {
        name = name,
        changedtick = vim.api.nvim_buf_get_changedtick(buffer),
        modified = vim.bo[buffer].modified,
      }
    end
  end
  return snapshots
end

function M.is_fresh(config, report, tools, context_buf)
  local current = workspace_buffers(config)
  for buffer, snapshot in pairs(report.buffer_snapshots or {}) do
    local now = current[buffer]
    if
      not now
      or now.name ~= snapshot.name
      or now.changedtick ~= snapshot.changedtick
      or now.modified
    then
      return false
    end
  end
  for _, snapshot in pairs(current) do
    if snapshot.modified then
      return false
    end
  end
  if report.workspace_snapshot_version ~= 1 or type(report.workspace_snapshot) ~= "table" then
    return false
  end
  local context = M.safe_call(tools, "editor_context", { path = report.snapshot_path }, context_buf)
  if
    context.workspace_snapshot_version ~= 1
    or type(context.dirty_buffers) ~= "table"
    or #context.dirty_buffers > 0
  then
    return false
  end
  if not vim.deep_equal(report.workspace_snapshot, context.workspace_snapshot) then
    return false
  end
  return true
end

function M.safe_call(tools, name, args, context_buf)
  local function invoke()
    return tools.call(name, args or vim.empty_dict())
  end
  local ok, result
  if context_buf and vim.api.nvim_buf_is_valid(context_buf) then
    ok, result = pcall(vim.api.nvim_buf_call, context_buf, invoke)
  else
    ok, result = pcall(invoke)
  end
  if not ok then
    return { status = "error", error = tostring(result) }
  end
  if type(result) ~= "table" then
    return { status = "error", error = "tool returned a non-object result" }
  end
  local serializable = pcall(vim.json.encode, result)
  if not serializable then
    return { status = "error", error = "tool returned a non-serializable result" }
  end
  return result
end

local static_kinds = { lint = true, typecheck = true, diagnostics = true }
local unsettled_lint = { stale = true, timeout = true, error = true }
local blocking_diagnostics = { failed = true, error = true, stale = true }

local function is_error_diagnostic(diagnostic)
  return diagnostic.severity == 1
    or diagnostic.severity == "ERROR"
    or diagnostic.severity == "error"
end

local function check_names(config, name)
  if name and name ~= "" then
    return { name }
  end
  local names = {}
  for check_name in pairs(config.checks) do
    names[#names + 1] = check_name
  end
  table.sort(names)
  return names
end

local function target_filetype(config, path, context_buf)
  if path and vim.filetype and vim.filetype.match then
    return vim.filetype.match({ filename = config.workspace .. "/" .. path }) or ""
  elseif context_buf and vim.api.nvim_buf_is_valid(context_buf) then
    return vim.bo[context_buf].filetype
  end
  return ""
end

-- Changed paths become targets; with none, `false` stands for the source buffer.
local function target_list(changed_paths)
  if changed_paths and #changed_paths > 0 then
    return vim.list_extend({}, changed_paths)
  end
  return { false }
end

-- Fill report.targets and return the ordered list of check jobs to execute.
local function plan_jobs(config, names, targets, context_buf, report)
  local jobs = {}
  report.targets = {}
  for _, path in ipairs(targets) do
    local ft = target_filetype(config, path, context_buf)
    local target = { path = path or nil, filetype = ft, selected = 0 }
    report.targets[#report.targets + 1] = target
    for _, check_name in ipairs(names) do
      local check = config.checks[check_name]
      local applicable = type(check) ~= "table"
        or not check.filetypes
        or #check.filetypes == 0
        or vim.tbl_contains(check.filetypes, ft)
      if applicable then
        target.selected = target.selected + 1
        jobs[#jobs + 1] = {
          name = check_name,
          path = path or nil,
          target = #report.targets,
          kind = type(check) == "table" and check.kind or nil,
        }
      end
    end
  end
  return jobs
end

-- Verdict accumulators: `passed` is the positive gate, `failed` records hard failures.
local function evaluate_checks(report, verdict, job_count)
  if job_count == 0 then
    report.reasons[#report.reasons + 1] =
      "No applicable named checks configured; validation is unverified."
  end
  for _, target in ipairs(report.targets) do
    if target.selected == 0 then
      verdict.passed = false
      report.reasons[#report.reasons + 1] = "No check covers "
        .. tostring(target.path or "the source buffer")
        .. " ("
        .. target.filetype
        .. ")"
    end
  end
  for _, check in ipairs(report.checks) do
    if check.result.status ~= "ok" or check.result.error then
      verdict.passed = false
      report.reasons[#report.reasons + 1] = check.name .. ": " .. tostring(check.result.status)
    end
    if check.result.status == "failed" then
      verdict.failed = true
    end
  end
end

-- Every target needs completed lint or static-check evidence, never cached diagnostics.
local function evaluate_static(report, verdict)
  for index, target in ipairs(report.targets) do
    local lint = report.lint[index]
    local static_verified = lint and lint.result.status == "ok" and lint.result.verified == true
    for _, check in ipairs(report.checks) do
      local completed = check.result.status == "ok" and not check.result.error
      if check.target == index and static_kinds[check.kind] and completed then
        static_verified = true
      end
    end
    target.static_verified = static_verified or false
    if not static_verified then
      verdict.passed = false
      report.reasons[#report.reasons + 1] = "No completed lint/static-check evidence for "
        .. tostring(target.path or "the source buffer")
    end
    if lint and lint.result.status == "failed" then
      verdict.failed, verdict.passed = true, false
    end
    if lint and unsettled_lint[lint.result.status] then
      verdict.passed = false
      report.reasons[#report.reasons + 1] = "Lint: " .. lint.result.status
    end
  end
end

local function evaluate_diagnostics(report, verdict)
  local errors = 0
  for _, diagnostics in ipairs(report.diagnostic_snapshots) do
    -- Cached diagnostics are advisory, not a positive validation gate.
    if diagnostics.status ~= "ok" then
      report.reasons[#report.reasons + 1] = "Editor diagnostics: " .. tostring(diagnostics.status)
      if blocking_diagnostics[diagnostics.status] then
        verdict.passed = false
      end
    end
    if diagnostics.status == "failed" then
      verdict.failed = true
    end
    for _, diagnostic in ipairs(diagnostics.diagnostics or {}) do
      if is_error_diagnostic(diagnostic) then
        errors = errors + 1
      end
    end
  end
  if errors > 0 then
    verdict.failed, verdict.passed = true, false
    report.reasons[#report.reasons + 1] = errors .. " editor error diagnostic(s)"
  end
end

local function evaluate_workspace(report, verdict, context)
  report.workspace_snapshot, report.workspace_snapshot_version =
    context.workspace_snapshot, context.workspace_snapshot_version
  if
    context.workspace_snapshot_version ~= 1
    or type(context.workspace_snapshot) ~= "table"
    or type(context.dirty_buffers) ~= "table"
  then
    verdict.passed = false
    report.reasons[#report.reasons + 1] = "Required workspace freshness evidence is unavailable."
  elseif #context.dirty_buffers > 0 then
    verdict.passed = false
    report.reasons[#report.reasons + 1] = "Workspace has unsaved buffers after validation."
  end
end

-- Combine all collected evidence into the final report verdict.
local function conclude(run)
  local report, jobs, targets = run.report, run.jobs, run.targets
  local verdict = { passed = #jobs > 0, failed = false }
  evaluate_checks(report, verdict, #jobs)
  evaluate_static(report, verdict)
  evaluate_diagnostics(report, verdict)
  local context =
    M.safe_call(run.tools, "editor_context", { path = targets[1] or nil }, run.context_buf)
  report.snapshot_path = targets[1] or nil
  evaluate_workspace(report, verdict, context)
  report.verified = verdict.passed and not verdict.failed
  report.status = verdict.failed and "failed" or report.verified and "ok" or "unverified"
  report.buffer_snapshots = workspace_buffers(run.config)
  return report
end

function M.run(config, tools, name, callback, context_buf, changed_paths)
  assert(type(config) == "table", "validation.run: config must be a table")
  assert(type(callback) == "function", "validation.run: callback must be a function")
  local cancelled = false
  local token = {
    cancel = function()
      cancelled = true
    end,
  }
  local report = { status = "unverified", verified = false, checks = {}, lint = {}, reasons = {} }
  local names = check_names(config, name)
  local targets = target_list(changed_paths)
  local jobs = plan_jobs(config, names, targets, context_buf, report)
  local run = { config = config, tools = tools, context_buf = context_buf }
  run.report, run.jobs, run.targets = report, jobs, targets
  local function finish()
    if cancelled then
      callback("cancelled")
      return
    end
    callback(nil, conclude(run))
  end
  -- Asynchronous stepping over a fixed list: each callback advances one index and the
  -- recursion depth is one, so the chain is bounded by #jobs and #targets.
  local function check_at(index)
    if cancelled then
      callback("cancelled")
      return
    end
    if not jobs[index] then
      report.diagnostic_snapshots = {}
      for _, path in ipairs(targets) do
        report.diagnostic_snapshots[#report.diagnostic_snapshots + 1] =
          M.safe_call(tools, "editor_diagnostics", { path = path or nil }, context_buf)
      end
      report.diagnostics = report.diagnostic_snapshots[1]
      finish()
      return
    end
    local job = jobs[index]
    local result =
      M.safe_call(tools, "editor_check", { name = job.name, path = job.path }, context_buf)
    report.checks[#report.checks + 1] =
      { name = job.name, path = job.path, target = job.target, kind = job.kind, result = result }
    vim.schedule(function()
      check_at(index + 1)
    end)
  end
  local function lint_at(index)
    if cancelled then
      callback("cancelled")
      return
    end
    if targets[index] == nil then
      check_at(1)
      return
    end
    local path = targets[index] or nil
    report.lint[index] =
      { path = path, result = M.safe_call(tools, "editor_lint", { path = path }, context_buf) }
    vim.schedule(function()
      lint_at(index + 1)
    end)
  end
  vim.schedule(function()
    lint_at(1)
  end)
  return token
end

return M
