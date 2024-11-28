local Anthropic = require("rose.provider.anthropic")
local Gemini = require("rose.provider.gemini")
local Groq = require("rose.provider.groq")
local Mistral = require("rose.provider.mistral")
local Nvidia = require("rose.provider.nvidia")
local Ollama = require("rose.provider.ollama")
local OpenAI = require("rose.provider.openai")
local Perplexity = require("rose.provider.perplexity")
local GitHub = require("rose.provider.github")
local xAI = require("rose.provider.xai")
local logger = require("rose.logger")

local M = {}

---@param prov_name string
---@param endpoint string
---@param api_key string|table
---@return table
M.init_provider = function(prov_name, endpoint, api_key)
  local providers = {
    anthropic = Anthropic,
    gemini = Gemini,
    github = GitHub,
    groq = Groq,
    mistral = Mistral,
    nvidia = Nvidia,
    ollama = Ollama,
    openai = OpenAI,
    pplx = Perplexity,
    xai = xAI,
  }

  local ProviderClass = providers[prov_name]
  if not ProviderClass then
    logger.error("Unknown provider " .. prov_name)
    return {}
  end

  -- For Ollama, we don't need an API key, so skip the API key prompt
  if prov_name == "ollama" then
    return ProviderClass:new(endpoint, {}) -- Pass an empty table for the API key
  end

  -- Check if API key is provided for other providers
  if not api_key or (type(api_key) == "table" and #api_key == 0) then
    vim.ui.input({ prompt = "Enter API key for " .. prov_name .. ": " }, function(input)
      if input then
        vim.fn.setenv(prov_name:upper() .. "_API_KEY", input)
        -- Now that we have the API key, initialize the provider
        return ProviderClass:new(endpoint, input)
      else
        logger.error("API key is required for provider " .. prov_name)
      end
    end)
    return {}
  end

  -- If API key is passed directly, initialize the provider
  return ProviderClass:new(endpoint, api_key)
end

return M
