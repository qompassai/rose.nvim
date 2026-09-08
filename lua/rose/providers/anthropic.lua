local C = require("rose.providers.common")
local M = {}

function M.encode(config, messages, tools)
  C.messages(messages, config)
  local wire, system, seen_conversation = {}, {}, false
  local function append(role, blocks)
    if wire[#wire] and wire[#wire].role == role then
      vim.list_extend(wire[#wire].content, blocks)
    else
      wire[#wire + 1] = { role = role, content = blocks }
    end
  end
  for _, message in ipairs(messages) do
    if message.role == "system" or message.role == "developer" then
      assert(not seen_conversation, "Anthropic system messages must precede conversation messages")
      system[#system + 1] = { type = "text", text = message.content or "" }
    elseif message._provider then
      seen_conversation = true
      -- Includes thinking.signature and redacted_thinking.data, unmodified and
      -- in order. Never turn these into normal text or rebuild only tool_use.
      append("assistant", C.copy(message._provider.response.content))
    elseif message.role == "tool" then
      seen_conversation = true
      local block = {
        type = "tool_result",
        tool_use_id = message.tool_call_id,
        content = message.content or "",
      }
      if message.is_error ~= nil then
        block.is_error = message.is_error
      end
      append("user", { block })
    else
      seen_conversation = true
      assert(
        not message.name and not message.tool_name and message.is_error == nil,
        "Anthropic normalized messages do not support name/is_error; use raw JSON request API"
      )
      local blocks = {}
      if message.content and message.content ~= "" then
        blocks[#blocks + 1] = { type = "text", text = message.content }
      end
      for _, call in ipairs(message.tool_calls or {}) do
        local args = call["function"].arguments
        if type(args) == "string" then
          local ok, decoded = pcall(vim.json.decode, args)
          assert(ok and type(decoded) == "table", "Anthropic tool arguments must be a JSON object")
          args = decoded
        end
        blocks[#blocks + 1] =
          { type = "tool_use", id = call.id, name = call["function"].name, input = C.copy(args) }
      end
      append(message.role, blocks)
    end
  end
  local payload = C.options(config, { model = config.model, messages = wire, stream = false })
  if #system > 0 then
    assert(payload.system == nil, "options.system conflicts with normalized system messages")
    payload.system = system
  end
  assert(
    type(payload.max_tokens) == "number" and payload.max_tokens > 0 and payload.max_tokens % 1 == 0,
    "Anthropic options.max_tokens must be an explicit positive integer"
  )
  if tools and #tools > 0 then
    payload.tools = C.tools(tools, "messages")
  end
  return payload
end

function M.decode(config, response)
  assert(
    type(response.content) == "table" and vim.islist(response.content),
    "Anthropic response has no content blocks"
  )
  local text, calls, citations = {}, {}, {}
  for _, block in ipairs(response.content) do
    if block.type == "text" then
      assert(type(block.text) == "string", "invalid Anthropic text block")
      text[#text + 1] = block.text
      vim.list_extend(citations, C.citations(block.citations))
    elseif block.type == "tool_use" then
      calls[#calls + 1] = {
        id = block.id,
        type = "function",
        ["function"] = { name = block.name, arguments = block.input },
      }
    elseif
      block.type == "thinking"
      or block.type == "redacted_thinking"
      or block.type == "server_tool_use"
      or (type(block.type) == "string" and block.type:match("_tool_result$"))
    then
      -- Provider-owned blocks are retained in _provider.response.content.
    else
      error("unsupported Anthropic content block; use the raw JSON request API", 0)
    end
  end
  return C.result(
    config,
    response,
    table.concat(text, "\n"),
    calls,
    response.stop_reason,
    citations
  )
end

return M
