local logger = require("rose.logger")
local Job = require("plenary.job")
local utils = require("rose.utils")

---@class Rose
---@field endpoint string
---@field api_key string|table
---@field name string
---@field rose_installed boolean
local Rose = {}
Rose.__index = Rose

-- Available API parameters for Rose
local AVAILABLE_API_PARAMETERS = {
  -- required
  model = true,
  messages = true,
  -- optional
  mirostat = true,
  mirostat_tau = true,
  num_ctx = true,
  repeat_last_n = true,
  repeat_penalty = true,
  temperature = true,
  seed = true,
  stop = true,
  tfs_z = true,
  num_predict = true,
  top_k = true,
  top_p = true,
  -- optional (advanced)
  format = true,
  system = true,
  stream = true,
  raw = true,
  keep_alive = true,
}

---@param endpoint string
---@param api_key string|table
---@return Rose
function Rose:new(endpoint, api_key)
  return setmetatable({
    endpoint = endpoint,
    api_key = api_key,
    name = "qompass",
    rose_installed = vim.fn.executable("rose") == 1,
  }, self)
end

-- Placeholder for setting model (not implemented)
function Rose:set_model(_) end

-- Preprocesses the payload before sending to the API
---@param payload table
---@return table
function Rose:preprocess_payload(payload)
  for _, message in ipairs(payload.messages) do
    message.content = message.content:gsub("^%s*(.-)%s*$", "%1")
  end
  return utils.filter_payload_parameters(AVAILABLE_API_PARAMETERS, payload)
end

-- Returns the curl parameters for the API request
---@return table
function Rose:curl_params()
  return { self.endpoint }
end

-- Verifies the API connection (always returns true for Rose)
---@return boolean
function Rose:verify()
  return true
end

-- Processes the stdout from the API response
---@param response string
---@return string|nil
function Rose:process_stdout(response)
  if response:match("message") and response:match("content") then
    local success, content = pcall(vim.json.decode, response)
    if success and content.message and content.message.content then
      return content.message.content
    else
      logger.debug("Could not process response: " .. response)
    end
  end
end

-- Processes the onexit event from the API response
---@param res string
function Rose:process_onexit(res)
  local success, parsed = pcall(vim.json.decode, res)
  if success and parsed.error then
    logger.error("Rose - error: " .. parsed.error)
  end
end

-- Returns the list of available models
---@return string[]
function Rose:get_available_models()
  if not self.rose_installed then
    logger.error("Rose is not installed or not in PATH.")
    return {}
  end

  local job = Job:new({
    command = "curl",
    args = { "-H", "Content-Type: application/json", "http://localhost:11434/api/tags" },
  }):sync()

  local parsed_response = utils.parse_raw_response(job)
  self:process_onexit(parsed_response)

  if parsed_response == "" then
    logger.debug("Rose server not running.")
    return {}
  end

  local success, parsed_data = pcall(vim.json.decode, parsed_response)
  if not success then
    logger.error("Rose - Error parsing JSON: " .. vim.inspect(parsed_data))
    return {}
  end

  if not parsed_data.models then
    logger.error("Rose - No models found. Please use 'rose pull' to download one.")
    return {}
  end

  local names = {}
  for _, model in ipairs(parsed_data.models) do
    table.insert(names, model.name)
  end

  return names
end

return Rose
