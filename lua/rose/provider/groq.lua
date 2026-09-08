-- luacheck: globals vim
local Job = require("plenary.job")
local logger = require("rose.logger")
local utils = require("rose.utils")
---@class Groq
---@field endpoint string
---@field api_key string|string[]|nil
---@field name string
local Groq = {}
Groq.__index = Groq

-- Available API parameters for Groq last updated 11/7/24
-- https://console.groq.com/docs/api-reference#chat-create
local AVAILABLE_API_PARAMETERS = {
  -- required
  model = true,
  messages = true,
  -- optional
  frequency_penalty = true,
  logit_bias = true,
  logprobs = true,
  max_tokens = true,
  n = true,
  parallel_tool_calls = true,
  presence_penalty = true,
  response_format = true,
  seed = true,
  stop = true,
  stream = true,
  stream_options = true,
  temperature = true,
  tool_choice = true,
  tools = true,
  top_logprobs = true,
  top_p = true,
  user = true,
}

-- Creates a new Groq instance
---@param endpoint string
---@param api_key string|string[]|nil
---@return Groq
function Groq:new(endpoint, api_key)
  return setmetatable({
    endpoint = endpoint,
    api_key = api_key,
    name = "groq",
  }, self)
end

-- Placeholder for setting model (not implemented)
function Groq:set_model(_) end

-- Preprocesses the payload before sending to the API
---@param payload table
---@return table
function Groq:preprocess_payload(payload)
  for _, message in ipairs(payload.messages) do
    message.content = message.content:gsub("^%s*(.-)%s*$", "%1")
  end
  return utils.filter_payload_parameters(AVAILABLE_API_PARAMETERS, payload)
end

-- Returns the curl parameters for the API request
---@return table
function Groq:curl_params()
  return {
    self.endpoint,
    "-H",
    "Authorization: Bearer " .. self.api_key,
  }
end

-- Verifies the API key or executes a routine to retrieve it
---@return boolean
function Groq:verify()
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
function Groq:process_stdout(response)
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
      logger.debug("Could not process response " .. response)
    end
  end
end

-- Processes the onexit event from the API response
---@param res string
function Groq:process_onexit(res)
  local success, parsed = pcall(vim.json.decode, res)
  if
    success
    and type(parsed) == "table"
    and type(parsed.error) == "table"
    and type(parsed.error.message) == "string"
  then
    logger.error("Groq - message: " .. parsed.error.message)
  end
end

-- Returns the list of available models
---@param online boolean
---@return string[]
function Groq:get_available_models(online)
  local ids = {
    "gemma-7b-it",
    "gemma2-9b-it",
    "llama-3.1-70b-versatile",
    "llama-3.1-8b-instant",
    "llama-3.2-11b-text-preview",
    "llama-3.2-1b-preview",
    "llama-3.2-3b-preview",
    "llama-3.2-90b-text-preview",
    "llama-guard-3-8b",
    "llama3-70b-8192",
    "llama3-8b-8192",
    "llama3-groq-70b-8192-tool-use-preview",
    "llama3-groq-8b-8192-tool-use-preview",
    "llava-v1.5-7b-4096-preview",
    "mixtral-8x7b-32768",
    "whisper-large-v3",
  }
  if online and self:verify() then
    local job = Job:new({
      command = "curl",
      args = {
        "https://api.groq.com/openai/v1/models",
        "-H",
        "Authorization: Bearer " .. self.api_key,
        "-H",
        "Content-Type: application/json",
      },
      on_exit = function(job)
        local parsed_response = utils.parse_raw_response(job:result())
        ids = {}
        if not parsed_response then
          logger.error("Groq - No model response received")
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

return Groq
