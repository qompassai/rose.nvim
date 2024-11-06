local OpenAI = require("rose.provider.openai")
local utils = require("rose.utils")

local GitHub = setmetatable({}, { __index = OpenAI })
GitHub.__index = GitHub

-- Available API parameters for GitHub models
local AVAILABLE_API_PARAMETERS = {
  -- required
  messages = true,
  model = true,
  -- optional
  max_tokens = true,
  temperature = true,
  top_p = true,
  stop = true,
  best_of = true,
  presence_penalty = true,
  stream = true,
}

function GitHub:new(endpoint, api_key)
  local instance = OpenAI.new(self, endpoint, api_key)
  instance.name = "github"
  return setmetatable(instance, self)
end

-- Preprocesses the payload before sending to the API
---@param payload table
---@return table
function GitHub:preprocess_payload(payload)
  for _, message in ipairs(payload.messages) do
    message.content = message.content:gsub("^%s*(.-)%s*$", "%1")
  end
  return utils.filter_payload_parameters(AVAILABLE_API_PARAMETERS, payload)
end

-- Returns the list of available models
---@param online boolean
---@return string[]
function GitHub:get_available_models(online)
  return {
    -- AI21 Labs Models
    "ai21-jamba-1.5-large",
    "ai21-jamba-1.5-mini",
    -- Cohere Models
    "cohere-command-r",
    "cohere-command-r-plus",
    "cohere-command-r-08-2024",
    "cohere-command-r-plus-08-2024",
    -- Core42 Models
    "jais-30b-chat",
    -- Meta Models
    "meta-llama-3.1-405b-instruct",
    "meta-llama-3.1-70b-instruct",
    "meta-llama-3.1-8b-instruct",
    "llama-3.2-11b-vision-instruct",
    "llama-3.2-90b-vision-instruct",
    -- Microsoft Phi Models
    "phi-3.5-moe-instruct-128k",
    "phi-3.5-mini-instruct-128k",
    "phi-3.5-vision-instruct-128k",
    "phi-3-medium-instruct-128k",
    "phi-3-medium-instruct-4k",
    "phi-3-mini-instruct-128k",
    "phi-3-mini-instruct-4k",
    "phi-3-small-instruct-128k",
    "phi-3-small-instruct-8k",
    -- Mistral AI
    "mistral-large",
    "mistral-large-2407",
    "mistral-small",
    "mistral-nemo",
    "ministral-3b",
    -- OpenAI
    "gpt-4o",
    "gpt-4o-mini",
    "o1-preview",
    "o1-mini"
  }
end

return GitHub

