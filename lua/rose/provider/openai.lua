local logger = require("rose.logger")
local utils = require("rose.utils")
local Job = require("plenary.job")
local websocket = require("resty.websocket.client")

---@class OpenAI
---@field endpoint string
---@field api_key string|table
---@field name string
local OpenAI = {}
OpenAI.__index = OpenAI

-- Available API parameters for OpenAI
-- https://platform.openai.com/docs/api-reference/chat
local AVAILABLE_API_PARAMETERS = {
  -- required
  messages = true,
  model = true,
  -- optional
  frequency_penalty = true,
  logit_bias = true,
  logprobs = true,
  top_logprobs = true,
  max_tokens = true,
  max_completion_tokens = true,
  presence_penalty = true,
  seed = true,
  stop = true,
  stream = true,
  temperature = true,
  top_p = true,
  tools = true,
  tool_choice = true,
}

-- Creates a new OpenAI instance
---@param endpoint string
---@param api_key string|table
---@return OpenAI
function OpenAI:new(endpoint, api_key)
  return setmetatable({
    endpoint = endpoint,
    api_key = api_key,
    name = "openai",
  }, self)
end

-- Placeholder for setting model (not implemented)
function OpenAI:set_model(_) end

-- Preprocesses the payload before sending to the API
---@param payload table
---@return table
function OpenAI:preprocess_payload(payload)
  for _, message in ipairs(payload.messages) do
    message.content = message.content:gsub("^%s*(.-)%s*$", "%1")
  end
  -- Changes according to beta limitations of the reasoning API
  -- https://platform.openai.com/docs/guides/reasoning
  if payload.model and string.find(payload.model, "o1", 1, true) then
    -- remove system prompt
    if payload.messages[1] and payload.messages[1].role == "system" then
      table.remove(payload.messages, 1)
    end
    payload.stream = nil
    payload.logprobs = nil
    payload.temperature = tonumber(1)
    payload.top_p = tonumber(1)
    payload.top_n = tonumber(1)
    payload.presence_penalty = tonumber(0)
    payload.frequency_penalty = tonumber(0)
  end
  -- Explicitly convert other numeric parameters to ensure they are numbers
  if payload.temperature then
    payload.temperature = tonumber(payload.temperature)
  end
  if payload.max_tokens then
    payload.max_tokens = tonumber(payload.max_tokens)
  end
  if payload.max_completion_tokens then
    payload.max_completion_tokens = tonumber(payload.max_completion_tokens)
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
function OpenAI:curl_params()
  return {
    self.endpoint,
    "-H",
    "authorization: Bearer " .. self.api_key,
  }
end

-- Verifies the API key or executes a routine to retrieve it
---@return boolean
function OpenAI:verify()
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
function OpenAI:process_stdout(response)
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
function OpenAI:process_onexit(res)
  local success, parsed = pcall(vim.json.decode, res)
  if success and parsed.error and parsed.error.message then
    logger.error(
      string.format(
        "OpenAI - code: %s message: %s type: %s",
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
---@param online boolean Whether to fetch models online
---@return string[]
function OpenAI:get_available_models(online)
  local ids = {
    "gpt-4o",
    "gpt-4-turbo",
    "gpt-4-turbo-2024-04-09",
    "chatgpt-4o-latest",
    "gpt-4-turbo-preview",
    "gpt-3.5-turbo-instruct",
    "gpt-4-0125-preview",
    "gpt-3.5-turbo-0125",
    "gpt-3.5-turbo",
    "o1-preview-2024-09-12",
    "o1-preview",
    "gpt-4o-mini",
    "gpt-4o-2024-05-13",
    "gpt-4o-mini-2024-07-18",
    "gpt-4-1106-preview",
    "gpt-3.5-turbo-16k",
    "gpt-4o-2024-08-06",
    "gpt-3.5-turbo-1106",
    "gpt-4-0613",
    "o1-mini",
    "gpt-4",
    "o1-mini-2024-09-12",
    "gpt-3.5-turbo-instruct-0914",
    "gpt-4o-realtime-preview",
    "gpt-4o-realtime-preview-2024-10-01",
    "gpt-4o-audio-preview",
    "gpt-4o-audio-preview-2024-10-01"
  }
  if online and self:verify() then
    local job = Job:new({
      command = "curl",
      args = {
        "https://api.openai.com/v1/models",
        "-H",
        "Authorization: Bearer " .. self.api_key,
      },
      on_exit = function(job)
        local parsed_response = utils.parse_raw_response(job:result())
        self:process_onexit(parsed_response)
        ids = {}
        local success, decoded = pcall(vim.json.decode, parsed_response)
        if success and decoded.data then
          for _, item in ipairs(decoded.data) do
            table.insert(ids, item.id)
          end
        end
        return ids
      end,
    })
    job:start()
    job:wait()
  end
  return ids
end

function OpenAI:send_realtime_request(payload, callback)
  if not self:verify() then
    logger.error("API key verification failed")
    return
  end

  local ws_url = "wss://api.openai.com/v1/realtime"

  local client = websocket()

  client:on_open(function()
    local message = vim.json.encode(payload)
    client:send(message)
  end)

  client:on_message(function(_, message)
    local success, parsed_message = pcall(vim.json.decode, message)
    if success then
      if parsed_message.choices and parsed_message.choices[1] then
        callback(parsed_message.choices[1].delta and parsed_message.choices[1].delta.content or parsed_message.choices[1].message.content)
      end
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

return OpenAI

