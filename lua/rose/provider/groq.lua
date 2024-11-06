local logger = require("rose.logger")
local utils = require("rose.utils")
local Job = require("plenary.job")

---@class Groq
---@field endpoint string
---@field api_key string|table
---@field name string
local Groq = {}
Groq.__index = Groq

-- Available API parameters for Groq
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
---@param api_key string|table
---@return Groq
function Groq:new(endpoint, api_key)
    return setmetatable({
        endpoint = endpoint,
        api_key = api_key,
        name = "groq",
    }, self)
end

-- Placeholder for setting model (not implemented)
--function Groq:set_model(model) end

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
    local api_key = self.api_key  -- Use a local variable to avoid reassignment issues

    if type(api_key) == "table" then
        -- If api_key is a table, treat it as a command to run to get the key
        local command = table.concat(api_key, " ")
        local handle = io.popen(command)
        if handle then
            local api_key_result = handle:read("*a"):gsub("%s+", "")
            handle:close()
            -- If retrieved value is valid, assign back to self.api_key
            if api_key_result and #api_key_result > 0 then
                self.api_key = api_key_result  -- This is now explicitly a string
                return true
            else
                logger.error("Error: Retrieved empty API key for " .. self.name)
                return false
            end
        else
            logger.error("Error verifying API key of " .. self.name)
            return false
        end
    elseif type(api_key) == "string" and api_key:match("%S") then
        -- If api_key is a non-empty string, it's considered valid
        return true
    else
        logger.error("Error with API key " .. self.name .. " " .. vim.inspect(api_key))
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
            and content.choices
            and content.choices[1]
            and content.choices[1].delta
            and content.choices[1].delta.content
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
    if success and parsed.error then
        logger.error("Groq - message: " .. parsed.error.message)
    end
end

-- Returns the list of available models asynchronously
---@param online boolean
---@param callback function
function Groq:get_available_models(online, callback)
    local ids = {
        -- Google Models
        "[Google] gemma-7b-it",
        "[Google] gemma2-9b-it",

        -- Groq Models
        "[Groq] llama3-groq-70b-8192-tool-use-preview",
        "[Groq] llama3-groq-8b-8192-tool-use-preview",

        -- HuggingFace Models
        "[HuggingFace] distil-whisper-large-v3-en",

        -- Meta Models
        "[Meta] llama-3.1-70b-versatile",
        "[Meta] llama-3.1-8b-instant",
        "[Meta] llama-3.2-1b-preview",
        "[Meta] llama-3.2-3b-preview",
        "[Meta] llama-3.2-11b-vision-preview",
        "[Meta] llama-3.2-90b-vision-preview",
        "[Meta] llama-guard-3-8b",
        "[Meta] llama3-70b-8192",
        "[Meta] llama3-8b-8192",

        -- Mistral Models
        "[Mistral] mixtral-8x7b-32768",

        -- OpenAI Models
        "[OpenAI] whisper-large-v3",
        "[OpenAI] whisper-large-v3-turbo"
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
            on_exit = function(j, return_val)
                if return_val == 0 then
                    local result = table.concat(j:result(), "\n")
                    local success, parsed_response = pcall(vim.json.decode, result)
                    if success and parsed_response and parsed_response.data then
                        ids = {}
                        for _, item in ipairs(parsed_response.data) do
                            local model_id = item.id
                            local label = "[Unknown]"
                            if model_id:match("gemma") then
                                label = "[Google]"
                            elseif model_id:match("groq") then
                                label = "[Groq]"
                            elseif model_id:match("llama") or model_id:match("mixtral") then
                                label = "[Meta]"
                            elseif model_id:match("distil") or model_id:match("whisper") then
                                label = "[HuggingFace]"
                            elseif model_id:match("whisper%-large%-v3") then
                                label = "[OpenAI]"
                            end
                            table.insert(ids, label .. " " .. model_id)
                        end
                        if callback then
                            callback(ids)
                        end
                    else
                        logger.error("Failed to fetch models from Groq API.")
                    end
                else
                    logger.error("Job exited with error code: " .. return_val)
                end
            end,
        })
        job:start()
    else
        if callback then
            callback(ids)
        end
    end
end

return Groq
