-- Explicit-user Hugging Face transfers. No model tools or third-party plugins.
local M = {}
local uv = vim.uv or vim.loop
local script =
  debug.getinfo(1, "S").source:sub(2):gsub("/lua/rose/hub%.lua$", "/scripts/rose_hub.py")
local options, active, last, sequence = nil, nil, { state = "idle" }, 0
local unpack = table.unpack or unpack

local function integer(n, lo, hi, name)
  assert(type(n) == "number" and n % 1 == 0 and n >= lo and n <= hi, "invalid " .. name)
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Rose Hub" })
end

local function invoke(fn, ...)
  if fn then
    local args = { ... }
    local n = select("#", ...)
    local ok = pcall(function()
      fn(unpack(args, 1, n))
    end)
    if not ok then
      notify("Rose Hub callback failed", vim.log.levels.ERROR)
    end
  end
end

local setup_options = {
  workspace = true,
  trusted = true,
  python = true,
  cache_dir = true,
  xet_cache = true,
  max_workers = true,
  max_files = true,
  max_total_bytes = true,
  xet = true,
  high_performance = true,
  on_progress = true,
  approve_upload = true,
  timeout_ms = true,
}

function M.setup(opts)
  assert(not active, "stop the active Hub operation before setup")
  opts = opts or {}
  assert(type(opts) == "table", "hub.setup: opts must be a table")
  for key in pairs(opts) do
    assert(setup_options[key], "unknown Hub option: " .. tostring(key))
  end
  local cfg = vim.tbl_extend("force", {
    workspace = uv.cwd(),
    trusted = false,
    python = "python3",
    cache_dir = vim.fn.stdpath("cache") .. "/rose/huggingface",
    max_workers = 4,
    max_files = 256,
    max_total_bytes = 10 * 1024 ^ 3,
    xet = "auto",
    high_performance = false,
    timeout_ms = 0,
  }, opts)
  assert(
    type(cfg.workspace) == "string" and cfg.workspace:sub(1, 1) == "/",
    "Hub workspace must be absolute"
  )
  local real = uv.fs_realpath(cfg.workspace)
  assert(real and uv.fs_stat(real).type == "directory", "Hub workspace must exist")
  -- Do not follow aliases silently: Python rechecks every component with NOFOLLOW.
  cfg.workspace = cfg.workspace:gsub("/+$", "")
  if cfg.workspace == "" then
    cfg.workspace = "/"
  end
  assert(real == cfg.workspace, "Hub workspace cannot contain symlinks or relative components")
  assert(
    type(cfg.cache_dir) == "string" and cfg.cache_dir:sub(1, 1) == "/",
    "Hub cache_dir must be absolute"
  )
  assert(
    type(cfg.python) == "string" and cfg.python ~= "" and not cfg.python:find("\0", 1, true),
    "invalid Hub python"
  )
  assert(type(cfg.trusted) == "boolean", "invalid Hub boolean")
  assert(type(cfg.high_performance) == "boolean", "invalid Hub boolean")
  assert(cfg.xet == "auto" or cfg.xet == "disabled", "Hub xet must be auto or disabled")
  for _, key in ipairs({ "approve_upload", "on_progress" }) do
    assert(
      cfg[key] == nil or type(cfg[key]) == "function",
      "Hub " .. key .. " must be a trusted setup callback"
    )
  end
  integer(cfg.max_workers, 1, 16, "max_workers")
  integer(cfg.max_files, 1, 4096, "max_files")
  integer(cfg.max_total_bytes, 1, 2 ^ 53 - 1, "max_total_bytes")
  integer(cfg.timeout_ms, 0, 2147483647, "timeout_ms")
  options = cfg
  return M
end

local function config()
  if not options then
    M.setup()
  end
  return options
end

local function worker_config(cfg, disabled)
  local result = {}
  for _, key in ipairs({
    "workspace",
    "trusted",
    "cache_dir",
    "xet_cache",
    "max_workers",
    "max_files",
    "max_total_bytes",
    "xet",
    "high_performance",
  }) do
    result[key] = cfg[key]
  end
  if disabled then
    result.xet = "disabled"
  end
  return result
end

local function finish(job, err, result)
  if job.done then
    return
  end
  job.done = true
  if job.timer then
    job.timer:stop()
    job.timer:close()
    job.timer = nil
  end
  if active == job then
    active = nil
  end
  job.state = job.cancelled and "cancelled" or (err and "error" or "done")
  last = { id = job.id, state = job.state, direction = job.direction, error = err, result = result }
  invoke(job.callback, err, result)
  if not job.callback then
    notify(
      err or ("Hub " .. job.direction .. " complete"),
      err and vim.log.levels.ERROR or vim.log.levels.INFO
    )
  end
end

local function progress(job, event)
  if job.done then
    return
  end
  job.progress = event
  invoke(job.cfg.on_progress, vim.deepcopy(event))
end

local helper_output_bytes_max = 8 * 1024 * 1024
local signal_term = 15

-- Line-delimited JSON event reader for one helper process. Returns a reader table whose
-- fields hold the decoded outcome: result, worker_error, error_code and invalid.
local function event_reader(job)
  local reader = { buffer = "", size = 0, invalid = false }
  function reader.line(raw)
    if raw == "" then
      return
    end
    local ok, event = pcall(vim.json.decode, raw)
    if not ok or type(event) ~= "table" then
      reader.invalid = true
      return
    end
    if event.event == "result" then
      reader.result = event.result
    elseif event.event == "error" then
      reader.worker_error, reader.error_code = event.message, event.code
    elseif event.event == "progress" or event.event == "capabilities" then
      vim.schedule(function()
        progress(job, event)
      end)
    end
  end
  function reader.stdout(err, data)
    if err then
      reader.invalid = true
    end
    if not data or reader.invalid then
      return
    end
    reader.size = reader.size + #data
    if reader.size > helper_output_bytes_max then
      reader.invalid = true
      if job.process then
        job.process:kill(signal_term)
      end
      return
    end
    reader.buffer = reader.buffer .. data
    -- Each iteration consumes at least the newline, so #buffer bounds the loop.
    for _ = 1, #reader.buffer do
      local at = reader.buffer:find("\n", 1, true)
      if not at then
        break
      end
      reader.line(reader.buffer:sub(1, at - 1))
      reader.buffer = reader.buffer:sub(at + 1)
    end
  end
  return reader
end

-- Map the helper's exit and decoded events to the callback(err, result, code) contract.
local function spawn_exited(job, reader, out, callback)
  job.process = nil
  if job.done then
    return
  end
  if job.cancelled then
    finish(job, "cancelled; completed remote commits cannot be undone")
    return
  end
  if reader.buffer ~= "" then
    reader.line(reader.buffer)
  end
  if reader.invalid then
    callback("invalid or oversized Hub helper response")
    return
  end
  if out.code ~= 0 or reader.worker_error then
    callback(
      type(reader.worker_error) == "string" and reader.worker_error
        or "Hub helper failed; check configured Python and optional SDK",
      nil,
      reader.error_code
    )
  elseif reader.result == nil then
    callback("Hub helper returned no result")
  else
    callback(nil, reader.result)
  end
end

local function spawn(job, operation, preview, callback, disabled)
  assert(type(job) == "table", "hub.spawn: job must be a table")
  assert(type(callback) == "function", "hub.spawn: callback must be a function")
  if job.done or job.cancelled then
    return
  end
  local payload = {
    operation = operation,
    config = worker_config(job.cfg, disabled),
    spec = job.spec,
    preview = preview,
  }
  local reader = event_reader(job)
  local ok, handle = pcall(vim.system, { job.cfg.python, "-I", "-u", script }, {
    stdin = vim.json.encode(payload),
    text = true,
    cwd = "/",
    -- HF_TOKEN is inherited, not read, copied into JSON, argv, status or logs.
    env = { HF_ENDPOINT = "https://huggingface.co", HF_DEBUG = "0", HF_HUB_VERBOSITY = "error" },
    stdout = reader.stdout,
    -- Never forward raw SDK stderr: it can contain auth or signed URLs.
    stderr = function() end,
  }, function(out)
    vim.schedule(function()
      spawn_exited(job, reader, out, callback)
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback("cannot start Hub helper; check configured Python")
    end)
  else
    job.process = handle
  end
end

local function preview_lines(p)
  local lines = {
    "Rose Hub — explicit " .. p.direction .. " preview",
    "Repository: " .. p.repo_id .. " (" .. p.repo_type .. ")",
    "Visibility: " .. p.visibility,
    "Revision: " .. p.revision,
    "Pinned parent/commit: " .. p.commit,
    "Workspace: " .. p.workspace,
    "Cache: " .. p.cache_dir,
    "Total selected bytes: " .. tostring(p.total_bytes),
  }
  if p.direction == "download" then
    lines[#lines + 1] = "Bytes to download: "
      .. tostring(p.download_bytes)
      .. "; cached: "
      .. tostring(p.cached_bytes)
    lines[#lines + 1] = "Destination: " .. p.destination
  else
    lines[#lines + 1] = "Upload can overwrite named remote assets and create multiple commits."
    lines[#lines + 1] =
      "No remote files will be deleted. Cancellation cannot undo committed batches."
  end
  lines[#lines + 1] = ""
  for _, row in ipairs(p.files) do
    if p.direction == "upload" then
      lines[#lines + 1] = row.path .. " -> " .. row.remote_path .. " | " .. row.size .. " bytes"
      lines[#lines + 1] = "  SHA256 " .. row.snapshot.sha256
    else
      lines[#lines + 1] = row.path
        .. " -> "
        .. row.local_path
        .. " | "
        .. row.size
        .. " bytes | "
        .. (row.is_cached and "cached" or "download")
        .. (type(row.local_before) == "table" and " | OVERWRITE existing file" or " | new file")
      if type(row.local_before) == "table" then
        lines[#lines + 1] = "  Existing SHA256 " .. row.local_before.sha256
      end
    end
  end
  return lines
end

local function confirm(job, preview, respond)
  job.state = "confirming"
  local original, used = respond, false
  respond = function(approved)
    if used or job.done then
      return
    end
    used = true
    original(approved)
  end
  -- User configuration holds this capability. JSON/spec booleans never bypass UI.
  if job.direction == "upload" and job.cfg.approve_upload then
    local responded = false
    local ok = pcall(job.cfg.approve_upload, vim.deepcopy(preview), function(approved)
      if responded or job.done then
        return
      end
      responded = true
      vim.schedule(function()
        if not job.done then
          respond(type(approved) == "table" and vim.deep_equal(approved, preview))
        end
      end)
    end)
    if not ok and not responded then
      respond(false)
    end
    return
  end
  -- Full exact manifest is visible in a native scratch buffer, never executable text.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].modeline = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, preview_lines(preview))
  vim.bo[buf].modifiable = false
  job.preview_buffer = buf
  vim.api.nvim_set_current_buf(buf)
  local action = job.direction == "upload" and "Upload exactly this manifest"
    or "Download exactly this manifest"
  vim.ui.select({ "Cancel", action }, {
    prompt = string.format(
      "Rose Hub: %s %s [%s] @ %s (%d files, %s bytes); review preview buffer",
      job.direction,
      preview.repo_id,
      preview.visibility,
      preview.revision,
      #preview.files,
      preview.total_bytes
    ),
  }, function(choice)
    if not job.done then
      respond(choice == action)
    end
  end)
end

local cancel_kill_grace_ms = 500
local signal_kill = 9

local function cancel_token(job)
  local token = { id = job.id }
  function token.cancel()
    if job.done then
      return false
    end
    job.cancelled = true
    if job.process then
      local proc = job.process
      proc:kill(signal_term)
      vim.defer_fn(function()
        if not job.done and job.process == proc then
          proc:kill(signal_kill)
        end
      end, cancel_kill_grace_ms)
    else
      vim.schedule(function()
        finish(job, "cancelled; completed remote commits cannot be undone")
      end)
    end
    return true
  end
  return token
end

-- Raises on a malformed spec; credentials and approval flags are never accepted here.
local function validate_spec(direction, spec, cfg)
  assert(type(spec) == "table", "Hub spec must be a table")
  local allowed = direction == "paper" and { id = true }
    or {
      repo_id = true,
      repo_type = true,
      revision = true,
      files = true,
      dry_run = true,
      destination = direction == "download",
      path_in_repo = direction == "upload",
    }
  for key in pairs(spec) do
    assert(allowed[key], "unknown Hub spec field (credentials/approval flags forbidden)")
  end
  if direction == "upload" then
    assert(cfg.trusted, "Hub upload requires a trusted workspace")
  end
end

local function transfer(job, direction, preview)
  job.state = "transferring"
  spawn(job, direction, preview, function(transfer_err, result, error_code)
    -- No blind upload retry: streamed Xet may already have committed batches.
    -- Downloads are commit-pinned and safe to resume with official HTTP fallback.
    local fallback = transfer_err
      and error_code == "xet_transport"
      and direction == "download"
      and job.cfg.xet == "auto"
      and not job.cancelled
    if fallback then
      progress(job, {
        event = "progress",
        phase = "http-fallback",
        message = "Retrying pinned download with Xet disabled",
      })
      spawn(job, direction, preview, function(e, r)
        finish(job, e, r)
      end, true)
    else
      finish(job, transfer_err, result)
    end
  end)
end

local function previewed(job, direction, err, preview)
  if err then
    finish(job, err)
    return
  end
  if direction == "paper" or job.spec.dry_run then
    finish(job, nil, preview)
    return
  end
  confirm(job, preview, function(approved)
    if job.done or job.cancelled then
      return
    end
    if not approved then
      finish(job, "Hub transfer not approved")
      return
    end
    transfer(job, direction, preview)
  end)
end

local function start(direction, spec, callback)
  assert(type(direction) == "string", "hub.start: direction must be a string")
  local cfg = vim.deepcopy(config())
  sequence = sequence + 1
  local job =
    { id = sequence, state = "starting", direction = direction, cfg = cfg, callback = callback }
  local token = cancel_token(job)
  job.token = token
  if active then
    vim.schedule(function()
      finish(job, "another Hub operation is active; stop it first")
    end)
    return token
  end
  active = job
  vim.schedule(function()
    if job.cancelled then
      finish(job, "cancelled")
      return
    end
    local ok, why = pcall(validate_spec, direction, spec, cfg)
    if not ok then
      finish(job, tostring(why))
      return
    end
    job.spec = vim.deepcopy(spec)
    if cfg.timeout_ms > 0 then
      job.timer = uv.new_timer()
      job.timer:start(cfg.timeout_ms, 0, vim.schedule_wrap(token.cancel))
    end
    job.state = direction == "paper" and "metadata" or "previewing"
    local operation = direction == "paper" and "paper" or "preview_" .. direction
    spawn(job, operation, nil, function(err, preview)
      previewed(job, direction, err, preview)
    end)
  end)
  return token
end

function M.download(spec, callback)
  return start("download", spec, callback)
end
function M.upload(spec, callback)
  return start("upload", spec, callback)
end

function M.paper(spec, callback)
  if type(spec) == "table" and (spec.action == "upload" or spec.action == "download") then
    local copy = vim.deepcopy(spec)
    local action = copy.action
    copy.action = nil
    local valid = type(copy.files) == "table" and #copy.files > 0
    for _, path in ipairs(type(copy.files) == "table" and copy.files or {}) do
      valid = valid
        and type(path) == "string"
        and path:lower():match("%.(%w+)$") ~= nil
        and vim.tbl_contains({ "pdf", "md", "bib" }, path:lower():match("%.(%w+)$"))
    end
    if not valid then
      return start("paper", { invalid = "paper assets must be PDF, MD or BIB" }, callback)
    end
    return start(action, copy, callback)
  end
  return start("paper", spec, callback)
end

function M.status()
  if not active then
    return vim.deepcopy(last)
  end
  return vim.deepcopy({
    id = active.id,
    state = active.state,
    direction = active.direction,
    progress = active.progress,
  })
end

function M.stop()
  return active and active.token.cancel() or false
end

function M.commands()
  local function input(direction)
    vim.ui.input(
      { prompt = "Rose Hub " .. direction .. " spec (JSON; explicit files required): " },
      function(raw)
        if not raw then
          return
        end
        local ok, spec = pcall(vim.json.decode, raw)
        if not ok or type(spec) ~= "table" then
          notify("Invalid Hub JSON spec", vim.log.levels.ERROR)
          return
        end
        M[direction](spec)
      end
    )
  end
  for suffix, direction in pairs({ Download = "download", Upload = "upload", Paper = "paper" }) do
    vim.api.nvim_create_user_command("RoseHub" .. suffix, function()
      input(direction)
    end, { desc = "Explicit Hugging Face " .. direction, force = true })
  end
  vim.api.nvim_create_user_command("RoseHubStop", function()
    M.stop()
  end, { desc = "Cancel Hub operation", force = true })
  vim.api.nvim_create_user_command("RoseHubStatus", function()
    notify(vim.inspect(M.status()))
  end, { desc = "Hub transfer status", force = true })
  return M
end

return M
