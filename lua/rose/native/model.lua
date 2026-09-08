-- Full-config router. Ollama remains the default; cloud is strictly opt-in.
local M = {}
local function name(config)
  return type(config.providers) == "table" and config.providers.provider or "ollama"
end

function M.validate(config)
  if type(config) ~= "table" then
    return nil, "model configuration must be a table"
  end
  if name(config) == "ollama" then
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
  local selected = provider == "ollama" and config.ollama
    or (config.providers and config.providers[provider])
  return {
    provider = provider,
    model = type(selected) == "table" and selected.model or nil,
    cloud = provider ~= "ollama",
  }
end

function M.capabilities(config)
  if name(config) == "ollama" then
    return {
      provider = "ollama",
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
  if name(config) == "ollama" then
    return require("rose.native.ollama").chat(config.ollama, messages, tools, callback)
  end
  return require("rose.providers").chat(config, messages, tools, callback)
end

function M.request(config, spec, callback)
  if name(config) == "ollama" then
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
