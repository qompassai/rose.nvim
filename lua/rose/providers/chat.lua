-- OpenAI-compatible chat completions: OpenAI, xAI, NIM, and Sonar's text/search API.
local C = require("rose.providers.common")
local M = {}

function M.encode(config, messages, tools)
  C.messages(messages, config)
  local wire = {}
  for _, message in ipairs(messages) do
    assert(
      message.is_error == nil,
      "chat completions has no is_error field; encode errors in tool content or use raw JSON"
    )
    local item
    if message._provider then
      -- Preserve reasoning_content, refusal, annotations, and any provider
      -- extension in the assistant message rather than rebuilding lossy text.
      item = C.copy(message._provider.response.choices[1].message)
    else
      item = { role = message.role, content = message.content or "" }
      if message.role == "tool" then
        item.tool_call_id = message.tool_call_id
        item.name = message.tool_name or message.name
      else
        item.name = message.name
        if C.present(message.tool_calls) then
          item.tool_calls = C.calls(message.tool_calls)
          for _, call in ipairs(item.tool_calls) do
            if type(call["function"].arguments) == "table" then
              call["function"].arguments = vim.json.encode(call["function"].arguments)
            end
          end
        end
      end
    end
    wire[#wire + 1] = item
  end
  local payload = C.options(config, { model = config.model, messages = wire, stream = false })
  if tools and #tools > 0 then
    payload.tools = C.tools(tools, "chat")
    if config.name == "nvidia" and payload.tool_choice == nil then
      payload.tool_choice = "auto"
    end
  end
  if config.api == "sonar" then
    assert(
      not payload.tools and payload.tool_choice == nil and payload.parallel_tool_calls == nil,
      "Sonar is a search/chat API, not Rose custom tool calling; select Perplexity Agent API"
    )
    for _, message in ipairs(wire) do
      assert(
        message.role ~= "tool" and not C.present(message.tool_calls),
        "Sonar does not support Rose tool history"
      )
    end
  end
  return payload
end

function M.decode(config, response)
  assert(
    type(response.choices) == "table" and #response.choices == 1,
    "provider response must contain exactly one choice"
  )
  local choice = response.choices[1]
  assert(type(choice.message) == "table", "provider response has no assistant message")
  local message = choice.message
  assert(
    not C.present(message.function_call),
    "legacy function_call is unsupported; use modern tools"
  )
  local calls = C.present(message.tool_calls) and message.tool_calls or {}
  if config.api == "sonar" then
    assert(#calls == 0, "Sonar returned unsupported custom tool calls; select Perplexity Agent API")
  end
  local text = message.content
  if not C.present(text) and type(message.refusal) == "string" then
    text = message.refusal
  end
  local citations = C.citations(response.citations)
  for _, citation in ipairs(C.citations(message.annotations)) do
    citations[#citations + 1] = citation
  end
  -- Search results remain accessible even when the provider omits a citation array.
  if #citations == 0 then
    citations = C.citations(response.search_results)
  end
  return C.result(config, response, text, calls, choice.finish_reason, citations)
end

return M
