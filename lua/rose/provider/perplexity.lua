local Job = require("plenary.job")
local logger = require("rose.logger")
local utils = require("rose.utils")

---@class Perplexity
---@field endpoint string
---@field api_key string|string[]|nil
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
  stream = true,
  presence_penalty = true,
  frequency_penalty = true,
}

-- Allowed models for Perplexity API
local ALLOWED_MODELS = {
  "llama-3.1-sonar-small-128k-online",
  "llama-3.1-sonar-large-128k-online",
  "llama-3.1-sonar-huge-128k-online",
  "llama-3.1-sonar-small-128k-chat",
  "llama-3.1-sonar-large-128k-chat",
  "llama-3.1-8b-instruct",
  "llama-3.1-70b-instruct",
}

-- Creates a new Perplexity instance
---@param endpoint string
---@param api_key string|string[]|nil
---@return Perplexity
function Perplexity:new(endpoint, api_key)
  return setmetatable({
    endpoint = endpoint,
    api_key = api_key,
    name = "pplx",
  }, self)
end

-- Sets the model for the Perplexity instance
---@param model string
function Perplexity:set_model(model)
  if vim.tbl_contains(ALLOWED_MODELS, model) then
    self.model = model
  else
    logger.error("Invalid model specified. Only Sonar models are supported by the API.")
  end
end

-- Preprocesses the payload before sending to the API
---@param payload table
---@return table|nil
function Perplexity:preprocess_payload(payload)
  if type(payload.messages) ~= "table" then
    logger.error("Messages are required in the payload")
    return nil
  end
  for _, message in ipairs(payload.messages) do
    if type(message) ~= "table" or type(message.content) ~= "string" then
      logger.error("Messages must contain text content")
      return nil
    end
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

  -- Ensure only Sonar models are used
  if not vim.tbl_contains(ALLOWED_MODELS, payload.model) then
    logger.error("Invalid model specified. Only Sonar models are supported by the API.")
    return nil
  end

  return utils.filter_payload_parameters(AVAILABLE_API_PARAMETERS, payload)
end

-- Returns the curl parameters for the API request
---@return table
function Perplexity:curl_params()
  return {
    self.endpoint .. "/chat/completions",
    "-H",
    "Authorization: Bearer " .. self.api_key,
    "-H",
    "Content-Type: application/json",
  }
end

-- Verifies the API key or executes a routine to retrieve it
---@return boolean
function Perplexity:verify()
  local current_key = self.api_key
  if type(current_key) == "table" then
    local command = table.concat(current_key, " ")
    local handle, open_err = io.popen(command)
    if handle then
      local key, read_err = handle:read("*a")
      local closed, close_err = handle:close()
      if not key or not closed then
        logger.error(
          "Error reading API key of " .. self.name .. ": " .. tostring(read_err or close_err)
        )
        return false
      end
      key = key:gsub("%s+", "")
      if key == "" then
        logger.error("Empty API key of " .. self.name)
        return false
      end
      self.api_key = key
      return true
    else
      logger.error("Error verifying API key of " .. self.name .. ": " .. tostring(open_err))
      return false
    end
  elseif type(current_key) == "string" and current_key:match("%S") then
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
      and type(content) == "table"
      and type(content.choices) == "table"
      and type(content.choices[1]) == "table"
      and type(content.choices[1].delta) == "table"
      and type(content.choices[1].delta.content) == "string"
    then
      return content.choices[1].delta.content
    else
      logger.debug("Could not process response: " .. response)
    end
  end
end

-- Processes the onexit event from the API response
---@param response string
---@return string|nil
function Perplexity:process_onexit(response)
  local success, parsed = pcall(vim.json.decode, response)
  if not success or type(parsed) ~= "table" then
    return
  end
  if type(parsed.error) == "table" and type(parsed.error.message) == "string" then
    logger.error(
      string.format(
        "Perplexity - code: %s message: %s type: %s",
        parsed.error.code or "N/A",
        parsed.error.message,
        parsed.error.type or "N/A"
      )
    )
  elseif
    type(parsed.choices) == "table"
    and type(parsed.choices[1]) == "table"
    and type(parsed.choices[1].message) == "table"
    and type(parsed.choices[1].message.content) == "string"
  then
    return parsed.choices[1].message.content
  end
end

-- Sends a user query to the API for text generation
---@param payload table
---@param callback function
function Perplexity:send_query(payload, callback)
  if not self:verify() then
    logger.error("API key verification failed")
    return
  end

  -- Preprocess the payload as per API guidelines
  local processed = self:preprocess_payload(payload)
  if not processed then
    return
  end
  payload = processed
  payload.stream = true

  -- Align payload with Perplexity API's message structure
  if not payload.messages then
    logger.error("Messages are required in the payload")
    return
  end

  for i, message in ipairs(payload.messages) do
    if not message.role then
      if i == 1 then
        message.role = "system" -- Assume the first message is a system message unless otherwise specified
      else
        message.role = "user" -- Default to "user" for the rest
      end
    end
  end

  local job = Job:new({
    command = "curl",
    args = {
      "-X",
      "POST",
      unpack(self:curl_params()),
      "-d",
      vim.json.encode(payload),
    },
    on_exit = function(j)
      local lines = j:result()
      if type(lines) ~= "table" then
        logger.error("No query response received")
        return
      end
      local response = table.concat(lines, "\n")
      local result = self:process_onexit(response)
      if result then
        callback(result)
      else
        logger.error("Failed to retrieve valid response")
      end
    end,
  })
  job:start()
end

local function websocket_client()
  -- The historical path expects a callable factory. Do not assume an API for
  -- an absent or incompatible optional WebSocket implementation.
  local available, websocket = pcall(require, "websocket.client")
  if not available then
    logger.error("WebSocket client unavailable: " .. tostring(websocket))
    return
  end
  if type(websocket) ~= "function" then
    logger.error("WebSocket client unavailable: expected a client factory function")
    return
  end
  local created, client = pcall(websocket)
  if not created then
    logger.error("WebSocket client unavailable: " .. tostring(client))
    return
  end
  if
    type(client) ~= "table"
    or type(client.on_open) ~= "function"
    or type(client.on_message) ~= "function"
    or type(client.on_error) ~= "function"
    or type(client.on_close) ~= "function"
    or type(client.send) ~= "function"
    or type(client.connect) ~= "function"
  then
    logger.error("WebSocket client unavailable: incompatible client interface")
    return
  end
  return client
end

-- Sends a user query using WebSocket for real-time interaction
---@param payload table
---@param callback function
function Perplexity:send_query_ws(payload, callback)
  if not self:verify() then
    logger.error("API key verification failed")
    return
  end

  -- Ensure only Sonar models are used
  if not vim.tbl_contains(ALLOWED_MODELS, payload.model) then
    logger.error("Invalid model specified. Only Sonar models are supported by the API.")
    return
  end

  local client = websocket_client()
  if not client then
    return
  end
  local ws_url = "wss://api.perplexity.ai/realtime"

  client:on_open(function()
    local message = vim.json.encode(payload)
    client:send(message)
  end)

  client:on_message(function(_, message)
    local success, parsed_message = pcall(vim.json.decode, message)
    if
      success
      and type(parsed_message) == "table"
      and type(parsed_message.choices) == "table"
      and type(parsed_message.choices[1]) == "table"
      and type(parsed_message.choices[1].message) == "table"
      and type(parsed_message.choices[1].message.content) == "string"
    then
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
    },
  })
end

-- Returns the list of available models
---@return string[]
function Perplexity:get_available_models()
  return ALLOWED_MODELS
end

-- Fixes to prevent repeated outputs and hallucinations
---@param response string
function Perplexity:remove_repeated_text(response)
  return response:gsub("%b<>", ""):gsub("%f[%w](%w+)%f[%W]%s*%1", "%1")
end

return Perplexity
