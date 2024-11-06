local logger = require("rose.logger")
local utils = require("rose.utils")
local Job = require("plenary.job")
local websocket = require("websocket.client")

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
  max_tokens = false,
  temperature = true,
  top_p = true,
  return_citations = true,
  search_domain_filter = true,
  return_images = true,
  return_related_questions = true,
  search_recency_filter = true,
  top_k = true,
  stream = false,
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
  -- Explicitly convert numeric parameters to ensure correct types
  if payload.temperature then
    payload.temperature = tonumber(payload.temperature)
  end
  if payload.max_tokens then
    payload.max_tokens = tonumber(payload.max_tokens)
  end
  if payload.top_p then
    payload.top_p = tonumber(payload.top_p)
  end
  if payload.presence_penalty then
    payload.presence_penalty = tonumber(payload.presence_penalty)
  end
  if payload.frequency_penalty then
    payload.frequency_penalty = tonumber(payload.frequency_penalty)
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
  local success, content = pcall(vim.json.decode, response)
  if
    success
    and content.choices
    and content.choices[1]
    and content.choices[1].message
    and content.choices[1].message.content
  then
    return content.choices[1].message.content
  else
    logger.debug("Could not process response: " .. response)
  end
end

-- Processes the onexit event from the API response
---@param res string
function Perplexity:process_onexit(res)
  local success, parsed = pcall(vim.json.decode, res)
  if success and parsed.error and parsed.error.message then
    logger.error(
      string.format(
        "Perplexity - code: %s message: %s type: %s",
        parsed.error.code or "N/A",
        parsed.error.message,
        parsed.error.type or "N/A"
      )
    )
  elseif success and parsed.choices and parsed.choices[1] and parsed.choices[1].message then
    return parsed.choices[1].message.content
  end
end

-- Returns the list of available models
---@return string[]
function Perplexity:get_available_models()
  local base_models = {
    "llama-3.1-sonar-small-128k-online",
    "llama-3.1-sonar-large-128k-online",
    "llama-3.1-sonar-huge-128k-online",
    "llama-3.1-sonar-small-128k-chat",
    "llama-3.1-sonar-large-128k-chat",
    "llama-3.1-8b-instruct",
    "llama-3.1-70b-instruct"
  }

  local is_pro = self:verify_pro_access()
  if is_pro then
    table.insert(base_models, "gpt-4-omni")
    table.insert(base_models, "claude-3.5-sonnet")
    table.insert(base_models, "claude-3-opus")
    table.insert(base_models, "sonar-large-32k")
    table.insert(base_models, "pplx-default")
  end

  return base_models
end

-- Add function to verify Pro access
function Perplexity:verify_pro_access()
  if not self:verify() then
    return false
  end
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

-- Sends a user query to the API for text generation
---@param payload table
---@param callback function
function Perplexity:send_query(payload, callback)
  if not self:verify() then
    logger.error("API key verification failed")
    return
  end

  payload = self:preprocess_payload(payload)
  local job = Job:new({
    command = "curl",
    args = {
      "-X", "POST",
      self.endpoint,
      "-H", "Authorization: Bearer " .. self.api_key,
      "-H", "Content-Type: application/json",
      "-d", vim.json.encode(payload)
    },
    on_exit = function(j)
      local response = table.concat(j:result(), "\n")
      local result = self:process_stdout(response)
      if result then
        callback(result)
      else
        logger.error("Failed to retrieve valid response")
      end
    end
  })
  job:start()
end

-- Sends a user query using WebSocket for real-time interaction
---@param payload table
---@param callback function
function Perplexity:send_query_ws(payload, callback)
  if not self:verify() then
    logger.error("API key verification failed")
    return
  end

  local ws_url = "wss://api.perplexity.ai/realtime"
  local client = websocket()

  client:on_open(function()
    local message = vim.json.encode(payload)
    client:send(message)
  end)

  client:on_message(function(_, message)
    local success, parsed_message = pcall(vim.json.decode, message)
    if success and parsed_message.choices and parsed_message.choices[1] then
      callback(parsed_message.choices[1].message.content)
    else
      logger.error("Failed to parse WebSocket message: " .. message)
    end
  end)

  client:on_error(function(_, err)
    logger.error("WebSocket error: " .. err)
  end)

  client:on_close(function(_, code, reason)
    logger.info(string.format("WebSocket closed - Code: %s, Reason: %s", code, reason))
  end)

  client:connect(ws_url, nil, {
    headers = {
      ["Authorization"] = "Bearer " .. self.api_key,
      ["Content-Type"] = "application/json",
    }
  })
end

-- Fixes to prevent repeated outputs and hallucinations
---@param response string
function Perplexity:remove_repeated_text(response)
  return response:gsub("%b<>", ""):gsub("%f[%w](%w+)%f[%W]%s*%1", "%1")
end

return Perplexity

