local logger = require("rose.logger")
local utils = require("rose.utils")
local Job = require("plenary.job")

---@class HuggingFace
---@field endpoint string
---@field api_key string|table
---@field name string
local HuggingFace = {}
HuggingFace.__index = HuggingFace

-- Available API parameters for Hugging Face
-- Reference: https://huggingface.co/docs/api-inference/index
local AVAILABLE_API_PARAMETERS = {
  inputs = true, -- The input text or list of inputs for the model
  parameters = true, -- Optional parameters for controlling output
  options = true, -- Options like wait_for_model (to wait for a model to be loaded if it's not ready)
}

-- Creates a new Hugging Face instance
---@param endpoint string
---@param api_key string|table
---@return HuggingFace
function HuggingFace:new(endpoint, api_key)
  local instance = setmetatable({
    endpoint = endpoint,
    api_key = api_key,
    name = "huggingface",
  }, self)

  -- Verify the API key before use
  if not instance:verify() then
    vim.api.nvim_err_writeln("Failed to verify API key. Please provide a valid key.")
    return nil
  end

  return instance
end

---@param model_type string
function HuggingFace:set_model(model_type)
  local available_models = self:get_available_models()
  if model_type == "text" then
    self.endpoint = available_models[1] -- Assign a text-based model
  elseif model_type == "image" then
    self.endpoint = "openai/clip-vit-base-patch32" -- Example of setting a specific image model
  elseif model_type == "voice" then
    self.endpoint = "facebook/wav2vec2-large-960h" -- Example of setting a specific voice model
  elseif model_type == "video" then
    self.endpoint = "google/movinet-a1" -- Example for video
  elseif model_type == "multimodal" then
    self.endpoint = "deepmind/flamingo-9b" -- Example for multimodal
  else
    logger.error("Invalid model type specified: " .. model_type)
    return
  end

  -- After setting the model, send an example request with sample payload.
  local sample_payload = {
    inputs = "This is a sample input to test the model.", -- Example payload
  }
  self:send_request(sample_payload)
end

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

-- Helper function to get an API key if it isn't set via environment variables
local function get_api_key(env_var, prompt_message)
  local key = os.getenv(env_var)
  if not key then
    vim.cmd(string.format([[let input = input("%s: ")]], prompt_message))
    key = vim.fn.eval("input")
    if key and key ~= "" then
      vim.cmd(string.format([[let $%s = "%s"]], env_var, key))
    else
      vim.api.nvim_err_writeln("API key not provided.")
      return nil
    end
  end
  return key
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
      return vim.inspect(content) -- Return a representation of the response for debugging purposes
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
    "gpt2", -- Example model: GPT-2
    "distilbert-base-uncased-finetuned-sst-2-english", -- Example sentiment analysis model
    "facebook/bart-large-cnn", -- Example summarization model
    "google/vit-base-patch16-224", -- Example vision model
    "bert-base-uncased", -- Example BERT model
    -- NVIDIA HF
    "nvidia/Gemma-2b-it-ONNX-INT4",
    "nvidia/Meta-Llama-3.1-8B-Instruct-ONNX-INT4",
    "nvidia/Meta-Llama-3.2-3B-Instruct-ONNX-INT4",
    "nvidia/Mistral-7B-Instruct-v0.3-ONNX-INT4",
    "nvidia/Phi-3.5-mini-Instruct-ONNX-INT4",
    "nvidia/Mistral-Nemo-12B-Instruct-ONNX-INT4",
    "nvidia/Nemotron-Mini-4B-Instruct-ONNX-INT4",
    -- Embedding
    "jina-ai/jina-embeddings-v2-small-en", -- 33 million parameters
    "jina-ai/jina-embeddings-v2-base-en", -- 137 million parameters
    "jina-ai/jina-embeddings-v2-base-zh", -- Chinese-English Bilingual embeddings
    "jina-ai/jina-embeddings-v2-base-de", -- German-English Bilingual embeddings
    "jina-ai/jina-embeddings-v2-base-es", -- Spanish-English Bilingual embeddings
    -- Image Embeddings Models
    "openai/clip-vit-base-patch32", -- CLIP model for image/text
    "facebook/dino-v2-small", -- DINOv2 for image embeddings

    -- Voice Embeddings Models
    "facebook/wav2vec2-large-960h", -- Wav2Vec 2.0 for voice embeddings
    "openai/whisper-small", -- Whisper for voice-to-text embeddings

    -- Video Embeddings Models
    "google/movinet-a1", -- MoViNet for video action recognition
    "facebook/mvit-v2-b", -- MViT for video embeddings

    -- Multimodal Embeddings Models
    "deepmind/flamingo-9b", -- Flamingo for multimodal embeddings
    "salesforce/blip-image-captioning", -- BLIP for image and text captioning
  }
end

-- Sends an API request to the endpoint asynchronously
---@param payload table
function HuggingFace:send_request(payload)
  -- Construct the curl parameters from the payload
  local params = self:curl_params()

  -- Update the data payload with the given input
  params[#params + 1] = "-d"
  params[#params + 1] = vim.fn.json_encode(self:preprocess_payload(payload))

  -- Use Plenary Job to send the request
  Job:new({
    command = "curl",
    args = params,
    on_stdout = function(_, response)
      local output = self:process_stdout(response)
      if output then
        -- Process the response (e.g., print or use in Neovim)
        vim.schedule(function()
          vim.api.nvim_out_write("Response received: " .. output .. "\n")
        end)
      end
    end,
    on_stderr = function(_, err)
      -- Log the error using the logger
      logger.error("Error occurred in HuggingFace API call: " .. err)
    end,
    on_exit = function(_, exit_code)
      -- Handle any cleanup or response parsing after the command exits
      if exit_code == 0 then
        vim.schedule(function()
          vim.api.nvim_out_write("Request completed successfully.\n")
        end)
      else
        vim.schedule(function()
          vim.api.nvim_err_writeln("Request failed with exit code: " .. exit_code)
        end)
      end
    end,
  }):start()
end

return HuggingFace
