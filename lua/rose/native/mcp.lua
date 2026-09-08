-- MCP stdio: one JSON-RPC 2.0 object per line. No shell, LSP framing or plugins.
local M = { clients = {} }
local Client = {}
Client.__index = Client
local versions =
  { ["2025-11-25"] = true, ["2025-06-18"] = true, ["2025-03-26"] = true, ["2024-11-05"] = true }

local function defer(callback, err, result)
  if callback then
    vim.schedule(function()
      callback(err, result)
    end)
  end
end

local function stop_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

function Client:_send(message)
  if self.closed or not self.process then
    return nil, "MCP client is closed"
  end
  local ok, encoded = pcall(vim.json.encode, message)
  if not ok then
    return nil, "MCP encoding failed: " .. tostring(encoded)
  end
  if #encoded > self.max_message then
    return nil, "MCP request exceeds size limit"
  end
  local written, err = pcall(self.process.write, self.process, encoded .. "\n")
  if not written then
    return nil, "MCP write failed: " .. tostring(err)
  end
  return true
end

function Client:_complete(id, err, result)
  local pending = self.pending[id]
  if not pending then
    return
  end
  self.pending[id] = nil
  stop_timer(pending.timer)
  defer(pending.callback, err, result)
end

function Client:notify(method, params)
  return self:_send({ jsonrpc = "2.0", method = method, params = params or vim.empty_dict() })
end

function Client:request(method, params, callback, timeout)
  local token = { cancel = function() end }
  if self.closed then
    defer(callback, "MCP client is closed")
    return token
  end
  self.sequence = self.sequence + 1
  local id = self.sequence
  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()
  self.pending[id] = { callback = callback, timer = timer }
  function token.cancel()
    if not self.pending[id] then
      return
    end
    self:notify("notifications/cancelled", { requestId = id, reason = "client cancelled" })
    self:_complete(id, "cancelled")
  end
  timer:start(
    timeout or self.timeout,
    0,
    vim.schedule_wrap(function()
      if not self.pending[id] then
        return
      end
      self:notify("notifications/cancelled", { requestId = id, reason = "request timeout" })
      self:_complete(id, "MCP timeout: " .. method)
    end)
  )
  local ok, err =
    self:_send({ jsonrpc = "2.0", id = id, method = method, params = params or vim.empty_dict() })
  if not ok then
    self:_complete(id, err)
  end
  return token
end

function Client:_message(message)
  if type(message) ~= "table" or message.jsonrpc ~= "2.0" then
    self:close("MCP protocol error: expected JSON-RPC 2.0 object")
    return
  end
  if message.method then
    if message.id ~= nil and message.id ~= vim.NIL then
      -- Never execute server-requested sampling, elicitation, roots or arbitrary
      -- editor commands. ping is the only supported server -> client request.
      local response = { jsonrpc = "2.0", id = message.id }
      if message.method == "ping" then
        response.result = vim.empty_dict()
      else
        response.error =
          { code = -32601, message = "Unsupported server request: " .. tostring(message.method) }
      end
      self:_send(response)
    elseif message.method == "notifications/cancelled" and type(message.params) == "table" then
      self:_complete(message.params.requestId, "MCP server cancelled request")
    end
    return
  end
  if type(message.id) ~= "number" and type(message.id) ~= "string" then
    self:close("MCP protocol error: response has no valid id")
    return
  end
  if message.error then
    local error_text = type(message.error) == "table" and message.error.message or message.error
    self:_complete(message.id, "MCP: " .. tostring(error_text))
  elseif message.result ~= nil then
    self:_complete(message.id, nil, message.result)
  else
    self:_complete(message.id, "MCP protocol error: missing result/error")
  end
end

function Client:_stdout(err, chunk)
  if self.closed then
    return
  end
  if err then
    self:close("MCP stdout error: " .. tostring(err))
    return
  end
  if not chunk then
    return
  end
  self.buffer = self.buffer .. chunk
  if #self.buffer > self.max_message then
    self:close("MCP message exceeds size limit")
    return
  end
  while not self.closed do
    local newline = self.buffer:find("\n", 1, true)
    if not newline then
      break
    end
    local line = self.buffer:sub(1, newline - 1):gsub("\r$", "")
    self.buffer = self.buffer:sub(newline + 1)
    if line ~= "" then
      local ok, message = pcall(vim.json.decode, line)
      if not ok then
        self:close("MCP protocol error: non-JSON stdout")
        return
      end
      self:_message(message)
    end
  end
end

function Client:list_tools(callback)
  return self:request("tools/list", vim.empty_dict(), function(err, result)
    if not err and (type(result) ~= "table" or type(result.tools) ~= "table") then
      err = "MCP tools/list missing tools array"
    end
    callback(err, result)
  end)
end

function Client:call_tool(name, args, callback, timeout)
  if type(args) == "table" and next(args) == nil then
    args = vim.empty_dict()
  end
  return self:request(
    "tools/call",
    { name = name, arguments = args or vim.empty_dict() },
    callback,
    timeout
  )
end

function Client:close(reason)
  if self.closed then
    return
  end
  self.closed = true
  M.clients[self] = nil
  local ids = {}
  for id in pairs(self.pending) do
    ids[#ids + 1] = id
  end
  for _, id in ipairs(ids) do
    self:_complete(id, reason or "MCP client closed")
  end
  if self.process and not self.exited then
    -- MCP defines EOF/process termination, not an invented "shutdown" method.
    pcall(self.process.write, self.process, nil)
    pcall(self.process.kill, self.process, 15)
    local uv = vim.uv or vim.loop
    self.kill_timer = uv.new_timer()
    self.kill_timer:start(500, 0, function()
      if not self.exited then
        pcall(self.process.kill, self.process, 9)
      end
      stop_timer(self.kill_timer)
      self.kill_timer = nil
    end)
  end
end

local mcp_timeout_ms_default = 30000
local mcp_initialize_timeout_ms_default = 10000
local mcp_message_bytes_max_default = 8 * 1024 * 1024
local mcp_stderr_bytes_max = 8192
local mcp_protocol_version = "2025-11-25"

-- Operating error for a malformed argv, or nil when it can be spawned.
local function argv_error(cmd)
  if type(cmd) ~= "table" or #cmd == 0 then
    return "MCP cmd must be an explicit argv array"
  end
  for _, arg in ipairs(cmd) do
    if type(arg) ~= "string" or arg:find("\0", 1, true) then
      return "MCP argv must contain strings without NUL"
    end
  end
  return nil
end

-- Handshake completion: validate the server's version, then announce readiness.
local function on_initialized(self, callback, err, result)
  if err then
    self:close(err)
    callback(err)
    return
  end
  if type(result) ~= "table" or not versions[result.protocolVersion] then
    self:close("unsupported MCP protocol version")
    callback("unsupported MCP protocol version")
    return
  end
  self.protocol_version, self.capabilities = result.protocolVersion, result.capabilities or {}
  local sent, send_err = self:notify("notifications/initialized")
  if not sent then
    self:close(send_err)
    callback(send_err)
    return
  end
  self.ready = true
  callback(nil, self)
end

function M.start(opts, callback)
  assert(type(opts) == "table", "MCP start requires an options table")
  assert(type(callback) == "function", "MCP start requires callback(err, client)")
  local self = setmetatable({
    pending = {},
    sequence = 0,
    buffer = "",
    stderr = "",
    timeout = opts.timeout or mcp_timeout_ms_default,
    max_message = opts.max_message or mcp_message_bytes_max_default,
  }, Client)
  local function fail(err)
    self:close(err)
    defer(callback, err)
    return self
  end
  if type(vim.system) ~= "function" then
    return fail("MCP requires vim.system (Neovim 0.10+)")
  end
  local invalid = argv_error(opts.cmd)
  if invalid then
    return fail(invalid)
  end
  local ok, process = pcall(vim.system, opts.cmd, {
    cwd = opts.cwd,
    env = opts.env,
    stdin = true,
    stdout = function(err, data)
      vim.schedule(function()
        self:_stdout(err, data)
      end)
    end,
    stderr = function(_, data)
      if data then
        self.stderr = (self.stderr .. data):sub(-mcp_stderr_bytes_max)
      end
    end,
  }, function(result)
    vim.schedule(function()
      self.exited = true
      stop_timer(self.kill_timer)
      self.kill_timer = nil
      self:close("MCP process exited (" .. result.code .. "): " .. self.stderr)
    end)
  end)
  if not ok then
    return fail("MCP spawn failed: " .. tostring(process))
  end
  self.process = process
  M.clients[self] = true
  self:request("initialize", {
    protocolVersion = mcp_protocol_version,
    capabilities = vim.empty_dict(),
    clientInfo = { name = "rose.nvim", version = "0.2.0" },
  }, function(err, result)
    on_initialized(self, callback, err, result)
  end, opts.initialize_timeout or mcp_initialize_timeout_ms_default)
  return self
end

function M.stop()
  local clients = {}
  for client in pairs(M.clients) do
    clients[#clients + 1] = client
  end
  for _, client in ipairs(clients) do
    client:close()
  end
end

return M
