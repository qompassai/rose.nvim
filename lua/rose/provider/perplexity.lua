local logger = require("rose.logger")
local utils = require("rose.utils")
local Job = require("plenary.job")

---@class Perplexity
---@field endpoint string
---@field api_key string|table
---@field name string
local Perplexity = {}
Perplexity.__index = Perplexity

-- Available API parameters for Perplexity
-- https://docs.perplexity.ai/api-reference/chat-completions
local AVAILABLE_API_PARAMETERS = {
  -- required
  model = true,
  messages = true,
  -- optional
  max_tokens = true,
  temperature = true,
  top_p = true,
  return_citations = true,
  search_domain_filter = true,
  return_images = true,
  return_related_questions = true,
  search_recency_filter = true,
  top_k = true,
  stream = true,
  presence_penalty = true,
  frequency_penalty = true,
}

-- Creates a new Perplexity instance
---@param endpoint string
---@param api_key string|table
---@return Perplexity
function Perplexity:new(endpoint, api_key)
  return setmetatable({
    endpoint = endpoint,
    api_key = api_key,
    name = "pplx",
  }, self)
end

-- Placeholder for setting model (not implemented)
function Perplexity:set_model(_) end

-- Preprocesses the payload before sending to the API
---@param payload table
---@return table
function Perplexity:preprocess_payload(payload)
  for _, message in ipairs(payload.messages) do
    message.content = message.content:gsub("^%s*(.-)%s*$", "%1")
  end
  return utils.filter_payload_parameters(AVAILABLE_API_PARAMETERS, payload)
end

-- Returns the curl parameters for the API request
---@return table
function Perplexity:curl_params()
  return {
    self.endpoint,
    "-H",
    "authorization: Bearer " .. self.api_key,
  }
end

-- Verifies the API key or executes a routine to retrieve it
---@return boolean
function Perplexity:verify()
  if type(self.api_key) == "table" then
    local command = table.concat(self.api_key, " ")
    local handle = io.popen(command)
    if handle then
      self.api_key = handle:read("*a"):gsub("%s+", "")
      handle:close()
      return true
    else
      logger.error("Error verifying API key of " .. self.name)
      return false
    end
  elseif self.api_key and self.api_key:match("%S") then
    return true
  else
    logger.error("Error with API key " .. self.name .. " " .. vim.inspect(self.api_key))
    return false
  end
end

-- Processes the stdout from the API response
---@param response string
---@return string|nil
function Perplexity:process_stdout(response)
  if response:match("chat%.completion%.chunk") or response:match("chat%.completion") then
    local success, content = pcall(vim.json.decode, response)
    if
      success
      and content.choices
      and content.choices[1]
      and content.choices[1].delta
      and content.choices[1].delta.content
    then
      return content.choices[1].delta.content
    else
      logger.debug("Could not process response: " .. response)
    end
  end
end

-- Processes the onexit event from the API response
---@param res string
function Perplexity:process_onexit(res)
  local parsed = res:match("<h1>(.-)</h1>")
  if parsed then
    logger.error("Perplexity - message: " .. parsed)
  end
end

-- Returns the list of available models
---@return string[]
function Perplexity:get_available_models()
  -- Base models available to all users
  local base_models = {
    -- Perplexity Sonar Online Models (128k context)
    "llama-3.1-sonar-small-128k-online",    -- 8B parameters
    "llama-3.1-sonar-large-128k-online",    -- 70B parameters
    "llama-3.1-sonar-huge-128k-online",     -- 405B parameters
    -- Perplexity Chat Models (128k context)
    "llama-3.1-sonar-small-128k-chat",
    "llama-3.1-sonar-large-128k-chat",
    -- Open Source Models (131k context)
    "llama-3.1-8b-instruct",
    "llama-3.1-70b-instruct"
  }

  -- Check if user has Pro access
  local is_pro = self:verify_pro_access()
  -- Add Pro models if user has access
  if is_pro then
    local pro_models = {
      -- Pro Models (32k context)
      "gpt-4-omni",                           -- OpenAI's latest
      "claude-3.5-sonnet",                    -- Anthropic's fast model
      "claude-3-opus",                        -- Anthropic's most capable
      "sonar-large-32k",                      -- LlaMa 3.1 70B optimized
      "pplx-default",                         -- Fast browsing optimized
      -- Beta Access Models
      "claude-3-sonnet-20240229",            -- Latest Sonnet version
      "claude-3-opus-20240229",              -- Latest Opus version
      "claude-3-haiku-20240307"              -- Fastest Claude version
    }
    -- Combine base and pro models
    for _, model in ipairs(pro_models) do
      table.insert(base_models, model)
    end
    logger.info("Perplexity Pro models enabled")
  else
    logger.info("Using Perplexity Free tier models")
  end

  return base_models
end

-- Add function to verify Pro access
function Perplexity:verify_pro_access()
  if not self:verify() then
    return false
  end
  -- Make API call to check subscription status
  local job = Job:new({
    command = "curl",
    args = {
      "https://api.perplexity.ai/account/subscription",
      "-H",
      "Authorization: Bearer " .. self.api_key,
    },
    on_exit = function(j)
      local response = utils.parse_raw_response(j:result())
      if response then
        local success, decoded = pcall(vim.json.decode, response)
        if success and decoded and decoded.tier == "pro" then
          return true
        end
      end
      return false
    end
  })
  job:sync()
  return job:result()
end

return Perplexity
