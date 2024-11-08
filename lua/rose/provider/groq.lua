-- luacheck: globals vim
local logger = require("rose.logger")
local utils = require("rose.utils")
local Job = require("plenary.job")
---@class Groq
---@field endpoint string
---@field api_key string|table
---@field name string
local Groq = {}
Groq.__index = Groq

-- Available API parameters for Groq last updated 11/7/24
-- https://console.groq.com/docs/api-reference#chat-create
local AVAILABLE_API_PARAMETERS = {
  -- required
  model = "llama3-8b-8192", -- Required parameter: ID of the model to use. Make sure to provide a valid model ID.
  messages = true,
  -- optional
  frequency_penalty = true, --Number between -2.0 and 2.0. Positive values penalize new tokens based on their existing frequency in the text so far, decreasing the model's likelihood to repeat the same line verbatim.
  logit_bias = true, -- This is not yet supported by any of our models. Modify the likelihood of specified tokens appearing in the completion.
  logprobs = true, --This is not yet supported by any LPU powered models. Whether to return log probabilities of the output tokens or not. If true, returns the log probabilities of each output token returned in the content of message.
  max_tokens = 8192, -- The maximum number of tokens that can be generated in the chat completion. The total length of input tokens and generated tokens is limited by the model's context length.
  n = 1, --integer or null | optional | Defaults to 1 | How many chat completion choices to generate for each input message. Note that the current moment, only n=1 is supported. Other values will result in a 400 response.
  parallel_tool_calls = true, --boolean or nullOptional. Defaults to true. Whether to enable parallel function calling during tool use.
  presence_penalty = 1, --Number between -2.0 and 2.0. Positive values penalize new tokens based on whether they appear in the text so far, increasing the model's likelihood to talk about new topics.
  response_format = { type = "json_object" }, ---- Set response_format to JSON mode for guaranteed valid JSON output
  seed = 42, --Integer (42 being default) or nil (optional, allows randomness. If specified, our system will make a best effort to sample deterministically, such that repeated requests with the same seed and parameters should return the same result. Determinism is not guaranteed, and you should refer to the system_fingerprint response parameter to monitor changes in the backend.
  stop = { "", "END", "###", "	" }, -- Set up to 4 stop sequences for stopping token generation
  stream = true, --true/false (boolean). streamboolean or nullOptional. Defaults to false. If set, partial message deltas will be sent. Tokens will be sent as data-only server-sent events as they become available, with the stream terminated by a data: [DONE] message. Example code.
  stream_options = { include_usage = false }, -- Set stream_options to include_usage = false, as it is unused
  temperature = 1, --What sampling temperature to use, between 0 and 2. Higher values like 0.8 will make the output more random, while lower values like 0.2 will make it more focused and deterministic. We generally recommend altering this or top_p but not both
  tool_choice = "auto", -- Set tool_choice to 'auto' to allow the model to decide between generating a message or calling tools. Replaced function_call.
  tools = {
    {
      name = "search_documents",
      description = "This function allows the model to search for documents based on the given search term and category.",
      type = "function",
      parameters = {
        type = "object",
        properties = {
          search_term = { type = "string", description = "The term to search for in the documents" },
          category = {
            type = "string",
            description = "The category of documents to filter, e.g., 'reports', 'invoices', 'articles'",
          },
          max_results = { type = "integer", description = "The maximum number of search results to return" },
        },
        required = { "search_term" },
      },
    },
    {
      name = "web_search",
      description = "This function allows the model to perform a web search using DuckDuckGo based on the given query.",
      type = "function",
      parameters = {
        type = "object",
        properties = {
          query = { type = "string", description = "The search query to look for information on the web" },
          num_results = { type = "integer", description = "The number of search results to retrieve, maximum of 10" },
          safe_search = {
            type = "string",
            description = "Enable or disable safe search filter, values can be 'on', 'moderate', or 'off'",
          },
          region = { type = "string", description = "Region to prioritize search results, e.g., 'us-en', 'uk-en'" },
        },
        required = { "query" },
      },
    },
  },
  top_logprobs = nil,  -- Set to nil as this is not supported by any of the models, or use an integer between 0 and 20 when supported
  top_p = 1,  -- Defaults to 1; can be adjusted between 0 and 1 for nucleus sampling
  user = "diver",  -- Set a unique identifier for the end-user to help monitor and detect abuse
}
-- Creates a new Groq instance
---@param endpoint string
---@param api_key string|table
---@return Groq
function Groq:new(endpoint, api_key)
  return setmetatable({
    endpoint = endpoint,
    api_key = api_key,
    name = "groq",
  }, self)
end

-- Sets the model for use in API requests
---@param model string
function Groq:set_model(model)
  self.model = model
end

-- Preprocesses the payload before sending to the API
---@param payload table
---@return table
function Groq:preprocess_payload(payload)
  for _, message in ipairs(payload.messages) do
    if message.content and type(message.content) == "string" then
        message.content = message.content:gsub("^%s*(.-)%s*$", "%1")
    else
        message.content = nil
    end
    if message.role == "system" then
      message.role = "system"
      message.name = message.name or nil
    elseif message.role == "user" then
      message.role = "user"
      message.name = message.name or nil
    elseif message.role == "assistant" then
      message.role = "assistant"
      message.name = message.name or nil
      message.tool_calls = message.tool_calls or nil
    elseif message.role == "tool" then
      message.role = "tool"
      message.tool_call_id = message.tool_call_id or nil
    end

    -- Remove deprecated fields
    message.function_call = nil
    message.tool_call_id = nil
  end
  payload.model = self.model or payload.model
  return utils.filter_payload_parameters(AVAILABLE_API_PARAMETERS, payload)
end

-- Returns the curl parameters for the API request
---@return table
function Groq:curl_params()
  return {
    self.endpoint,
    "-H",
    "Authorization: Bearer " .. self.api_key,
    "-H",
    "Content-Type: application/json",
  }
end

-- Executes a chat completion request
---@param payload table
---@param on_exit function
function Groq:chat_completion(payload, on_exit)
  local processed_payload = self:preprocess_payload(payload)
  local job = Job:new({
    command = "curl",
    args = vim.list_extend(self:curl_params(), {
      "-d",
      vim.json.encode(processed_payload),
    }),
    on_exit = function(job, return_val)
      if return_val == 0 then
        local response = table.concat(job:result(), "\n")
        local success, content = pcall(vim.json.decode, response)
        if success and content.choices and content.choices[1] then
          local choice = content.choices[1]
          if choice.message and choice.message.tool_calls then
            -- Process the tool call
            self:process_tool_call(choice.message.tool_calls[1], function(tool_result)
              on_exit(tool_result or "Tool execution failed.")
            end)
          else
            on_exit(choice.message.content)
          end
        else
          logger.error("Failed to parse chat completion response")
          on_exit(nil)
        end
      else
        logger.error("Failed to get chat completion response")
        on_exit(nil)
      end
    end,
  })
  job:start()
end

-- Verifies the API key or executes a routine to retrieve it
---@return boolean
function Groq:verify()
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
function Groq:process_stdout(response)
  local success, content = pcall(vim.json.decode, response)
  if success and content.choices and content.choices[1] and content.choices[1].message then
    return content.choices[1].message.content
  else
    logger.debug("Could not process response " .. response)
  end
end

-- Processes the onexit event from the API response
---@param res string
function Groq:process_onexit(res)
  local success, parsed = pcall(vim.json.decode, res)
  if success and parsed.error then
    logger.error("Groq - message: " .. parsed.error.message)
  end
end

-- Returns the list of available models
---@param online boolean
---@return string[]
function Groq:get_available_models(online)
  local ids = {
    "distil-whisper-large-v3-en",
    "gemma2-9b-it",
    "gemma-7b-it",
    "llama3-groq-70b-8192-tool-use-preview",
    "llama3-groq-8b-8192-tool-use-preview",
    "llama-3.1-70b-versatile",
    "llama-3.1-8b-instant",
    "llama-3.2-1b-preview",
    "llama-3.2-3b-preview",
    "llama-3.2-11b-vision-preview",
    "llama-3.2-90b-vision-preview",
    "llama-guard-3-8b",
    "llama3-70b-8192",
    "llama3-8b-8192",
    "mixtral-8x7b-32768",
    "whisper-large-v3",
    "whisper-large-v3-turbo",
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
        self:process_onexit(parsed_response)
        ids = {}
        for _, item in ipairs(vim.json.decode(parsed_response).data) do
          table.insert(ids, item.id)
        end
        return ids
      end,
    })
    job:start()
    job:wait()
  end
  return ids
end

-- Processes tool calls requested by the model
---@param tool_call table
---@param on_tool_call_complete function
function Groq:process_tool_call(tool_call, on_tool_call_complete)
  if tool_call.name == "web_search" then
    local query = tool_call.parameters.query
    local num_results = tool_call.parameters.num_results or 5
    local safe_search = tool_call.parameters.safe_search or "moderate"
    local region = tool_call.parameters.region or "us-en"

    local search_endpoint = "https://api.duckduckgo.com/"
    local args = {
      "-G",
      search_endpoint,
      "-d",
      "q=" .. utils.url_encode(query),
      "-d",
      "format=json",
      "-d",
      "safesearch=" .. safe_search,
      "-d",
      "region=" .. region,
      "-d",
      "max_results=" .. tostring(num_results),
    }

    local job = Job:new({
      command = "curl",
      args = args,
      on_exit = function(job, return_val)
        if return_val == 0 then
          local response = table.concat(job:result(), "\n")
          local success, content = pcall(vim.json.decode, response)
          if success and content then
            -- Assuming DuckDuckGo returns results in "RelatedTopics"
            local results = {}
            for i, result in ipairs(content.RelatedTopics) do
              if i > num_results then
                break
              end
              table.insert(results, result.Text .. ": " .. result.FirstURL)
            end
            on_tool_call_complete(table.concat(results, "\n"))
          else
            logger.debug("Failed to parse web search response: " .. response)
            on_tool_call_complete(nil)
          end
        else
          logger.error("Failed to perform web search")
          on_tool_call_complete(nil)
        end
      end,
    })
    job:start()
  else
    logger.error("Unknown tool call requested: " .. tool_call.name)
    on_tool_call_complete(nil)
  end
end

---@param file_path string The path to the audio file to transcribe
---@param language string Optional, ISO-639-1 language code for the input audio
---@param model string The model to use for transcription
---@param prompt string Optional, text to guide the model's style or continue a previous audio segment
---@param response_format string Optional, format of the transcript output (json, text, verbose_json)
---@param temperature number Optional, sampling temperature between 0 and 1
---@param timestamp_granularities table Optional, timestamp granularities for verbose_json (word, segment)
---@param on_exit function Callback function when transcription is complete
function Groq:audio_transcription(file_path, language, model, prompt, response_format, temperature, timestamp_granularities, on_exit)
  local args = vim.list_extend(self:curl_params(), {
    "-X", "POST",
    "-F", string.format("file=@%s", file_path),
    "-F", string.format("model=%s", model or "whisper-large-v3"),
  })

  if language then
    table.insert(args, "-F")
    table.insert(args, string.format("language=%s", language))
  end

  if prompt then
    table.insert(args, "-F")
    table.insert(args, string.format("prompt=%s", prompt))
  end

  if response_format then
    table.insert(args, "-F")
    table.insert(args, string.format("response_format=%s", response_format))
  else
    table.insert(args, "-F")
    table.insert(args, "response_format=json")
  end

  if temperature then
    table.insert(args, "-F")
    table.insert(args, string.format("temperature=%s", temperature))
  end

  if timestamp_granularities then
    table.insert(args, "-F")
    table.insert(args, string.format("timestamp_granularities=%s", vim.inspect(timestamp_granularities)))
  end

  local job = Job:new({
    command = "curl",
    args = args,
    on_exit = function(job, return_val)
      if return_val == 0 then
        local response = table.concat(job:result(), "\n")
        local success, content = pcall(vim.json.decode, response)
        if success and content then
          on_exit(content)
        else
          logger.error("Failed to parse transcription response")
          on_exit(nil)
        end
      else
        logger.error("Failed to get transcription response")
        on_exit(nil)
      end
    end,
  })
  job:start()
end


return Groq
