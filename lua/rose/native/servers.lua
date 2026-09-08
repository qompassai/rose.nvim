-- Third-party executable trust is distinct from workspace edit trust.
local M = { clients = {} }

function M.setup(config)
  M.stop()
  M.config = config
end

function M.call(server_name, tool_name, args, callback)
  local config = M.config.mcp.servers[server_name]
  local cancelled, request = false, nil
  local token = {
    cancel = function()
      cancelled = true
      if request then
        request.cancel()
      end
    end,
  }
  local function reject(message)
    vim.schedule(function()
      callback(message)
    end)
    return token
  end
  if type(config) ~= "table" or config.trusted ~= true or config.read_only ~= true then
    return reject("MCP server requires explicit trusted=true and read_only=true configuration")
  end
  local allowed = false
  for _, name in ipairs(config.allow_tools or {}) do
    if name == tool_name then
      allowed = true
    end
  end
  if not allowed then
    return reject("MCP tool is not in server allow_tools")
  end
  local function invoke(err, client)
    if cancelled then
      callback("cancelled")
      return
    end
    if err then
      callback(err)
      return
    end
    request = client:call_tool(tool_name, args, function(call_err, result)
      if not call_err and type(result) == "table" and result.isError then
        call_err = "MCP tool returned isError=true"
      end
      callback(call_err, result)
    end, config.timeout)
  end
  local client = M.clients[server_name]
  if client and client.ready and not client.closed then
    invoke(nil, client)
  elseif client and not client.closed then
    return reject("MCP server is still initializing; retry after initialization")
  else
    M.clients[server_name] = require("rose.native.mcp").start({
      cmd = config.cmd,
      cwd = M.config.workspace,
      timeout = config.timeout,
      env = config.env,
    }, invoke)
  end
  return token
end

function M.stop()
  for _, client in pairs(M.clients) do
    client:close("MCP servers stopped")
  end
  M.clients = {}
end

return M
