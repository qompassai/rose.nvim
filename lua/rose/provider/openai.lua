local Job = require("plenary.job")
local logger = require("rose.logger")
local utils = require("rose.utils")

---@class OpenAI
---@field endpoint string
---@field api_key string|string[]|nil
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
---@param api_key string|string[]|nil
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
    payload.logprobs = nil
    payload.temperature = 1
    payload.top_p = 1
    payload.top_n = 1
    payload.presence_penalty = 0
    payload.frequency_penalty = 0
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
function OpenAI:process_stdout(response)
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
---@param res string
function OpenAI:process_onexit(res)
  local success, parsed = pcall(vim.json.decode, res)
  if not success or type(parsed) ~= "table" then
    return
  end
  if type(parsed.error) == "table" and type(parsed.error.message) == "string" then
    logger.error(
      string.format(
        "OpenAI - code: %s message: %s type: %s",
        parsed.error.code,
        parsed.error.message,
        parsed.error.type
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
        ids = {}
        if not parsed_response then
          logger.error("OpenAI - No model response received")
          return
        end
        self:process_onexit(parsed_response)
        local success, decoded = pcall(vim.json.decode, parsed_response)
        if success and type(decoded) == "table" and type(decoded.data) == "table" then
          for _, item in ipairs(decoded.data) do
            if type(item) == "table" and type(item.id) == "string" then
              table.insert(ids, item.id)
            end
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

return OpenAI
