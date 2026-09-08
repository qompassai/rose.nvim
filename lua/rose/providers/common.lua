local M = {}
-- Roles the normalized chat shape accepts; anything else is a caller bug, not provider data.
local normalized_roles =
  { system = true, developer = true, user = true, assistant = true, tool = true }

function M.copy(value)
  return vim.deepcopy(value)
end
function M.present(value)
  return value ~= nil and value ~= vim.NIL
end

function M.fields(value, allowed, kind)
  assert(type(value) == "table", kind .. " must be a table")
  for key in pairs(value) do
    assert(
      allowed[key],
      "unsupported " .. kind .. " field; use the raw JSON request API for native fields"
    )
  end
end

function M.options(config, payload)
  local reserved = { model = true, messages = true, input = true, tools = true, stream = true }
  for key, value in pairs(config.options or {}) do
    assert(
      type(key) == "string" and not reserved[key],
      "provider options cannot override model/messages/input/tools/stream; use the raw JSON "
        .. "request API"
    )
    payload[key] = M.copy(value)
  end
  assert(
    payload.n == nil or payload.n == 1,
    "normalized chat supports n=1 only; use the raw JSON request API"
  )
  return payload
end

function M.messages(messages, config)
  assert(type(messages) == "table" and vim.islist(messages), "messages must be an array")
  local pending = {}
  for _, message in ipairs(messages) do
    M.fields(message, {
      role = true,
      content = true,
      tool_calls = true,
      tool_call_id = true,
      tool_name = true,
      name = true,
      _provider = true,
      usage = true,
      citations = true,
      finish_reason = true,
      is_error = true,
    }, "normalized message")
    assert(normalized_roles[message.role], "unsupported normalized message role")
    assert(
      not M.present(message.content) or type(message.content) == "string",
      "normalized chat accepts text content only; use the raw JSON request API for media/blocks"
    )
    if message._provider then
      assert(
        message.role == "assistant"
          and message._provider.name == config.name
          and message._provider.api == config.api
          and message._provider.model == config.model
          and message._provider.endpoint == config.endpoint,
        "provider history belongs to a different endpoint, API or model; start a new conversation"
      )
    end
    if message.role == "tool" then
      assert(
        type(message.tool_call_id) == "string" and message.tool_call_id ~= "",
        "tool results require the original tool_call_id"
      )
      assert(
        pending[message.tool_call_id],
        "tool result id does not match a pending assistant call"
      )
      pending[message.tool_call_id] = nil
    else
      assert(
        next(pending) == nil,
        "all assistant tool calls need results before another conversation message"
      )
    end
    if M.present(message.tool_calls) then
      assert(message.role == "assistant", "tool_calls are permitted only on assistant messages")
      for _, call in ipairs(M.calls(message.tool_calls)) do
        pending[call.id] = true
      end
    end
  end
  assert(
    next(pending) == nil,
    "all assistant tool calls require matching results before the next model request"
  )
end

function M.calls(calls, native)
  assert(type(calls) == "table" and vim.islist(calls), "invalid provider tool_calls")
  local ids, result = {}, {}
  for _, call in ipairs(calls) do
    assert(
      type(call) == "table" and type(call.id) == "string" and call.id ~= "" and not ids[call.id],
      "missing or duplicate provider tool-call id"
    )
    if not native then
      M.fields(call, { id = true, type = true, ["function"] = true }, "normalized tool call")
    end
    assert(
      call.type == nil or call.type == "function",
      "unsupported tool call; use the raw JSON request API"
    )
    local fn = call["function"]
    assert(
      type(fn) == "table" and type(fn.name) == "string" and fn.name ~= "",
      "invalid provider tool function"
    )
    if not native then
      M.fields(fn, { name = true, arguments = true }, "normalized tool function")
    end
    assert(
      type(fn.arguments) == "string" or type(fn.arguments) == "table",
      "invalid provider tool arguments"
    )
    ids[call.id] = true
    result[#result + 1] = {
      id = call.id,
      type = "function",
      ["function"] = { name = fn.name, arguments = M.copy(fn.arguments) },
    }
  end
  return result
end

function M.tools(tools, format, config)
  local result = {}
  for _, tool in ipairs(tools or {}) do
    M.fields(tool, { type = true, ["function"] = true }, "tool schema")
    assert(tool.type == "function", "only custom function schemas are supported by normalized chat")
    local fn = tool["function"]
    assert(type(fn) == "table" and type(fn.name) == "string", "invalid function tool schema")
    if format == "chat" then
      result[#result + 1] = M.copy(tool)
    else
      local item = M.copy(fn)
      if format == "messages" then
        item.input_schema, item.parameters = item.parameters, nil
      else
        item.type = "function"
        -- Rose's optional tool fields are intentional; do not silently make
        -- every parameter required via the Responses API's strict default.
        if config and config.name == "openai" and item.strict == nil then
          item.strict = false
        end
      end
      result[#result + 1] = item
    end
  end
  return result
end

-- Do not render separate reasoning fields, thinking blocks, or common tagged
-- reasoning embedded in compatible servers' content. Unclosed tags fail closed.
function M.public_text(text)
  assert(
    not M.present(text) or type(text) == "string",
    "unsupported assistant content; use raw JSON request API"
  )
  text = M.present(text) and text or ""
  for _, tag in ipairs({ "think", "thinking" }) do
    text = text:gsub("<" .. tag .. ">.-</" .. tag .. ">", "")
    local open = text:find("<" .. tag .. ">", 1, true)
    if open then
      text = text:sub(1, open - 1)
    end
  end
  return text
end

function M.usage(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local input = raw.input_tokens or raw.prompt_tokens
  local output = raw.output_tokens or raw.completion_tokens
  return {
    input_tokens = input,
    output_tokens = output,
    total_tokens = raw.total_tokens
      or (type(input) == "number" and type(output) == "number" and input + output or nil),
    raw = M.copy(raw),
  }
end

function M.citations(values)
  local result = {}
  for _, item in ipairs(type(values) == "table" and values or {}) do
    result[#result + 1] = type(item) == "string" and { url = item } or M.copy(item)
  end
  return result
end

function M.result(config, response, text, calls, reason, citations)
  calls = M.calls(calls or {}, true)
  local reasons = {
    end_turn = "stop",
    stop_sequence = "stop",
    completed = "stop",
    max_tokens = "length",
    max_output_tokens = "length",
    tool_use = "tool_calls",
    refusal = "content_filter",
  }
  if #calls > 0 then
    reason = "tool_calls"
  end
  return {
    role = "assistant",
    content = M.public_text(text),
    tool_calls = #calls > 0 and calls or nil,
    usage = M.usage(response.usage),
    citations = M.citations(citations),
    finish_reason = reasons[reason] or reason,
    _provider = {
      name = config.name,
      api = config.api,
      model = config.model,
      endpoint = config.endpoint,
      response = M.copy(response),
    },
  }
end

return M
