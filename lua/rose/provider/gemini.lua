local Job = require("plenary.job")
local logger = require("rose.logger")
local utils = require("rose.utils")

---@class Gemini
---@field endpoint string
---@field api_key string|string[]|nil
---@field name string
---@field _model string|nil
local Gemini = {}
Gemini.__index = Gemini

-- Available API parameters for Gemini
-- https://ai.google.dev/gemini-api/docs/models/generative-models#model_parameters
local AVAILABLE_API_PARAMETERS = {
  contents = true,
  system_instruction = true,
  generationConfig = {
    stopSequences = true,
    temperature = true,
    maxOutputTokens = true,
    topP = true,
    topK = true,
  },
}

-- Creates a new Gemini instance
---@param endpoint string
---@param api_key string|string[]|nil
---@return Gemini
function Gemini:new(endpoint, api_key)
  return setmetatable({
    endpoint = endpoint,
    api_key = api_key,
    name = "gemini",
    _model = nil,
  }, self)
end

-- Sets the model for the actual API request
---@param model string
function Gemini:set_model(model)
  self._model = model
end

-- Preprocesses the payload before sending to the API
---@param payload table
---@return table
function Gemini:preprocess_payload(payload)
  local new_messages = {}
  for _, message in ipairs(payload.messages) do
    if message.role == "system" then
      payload.system_instruction = {
        parts = {
          text = (message.parts and message.parts.text or message.content):gsub(
            "^%s*(.-)%s*$",
            "%1"
          ),
        },
      }
    else
      local _role = message.role == "assistant" and "model" or message.role
      if message.content then
        table.insert(new_messages, {
          parts = { { text = message.content:gsub("^%s*(.-)%s*$", "%1") } },
          role = _role,
        })
      end
    end
  end
  payload.contents = vim.deepcopy(new_messages)
  return utils.filter_payload_parameters(AVAILABLE_API_PARAMETERS, payload)
end

-- Returns the curl parameters for the API request
---@return table
function Gemini:curl_params()
  return {
    self.endpoint .. self._model .. ":streamGenerateContent?alt=sse",
    "-H",
    "x-goog-api-key: " .. self.api_key,
    "-X",
    "POST",
  }
end

-- Verifies the API key or executes a routine to retrieve it
---@return boolean
function Gemini:verify()
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

---Processes the stdout from the API response
---@param response string
---@return string|nil
function Gemini:process_stdout(response)
  if response:match('"text":') then
    local success, content = pcall(vim.json.decode, response)
    if
      success
      and type(content) == "table"
      and type(content.candidates) == "table"
      and type(content.candidates[1]) == "table"
      and type(content.candidates[1].content) == "table"
      and type(content.candidates[1].content.parts) == "table"
      and type(content.candidates[1].content.parts[1]) == "table"
      and type(content.candidates[1].content.parts[1].text) == "string"
    then
      return content.candidates[1].content.parts[1].text
    else
      logger.debug("Could not process response: " .. response)
    end
  end
end

---Processes the onexit event from the API response
---@param res string
function Gemini:process_onexit(res)
  local success, parsed = pcall(vim.json.decode, res)
  if
    success
    and type(parsed) == "table"
    and type(parsed.error) == "table"
    and type(parsed.error.message) == "string"
  then
    logger.error(
      string.format(
        "GEMINI - code: %s message: %s status: %s",
        parsed.error.code,
        parsed.error.message,
        parsed.error.status
      )
    )
  end
end

---Returns the list of available models
---@return string[]
function Gemini:get_available_models(online)
  local ids = {
    "gemini-1.5-flash",
    "gemini-1.5-pro",
    "gemini-1.0-pro",
  }
  if online and self:verify() then
    local job = Job:new({
      command = "curl",
      args = { "https://generativelanguage.googleapis.com/v1beta/models?key=" .. self.api_key },
      on_exit = function(job)
        local parsed_response = utils.parse_raw_response(job:result())
        ids = {}
        if not parsed_response then
          logger.error("Gemini - No model response received")
          return
        end
        self:process_onexit(parsed_response)
        local success, decoded = pcall(vim.json.decode, parsed_response)
        if success and type(decoded) == "table" and type(decoded.models) == "table" then
          for _, item in ipairs(decoded.models) do
            if type(item) == "table" and type(item.name) == "string" then
              table.insert(ids, string.sub(item.name, 8))
            end
          end
        end
      end,
    })
    job:start()
    job:wait()
  end
  return ids
end

return Gemini
