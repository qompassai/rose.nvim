-- User commands for speech: :RoseDictate, :RoseSpeak, :RoseSpeechStop and
-- :RoseSpeechStatus. Command bodies stay thin; all limits and consent checks
-- live in rose.speech so the web UI and these commands share one code path.
local speech = require("rose.speech")
local M = { recording = nil, pending = nil }

local function notify(message, level)
  assert(type(message) == "string", "notification must be a string")
  vim.notify(message, level or vim.log.levels.INFO, { title = "Rose Speech" })
end

-- Where dictated text goes is decided when recording starts, not when the
-- transcript arrives, so the user may switch windows while speaking.
local function capture_target()
  local buffer, window = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(window)
  local ui = package.loaded["rose.native.ui"]
  local chat = ui ~= nil and ui.buffer == buffer
  return { buffer = buffer, window = window, row = cursor[1], col = cursor[2], chat = chat }
end

local function insert_text(target, text)
  assert(type(text) == "string", "text must be a string")
  assert(#text >= 1, "text must not be empty")
  if target.chat then
    -- The chat buffer is read-only: dictation becomes the next question.
    require("rose").ask(text)
    return
  end
  if not vim.api.nvim_buf_is_valid(target.buffer) then
    notify("dictation target buffer no longer exists", vim.log.levels.WARN)
    return
  end
  if not vim.bo[target.buffer].modifiable then
    notify("dictation target buffer is not modifiable", vim.log.levels.WARN)
    return
  end
  local lines = vim.split(text, "\n", { plain = true })
  local row = math.min(target.row, vim.api.nvim_buf_line_count(target.buffer))
  local line = vim.api.nvim_buf_get_lines(target.buffer, row - 1, row, false)[1] or ""
  local col = math.min(target.col, #line)
  vim.api.nvim_buf_set_text(target.buffer, row - 1, col, row - 1, col, lines)
end

local function dictate(fullconfig)
  if M.recording then
    notify("already recording; use :RoseSpeechStop to finish", vim.log.levels.WARN)
    return
  end
  local target = capture_target()
  local config = speech.config(fullconfig)
  local bounds = { max_seconds = config.record.max_seconds }
  M.recording = speech.record(fullconfig, bounds, function(err, capture)
    M.recording = nil
    if err then
      notify("recording failed: " .. err, vim.log.levels.WARN)
      return
    end
    notify(string.format("transcribing %.1f s of audio", capture.seconds))
    local upload = { path = capture.path, mime = "audio/wav" }
    M.pending = speech.transcribe(fullconfig, upload, function(stt_err, result)
      M.pending = nil
      if stt_err then
        notify("transcription failed: " .. stt_err, vim.log.levels.WARN)
        return
      end
      if result.text:match("^%s*$") then
        notify("transcription was empty", vim.log.levels.WARN)
        return
      end
      insert_text(target, result.text)
    end)
  end)
  notify("recording (max " .. config.record.max_seconds .. " s); :RoseSpeechStop to finish")
end

-- The last Rose response is the final "## <kind>" section of the chat buffer.
local function last_response()
  local ui = package.loaded["rose.native.ui"]
  if ui == nil or ui.buffer == nil or not vim.api.nvim_buf_is_valid(ui.buffer) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(ui.buffer, 0, -1, false)
  local start = nil
  for index = #lines, 1, -1 do
    if lines[index]:match("^## ") then
      start = index
      break
    end
  end
  if start == nil then
    return nil
  end
  local text = table.concat(lines, "\n", start + 1, #lines):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return nil
  end
  return text
end

local function speak_text(fullconfig, text)
  if M.pending then
    notify("speech is busy; use :RoseSpeechStop first", vim.log.levels.WARN)
    return
  end
  notify("synthesizing speech")
  M.pending = speech.speak(fullconfig, { text = text }, function(err, result)
    if err then
      M.pending = nil
      notify("speech failed: " .. err, vim.log.levels.WARN)
      return
    end
    M.pending = speech.play(fullconfig, result.path, function(play_err)
      M.pending = nil
      speech.remove(result.path)
      if play_err then
        notify("playback failed: " .. play_err, vim.log.levels.WARN)
      end
    end)
  end)
end

local function speak(fullconfig, args)
  local text
  if args.range > 0 then
    local lines = vim.api.nvim_buf_get_lines(0, args.line1 - 1, args.line2, false)
    text = table.concat(lines, "\n")
  elseif args.args ~= "" then
    text = args.args
  else
    text = last_response()
    if text == nil then
      notify("no Rose response to speak; select a range or pass text", vim.log.levels.WARN)
      return
    end
  end
  if text:match("^%s*$") then
    notify("nothing to speak", vim.log.levels.WARN)
    return
  end
  speak_text(fullconfig, text)
end

local function stop()
  if M.recording then
    M.recording.stop()
    notify("finishing recording")
    return
  end
  local count = speech.stop()
  M.pending = nil
  notify("stopped " .. count .. " speech operation(s)")
end

local function status(fullconfig)
  local capabilities = speech.capabilities(fullconfig)
  local lines = {}
  for _, kind in ipairs({ "stt", "tts" }) do
    for _, item in ipairs(capabilities[kind]) do
      local state = item.available and "available" or ("unavailable: " .. item.reason)
      lines[#lines + 1] = string.format("%s %-10s %s", kind, item.provider, state)
    end
  end
  local active = 0
  for _ in pairs(speech.active) do
    active = active + 1
  end
  local recording = tostring(M.recording ~= nil)
  lines[#lines + 1] = "recording: " .. recording .. ", active operations: " .. active
  notify(table.concat(lines, "\n"))
end

function M.register(fullconfig)
  assert(type(fullconfig) == "table", "fullconfig must be a table")
  vim.api.nvim_create_user_command("RoseDictate", function()
    dictate(fullconfig)
  end, { desc = "Record from the microphone, transcribe, and insert at the cursor" })
  vim.api.nvim_create_user_command("RoseSpeak", function(args)
    speak(fullconfig, args)
  end, { range = true, nargs = "?", desc = "Speak a range, given text, or the last Rose response" })
  vim.api.nvim_create_user_command("RoseSpeechStop", stop, {
    desc = "Finish the current recording or cancel speech operations",
  })
  vim.api.nvim_create_user_command("RoseSpeechStatus", function()
    status(fullconfig)
  end, { desc = "Show speech provider availability and active operations" })
end

return M
