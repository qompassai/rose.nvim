-- Plugin-free, bounded DAP probes. This is not a full interactive debugger UI.
local M = {}
local options = {}
local active

function M.setup(opts)
  options = opts or {}
end

local function fail(message, status)
  return { status = status or "error", error = tostring(message), verified = false }
end

-- Adapter configs are shallow JSON-like tables; deeper nesting is a configuration error.
local expand_depth_max = 16

local function expand(value, root, depth)
  depth = depth or 1
  assert(depth <= expand_depth_max, "debug adapter configuration nests deeper than 16 levels")
  if type(value) == "string" then
    return (value:gsub("%${workspaceFolder}", function()
      return root
    end))
  elseif type(value) == "table" then
    local result = {}
    for k, v in pairs(value) do
      result[k] = expand(v, root, depth + 1)
    end
    return result
  end
  return value
end

local function inside(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local dap_frame_bytes_max = 8 * 1024 * 1024
local dap_output_bytes_max = 65536
local dap_events_max = 100
local dap_stderr_bytes_max = 8192

-- One adapter connection: framing, request/response matching and bounded event capture.
local Session = {}
Session.__index = Session

function Session:send(message)
  self.seq = self.seq + 1
  message.seq = self.seq
  local payload = vim.json.encode(message)
  self.process:write(("Content-Length: %d\r\n\r\n%s"):format(#payload, payload))
  return message.seq
end
function Session:request(command, args)
  return self:send({ type = "request", command = command, arguments = args or vim.empty_dict() })
end
function Session:receive(message)
  if message.type == "response" then
    self.pending[message.request_seq] = message
  elseif message.type == "event" then
    if message.event == "initialized" then
      self.initialized = true
    end
    if message.event == "stopped" then
      self.stopped = message.body or {}
    end
    if message.event == "terminated" then
      self.terminated = true
    end
    if message.event == "exited" then
      self.exit_code = (message.body or {}).exitCode
    end
    if message.event == "output" then
      self.output = (self.output .. ((message.body or {}).output or "")):sub(-dap_output_bytes_max)
    elseif #self.events < dap_events_max then
      self.events[#self.events + 1] = { event = message.event, body = message.body }
    end
  elseif message.type == "request" then
    -- In particular, never execute adapter-supplied runInTerminal commands.
    self:send({
      type = "response",
      request_seq = message.seq,
      command = message.command,
      success = false,
      message = "Reverse requests are not supported by Rose probes",
    })
  end
end
function Session:feed(chunk)
  self.input = self.input .. chunk
  if #self.input > dap_frame_bytes_max then
    self.error = "DAP frame limit exceeded"
    return
  end
  -- Every complete frame removes at least its 4-byte separator, so one iteration per
  -- buffered byte is a safe explicit bound.
  for _ = 1, #self.input do
    local pos = self.input:find("\r\n\r\n", 1, true)
    if not pos then
      return
    end
    local length = tonumber(self.input:sub(1, pos - 1):lower():match("content%-length:%s*(%d+)"))
    if not length or length > dap_frame_bytes_max then
      self.error = "Invalid DAP Content-Length"
      return
    end
    if #self.input < pos + 3 + length then
      return
    end
    local body = self.input:sub(pos + 4, pos + 3 + length)
    self.input = self.input:sub(pos + 4 + length)
    local ok, msg = pcall(vim.json.decode, body)
    if not ok or type(msg) ~= "table" then
      self.error = "Invalid DAP JSON"
      return
    end
    self:receive(msg)
  end
end
function Session:await(predicate)
  local remaining = math.max(0, self.deadline - vim.uv.hrtime() / 1e6)
  local ready = vim.wait(math.floor(remaining), function()
    return predicate() or self.error ~= nil or self.closed
  end, 10)
  if self.error then
    error(self.error)
  end
  if not predicate() then
    if not ready then
      error("DAP probe timed out")
    end
    error("DAP adapter exited before completing the request")
  end
end
function Session:response(seq)
  self:await(function()
    return self.pending[seq] ~= nil
  end)
  local reply = self.pending[seq]
  self.pending[seq] = nil
  if not reply.success then
    error(reply.message or "DAP request failed")
  end
  return reply.body or {}
end
function Session:rpc(command, args)
  return self:response(self:request(command, args))
end
local function connect(cmd, root, timeout)
  assert(type(cmd) == "table", "debug.connect: cmd must be an argv table")
  assert(type(timeout) == "number", "debug.connect: timeout must be milliseconds")
  local session = setmetatable({
    seq = 0,
    pending = {},
    events = {},
    input = "",
    output = "",
    initialized = false,
    closed = false,
    timeout = timeout,
  }, Session)
  session.deadline = vim.uv.hrtime() / 1e6 + timeout
  session.process = vim.system(cmd, {
    cwd = root,
    stdin = true,
    stdout = function(err, data)
      vim.schedule(function()
        if err then
          session.error = tostring(err)
        end
        if data and not session.closed then
          local ok, message = pcall(session.feed, session, data)
          if not ok then
            session.error = tostring(message)
          end
        end
      end)
    end,
    stderr = function(_, data)
      if data then
        session.stderr = ((session.stderr or "") .. data):sub(-dap_stderr_bytes_max)
      end
    end,
  }, function()
    vim.schedule(function()
      session.closed = true
    end)
  end)
  return session
end

local function close(session)
  if not session then
    return
  end
  if not session.closed then
    pcall(session.request, session, "disconnect", { terminateDebuggee = true })
    -- Give the adapter a bounded opportunity to terminate its launched process.
    vim.wait(500, function()
      return session.closed
    end, 10)
    pcall(session.process.write, session.process, nil)
    if not session.closed then
      pcall(session.process.kill, session.process, 15)
    end
    vim.defer_fn(function()
      if not session.closed then
        pcall(session.process.kill, session.process, 9)
      end
    end, 500)
  end
end

function M.stop()
  if active then
    active.error = "DAP probe cancelled"
    close(active)
    active = nil
  end
end

function M.status()
  local config = options.debug or {}
  local names = vim.tbl_keys(config.configurations or {})
  table.sort(names)
  return {
    status = #names > 0 and "ok" or "unavailable",
    backend = "rose-stdio-dap",
    transport = "stdio",
    configurations = names,
    active = active ~= nil,
    verified = false,
    limitations = "Named launch probes only; no TCP adapters, attach, evaluate, or interactive UI",
  }
end

local probe_timeout_ms_default = 30000
local probe_timeout_ms_max = 120000
local stack_levels_max = 20

-- Resolve configured breakpoint paths to real files inside the workspace.
-- Returns the DAP setBreakpoints argument list, or nil plus an operating error.
local function probe_breakpoints(config, root)
  local breakpoints = {}
  for path, lines in pairs(config.breakpoints or {}) do
    local real = vim.uv.fs_realpath(vim.fs.joinpath(root, path))
    if not real or not inside(vim.fs.normalize(real), root) then
      return nil, "Breakpoint path escapes workspace"
    end
    local points = {}
    for _, line in ipairs(lines) do
      if type(line) ~= "number" or line < 1 or line % 1 ~= 0 then
        return nil, "Invalid breakpoint line"
      end
      points[#points + 1] = { line = line }
    end
    breakpoints[#breakpoints + 1] = { source = { path = real }, breakpoints = points }
  end
  return breakpoints
end

-- Drive the DAP handshake: initialize, launch, breakpoints, configurationDone, first stop.
local function probe_launch(session, config, launch, breakpoints)
  local capabilities = session:rpc("initialize", {
    clientID = "rose.nvim",
    adapterID = config.adapter,
    pathFormat = "path",
    linesStartAt1 = true,
    columnsStartAt1 = true,
    supportsRunInTerminalRequest = false,
    supportsVariableType = true,
  })
  local launch_id = session:request("launch", launch)
  session:await(function()
    return session.initialized or session.pending[launch_id] ~= nil
  end)
  if session.pending[launch_id] and not session.pending[launch_id].success then
    session:response(launch_id)
  end
  session:await(function()
    return session.initialized or session.terminated
  end)
  local bp_results = {}
  for _, bp in ipairs(breakpoints) do
    bp_results[#bp_results + 1] = session:rpc("setBreakpoints", bp)
  end
  if capabilities.supportsConfigurationDoneRequest then
    session:rpc("configurationDone")
  end
  session:response(launch_id)
  session:await(function()
    return session.stopped ~= nil or session.terminated == true
  end)
  return bp_results
end

local function probe_observe(session, name, bp_results)
  local observation = {
    status = "ok",
    verified = false,
    name = name,
    backend = "rose-stdio-dap",
    breakpoints = bp_results,
    events = session.events,
    output = session.output,
  }
  if session.stopped then
    local thread_id = session.stopped.threadId
    if not thread_id then
      local threads = session:rpc("threads").threads or {}
      thread_id = threads[1] and threads[1].id
    end
    observation.stopped = session.stopped
    if thread_id then
      observation.stack =
        session:rpc("stackTrace", { threadId = thread_id, levels = stack_levels_max })
      local frames = observation.stack.stackFrames or {}
      if frames[1] then
        observation.scopes = session:rpc("scopes", { frameId = frames[1].id })
        -- Variable enumeration can evaluate properties in some adapters.
        -- Scope/stack data are enough for a non-evaluating probe by default.
      end
    end
    observation.reason = "Stopped event observed; this is debugging evidence, not a passing test"
    if session.stopped.reason == "exception" then
      observation.status = "failed"
    end
  else
    observation.exit_code = session.exit_code
    observation.status = session.exit_code == 0 and "ok"
      or (session.exit_code ~= nil and "failed" or "unverified")
    observation.reason = "Debuggee terminated; exit code is evidence only, not test coverage"
  end
  return observation
end

-- Validate configuration and workspace boundaries; returns a plan table or a fail() result.
local function probe_plan(name)
  local debug_opts = options.debug or {}
  local config = (debug_opts.configurations or {})[name]
  if type(config) ~= "table" then
    return nil, fail("Unknown named debug configuration: " .. tostring(name))
  end
  local adapter = (debug_opts.adapters or {})[config.adapter]
  if type(adapter) ~= "table" or type(adapter.cmd) ~= "table" or #adapter.cmd == 0 then
    return nil, fail("A stdio adapter.cmd argv list is required", "unavailable")
  end
  local root = vim.uv.fs_realpath(options.workspace or vim.fn.getcwd())
  if not root then
    return nil, fail("Workspace does not exist")
  end
  root = vim.fs.normalize(root):gsub("/+$", "")
  if root == "" then
    return nil, fail("Filesystem root is not a supported trusted workspace")
  end
  local argv = expand(adapter.cmd, root)
  if vim.fn.executable(argv[1]) ~= 1 then
    return nil, fail("Debug adapter is not installed: " .. argv[1], "unavailable")
  end
  local launch = expand(config.launch or {}, root)
  if launch.request and launch.request ~= "launch" then
    return nil, fail("Only launch probes are supported")
  end
  launch.request = nil
  launch.cwd = launch.cwd or root
  -- Checks and debuggers execute trusted code, not an OS sandbox. Restrict the
  -- launch directory and source files; only user configuration supplies argv.
  local cwd = vim.uv.fs_realpath(launch.cwd)
  if not cwd or not inside(vim.fs.normalize(cwd), root) then
    return nil, fail("Debug cwd is outside workspace")
  end
  local breakpoints, bp_err = probe_breakpoints(config, root)
  if not breakpoints then
    return nil, fail(bp_err)
  end
  return { config = config, root = root, argv = argv, launch = launch, breakpoints = breakpoints }
end

local function probe(name)
  if options.trusted ~= true then
    return fail("Debug probes require a trusted workspace")
  end
  if active then
    return fail("A debug probe is already running")
  end
  local plan, failure = probe_plan(name)
  if not plan then
    return failure
  end
  local timeout_ms = math.min(plan.config.timeout or probe_timeout_ms_default, probe_timeout_ms_max)
  local session
  local ok, result = pcall(function()
    session = connect(plan.argv, plan.root, timeout_ms)
    active = session
    local bp_results = probe_launch(session, plan.config, plan.launch, plan.breakpoints)
    return probe_observe(session, name, bp_results)
  end)
  close(session)
  active = nil
  if not ok then
    local out = fail(result, tostring(result):find("timed out", 1, true) and "timeout" or "error")
    out.stderr = session and session.stderr or nil
    return out
  end
  return result
end

function M.call(args)
  args = args or {}
  if args.action == nil or args.action == "status" then
    return M.status()
  end
  if args.action ~= "run" then
    return fail("Unknown debug action")
  end
  -- The model can select a name, never executable commands or launch arguments.
  for key in pairs(args) do
    if key ~= "action" and key ~= "name" and key ~= "path" then
      return fail("Unexpected debug argument: " .. key)
    end
  end
  return probe(args.name)
end

return M
