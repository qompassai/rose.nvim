-- Responses-style APIs: OpenAI, xAI, and Perplexity Agent.
local C = require("rose.providers.common")
local M = {}

function M.encode(config, messages, tools)
  C.messages(messages, config)
  local input = {}
  for _, message in ipairs(messages) do
    if message._provider then
      -- ALL output items, in original order: function calls, reasoning (including
      -- encrypted_content), message phase, annotations, and provider extensions.
      vim.list_extend(input, C.copy(message._provider.response.output))
    elseif message.role == "tool" then
      input[#input + 1] = {
        type = "function_call_output",
        call_id = message.tool_call_id,
        output = message.content or "",
      }
    else
      assert(
        not message.name and not message.tool_name and message.is_error == nil,
        "Responses normalized messages do not support name/is_error; use raw JSON request API"
      )
      if message.content and message.content ~= "" then
        input[#input + 1] = { role = message.role, content = message.content }
      end
      for _, call in ipairs(message.tool_calls or {}) do
        local args = call["function"].arguments
        input[#input + 1] = {
          type = "function_call",
          call_id = call.id,
          name = call["function"].name,
          arguments = type(args) == "string" and args or vim.json.encode(args),
        }
      end
    end
  end
  local payload = C.options(config, { model = config.model, input = input, stream = false })
  if tools and #tools > 0 then
    payload.tools = C.tools(tools, "responses", config)
  end
  if config.name == "openai" then
    if payload.store == nil then
      payload.store = false
    end
    if payload.store == false then
      payload.include = payload.include or {}
      assert(
        type(payload.include) == "table" and vim.islist(payload.include),
        "Responses include must be an array"
      )
      if not vim.tbl_contains(payload.include, "reasoning.encrypted_content") then
        payload.include[#payload.include + 1] = "reasoning.encrypted_content"
      end
    end
  end
  return payload
end

function M.decode(config, response)
  assert(
    type(response.output) == "table" and vim.islist(response.output),
    "provider response has no output array"
  )
  assert(
    response.status ~= "failed"
      and response.status ~= "cancelled"
      and response.status ~= "queued"
      and response.status ~= "in_progress",
    "provider response is not complete; use the raw request API for background/polling"
  )
  local texts, calls, citations = {}, {}, C.citations(response.citations)
  for _, item in ipairs(response.output) do
    if item.type == "function_call" then
      calls[#calls + 1] = {
        id = item.call_id,
        type = "function",
        ["function"] = { name = item.name, arguments = item.arguments },
      }
    elseif item.type == "message" then
      for _, block in ipairs(item.content or {}) do
        if block.type == "output_text" or block.type == "text" then
          assert(type(block.text) == "string", "invalid provider text block")
          texts[#texts + 1] = block.text
          vim.list_extend(citations, C.citations(block.annotations or block.citations))
        elseif block.type == "refusal" then
          texts[#texts + 1] = block.refusal or ""
        else
          error("unsupported Responses content block; use the raw JSON request API", 0)
        end
      end
    elseif
      item.type == "custom_tool_call"
      or item.type == "computer_call"
      or item.type == "local_shell_call"
      or item.type == "shell_call"
      or item.type == "apply_patch_call"
      or item.type == "mcp_approval_request"
    then
      error("provider requested a non-function client tool; use the raw JSON request API", 0)
    else
      -- Reasoning and server-side search records are opaque, replayed verbatim,
      -- never rendered or mistaken for local function calls.
      assert(type(item.type) == "string", "invalid provider output item")
    end
  end
  local reason = response.incomplete_details and response.incomplete_details.reason
    or response.status
  return C.result(config, response, table.concat(texts, "\n"), calls, reason, citations)
end

return M
