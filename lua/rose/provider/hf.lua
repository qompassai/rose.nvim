local logger = require("rose.logger")
local utils = require("rose.utils")

---@class HuggingFace
---@field endpoint string
---@field api_key string|table
---@field name string
local HuggingFace = {}
HuggingFace.__index = HuggingFace

-- Available API parameters for Hugging Face
-- Reference: https://huggingface.co/docs/api-inference/index
local AVAILABLE_API_PARAMETERS = {
  inputs = true,        -- The input text or list of inputs for the model
  parameters = true,    -- Optional parameters for controlling output
  options = true,       -- Options like wait_for_model (to wait for a model to be loaded if it's not ready)
}

-- Creates a new Hugging Face instance
---@param endpoint string
---@param api_key string|table
---@return HuggingFace
function HuggingFace:new(endpoint, api_key)
  return setmetatable({
    endpoint = endpoint,
    api_key = api_key,
    name = "huggingface",
  }, self)
end

--- Placeholder for setting model (not implemented)
function HuggingFace:set_model(_) end

-- Preprocesses the payload before sending to the API
---@param payload table
---@return table
function HuggingFace:preprocess_payload(payload)
  -- Make sure `inputs` field is provided and is trimmed
  if payload.inputs then
    if type(payload.inputs) == "string" then
      payload.inputs = payload.inputs:gsub("^%s*(.-)%s*$", "%1")
    elseif type(payload.inputs) == "table" then
      for i, input in ipairs(payload.inputs) do
        payload.inputs[i] = input:gsub("^%s*(.-)%s*$", "%1")
      end
    end
  end

  return utils.filter_payload_parameters(AVAILABLE_API_PARAMETERS, payload)
end

-- Returns the curl parameters for the API request
---@return table
function HuggingFace:curl_params()
  return {
    self.endpoint,
    "-H",
    "Authorization: Bearer " .. self.api_key,
    "-H",
    "Content-Type: application/json",
  }
end

-- Verifies the API key or executes a routine to retrieve it
---@return boolean
function HuggingFace:verify()
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
function HuggingFace:process_stdout(response)
  local success, content = pcall(vim.json.decode, response)
  if success and content then
    if content.generated_text then
      return content.generated_text
    elseif content.outputs then
      return content.outputs
    else
      return vim.inspect(content)  -- Return a representation of the response for debugging purposes
    end
  else
    logger.debug("Could not process response: " .. response)
  end
end

-- Processes the onexit event from the API response
---@param res string
function HuggingFace:process_onexit(res)
  local success, parsed = pcall(vim.json.decode, res)
  if success and parsed.error then
    logger.error("HuggingFace - message: " .. parsed.error)
  end
end

-- Returns the list of available models
---@return string[]
function HuggingFace:get_available_models()
  return {
    "gpt2",             -- Example model: GPT-2
    "distilbert-base-uncased-finetuned-sst-2-english",  -- Example sentiment analysis model
    "facebook/bart-large-cnn", -- Example summarization model
    "google/vit-base-patch16-224", -- Example vision model
    "bert-base-uncased", -- Example BERT model
  }
end

return HuggingFace

