-- Incremental SSE parser. A raw event API, never wired directly into the text UI.
local M = {}

local event_bytes_max_default = 1024 * 1024

-- Fold the buffered field lines of one event into { event, id, data } text parts.
local function parse_fields(lines)
  local event, data, id = "message", {}, nil
  for _, line in ipairs(lines) do
    if line:sub(1, 1) ~= ":" then
      local name, value = line:match("^([^:]+):%s?(.*)$")
      if name == "data" then
        data[#data + 1] = value
      elseif name == "event" then
        event = value
      elseif name == "id" then
        id = value
      end
    end
  end
  return event, id, data
end

-- Decode the joined data text into an event item, or return nil plus a stream error.
local function decode_item(event, id, text)
  local item = { event = event, id = id }
  if text == "[DONE]" then
    item.done = true
    return item
  end
  local ok, value = pcall(vim.json.decode, text)
  if not ok or type(value) ~= "table" then
    return nil, "invalid provider SSE JSON"
  end
  item.data = value
  local api_error = event == "error"
    or value.type == "error"
    or value.error
    or value.type == "response.failed"
  if api_error then
    return nil, "provider returned a streaming API error"
  end
  return item
end

-- Complete one buffered event: parse, decode, and hand it to the consumer.
local function dispatch(state)
  if #state.lines == 0 then
    return
  end
  local event, id, data = parse_fields(state.lines)
  state.lines, state.bytes = {}, 0
  if #data == 0 then
    return
  end
  local item, err = decode_item(event, id, table.concat(data, "\n"))
  if not item then
    state.failed = err
    return
  end
  state.events = state.events + 1
  if state.on_event then
    vim.schedule(function()
      -- Callers opt into raw events, which can contain private reasoning.
      state.on_event(item)
    end)
  end
end

local function feed(state, chunk)
  if state.failed then
    return
  end
  state.pending = state.pending .. chunk
  -- Each iteration consumes at least the newline, so #pending bounds the loop.
  for _ = 1, #state.pending do
    local at = state.pending:find("\n", 1, true)
    if not at then
      break
    end
    local line = state.pending:sub(1, at - 1):gsub("\r$", "")
    state.pending = state.pending:sub(at + 1)
    state.bytes = state.bytes + #line
    if state.bytes > state.event_bytes_max then
      state.failed = "provider SSE event exceeds size limit"
      return
    end
    if line == "" then
      dispatch(state)
    else
      state.lines[#state.lines + 1] = line
    end
    if state.failed then
      return
    end
  end
  if state.bytes + #state.pending > state.event_bytes_max then
    state.failed = "provider SSE event exceeds size limit"
  end
end

local function finish(state)
  if state.failed then
    return nil, state.failed
  end
  if state.pending ~= "" or #state.lines > 0 then
    return nil, "truncated provider SSE event"
  end
  return { stream = true, events = state.events }
end

function M.new(on_event, max_event_bytes)
  assert(on_event == nil or type(on_event) == "function", "sse.new: on_event must be a function")
  assert(
    max_event_bytes == nil or (type(max_event_bytes) == "number" and max_event_bytes > 0),
    "sse.new: max_event_bytes must be a positive number"
  )
  local state = {
    on_event = on_event,
    event_bytes_max = max_event_bytes or event_bytes_max_default,
    pending = "",
    lines = {},
    bytes = 0,
    events = 0,
    failed = nil,
  }
  return {
    feed = function(chunk)
      feed(state, chunk)
    end,
    finish = function()
      return finish(state)
    end,
    error = function()
      return state.failed
    end,
  }
end

return M
