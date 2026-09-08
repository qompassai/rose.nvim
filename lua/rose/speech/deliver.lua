-- Callback delivery for the speech subsystem. Every speech callback is invoked
-- from vim.schedule so callers may touch buffers and windows without checking
-- whether they were called synchronously or from a libuv thread.
local M = {}

-- Rejections are asynchronous like real results, so callers never need two code
-- paths, and a cancel before delivery is honoured exactly like a live cancel.
function M.rejected(callback, message)
  assert(type(callback) == "function", "callback must be a function")
  assert(type(message) == "string", "rejection message must be a string")
  assert(message ~= "", "rejection message must not be empty")
  local cancelled, delivered = false, false
  vim.schedule(function()
    assert(not delivered, "rejection delivered twice")
    delivered = true
    if cancelled then
      callback("cancelled")
    else
      callback(message)
    end
  end)
  return {
    cancel = function()
      cancelled = true
    end,
    stop = function()
      cancelled = true
    end,
  }
end

-- Strips Lua source positions from assertion messages. Speech errors may
-- otherwise leak file paths of the plugin or partial audio metadata.
function M.safe_error(err)
  local text = tostring(err):gsub("^.-:%d+:%s*", "")
  local line = text:match("^[^\r\n]+")
  if line == nil then
    return "speech request failed"
  end
  assert(#line >= 1, "error line must not be empty")
  return line
end

-- Schedules `callback(...)` exactly once. Used by process-based engines whose
-- exit callbacks run outside the main loop.
function M.later(callback, ...)
  assert(type(callback) == "function", "callback must be a function")
  local arguments, count = { ... }, select("#", ...)
  assert(count <= 4, "speech callbacks carry at most four values")
  vim.schedule(function()
    callback(unpack(arguments, 1, count))
  end)
end

return M
