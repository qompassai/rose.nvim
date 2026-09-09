-- Shared /api/chat wire protocol supported by qompassai/rose and Ollama.
-- Provider-specific endpoint and TLS policy is enforced by the HTTP transport.
local M = {}

function M.chat(config, provider, messages, tools, callback)
  local label = provider == "rose" and "Rose" or "Ollama"
  local payload = { model = config.model, messages = messages, stream = false }
  if tools and #tools > 0 then
    payload.tools = tools
  end
  if config.options then
    payload.options = config.options
  end
  local ok, body = pcall(vim.json.encode, payload)
  if not ok then
    vim.schedule(function()
      callback("cannot encode model request: " .. tostring(body))
    end)
    return { cancel = function() end }
  end
  return require("rose.native.http").request({
    provider = provider,
    url = config.base_url:gsub("/+$", "") .. "/api/chat",
    body = body,
    timeout = config.timeout,
    allow_remote = config.allow_remote,
    transport = config.transport,
    tls = config.tls,
  }, function(err, data)
    if err then
      callback(err)
      return
    end
    if type(data) ~= "string" then
      callback("invalid " .. label .. " JSON response")
      return
    end
    local decoded, response = pcall(vim.json.decode, data)
    if not decoded or type(response) ~= "table" then
      callback("invalid " .. label .. " JSON response")
      return
    end
    if response.error then
      callback(label .. ": " .. tostring(response.error))
      return
    end
    local message = response.message
    if
      type(message) ~= "table"
      or (type(message.content) ~= "string" and type(message.tool_calls) ~= "table")
    then
      callback(label .. " response is missing an assistant message")
      return
    end
    message.role = "assistant"
    callback(nil, message)
  end)
end

return M
