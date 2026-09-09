-- Full-config router. Rose is the default; Ollama is compatibility, cloud is opt-in.
local M = {}
local function name(config)
  if type(config.providers) == "table" and config.providers.provider ~= nil then
    return config.providers.provider
  end
  return config.ollama ~= nil and config.rose == nil and "ollama" or "rose"
end

local function is_local(provider)
  return provider == "rose" or provider == "ollama"
end

function M.validate(config)
  if type(config) ~= "table" then
    return nil, "model configuration must be a table"
  end
  local provider = name(config)
  if is_local(provider) then
    local section = config[provider]
    if type(section) ~= "table" then
      return nil, provider .. " configuration must be a table"
    end
    local why = require("rose.native.http").validate({
      provider = provider,
      url = section.base_url,
      allow_remote = section.allow_remote,
      transport = section.transport,
      tls = section.tls,
    })
    if why then
      return nil, why
    end
    return true
  end
  local ok, result = pcall(require("rose.providers").resolve, config)
  if not ok then
    return nil, tostring(result):gsub("^.-:%d+:%s*", "")
  end
  return true
end

function M.describe(config)
  local provider = name(config)
  local selected = is_local(provider) and config[provider]
    or (config.providers and config.providers[provider])
  return {
    provider = provider,
    model = type(selected) == "table" and selected.model or nil,
    cloud = not is_local(provider),
  }
end

function M.capabilities(config)
  if is_local(name(config)) then
    return {
      provider = name(config),
      cloud = false,
      tools = true,
      chat = true,
      json_request = false,
      sse = false,
    }
  end
  local ok, selected, api = pcall(require("rose.providers").resolve, config)
  if not ok then
    return { provider = name(config), cloud = true, enabled = false, tools = false }
  end
  return {
    provider = selected.name,
    api = selected.api,
    cloud = true,
    enabled = true,
    chat = true,
    tools = api.tools and selected.capabilities.tools == true,
    json_request = true,
    sse = true,
    chat_streaming = false,
    opaque_replay = true,
    citations = true,
    realtime = false,
    multipart = false,
    binary_media = false,
  }
end

function M.chat(config, messages, tools, callback)
  local provider = name(config)
  if is_local(provider) then
    return require("rose.native." .. provider).chat(config[provider], messages, tools, callback)
  end
  return require("rose.providers").chat(config, messages, tools, callback)
end

function M.request(config, spec, callback)
  if is_local(name(config)) then
    vim.schedule(function()
      callback("generic authenticated JSON requests require an explicitly selected cloud provider")
    end)
    return { cancel = function() end }
  end
  return require("rose.providers").request(config, spec, callback)
end

function M.stop()
  if package.loaded["rose.providers.transport"] then
    package.loaded["rose.providers.transport"].stop()
  end
end

return M
