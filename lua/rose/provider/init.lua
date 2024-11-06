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

---@param prov_name string # name of the provider
---@param endpoint string # API endpoint for the provider
---@param api_key string|table # API key or routine for authentication
---@return table # returns initialized provider
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
  return ProviderClass:new(endpoint, api_key)
end

return M
