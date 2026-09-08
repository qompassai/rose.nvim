-- Microphone capture and playback through external command-line tools. Rose
-- never links audio libraries: the user's own PipeWire/ALSA/FFmpeg binaries do
-- the work, and every process has a hard time bound and an explicit kill path.
local deliver = require("rose.speech.deliver")
local M = {}
local uv = vim.uv or vim.loop

-- Candidates in preference order. The output path is appended as the final
-- argument, which every listed tool accepts. 16 kHz mono PCM WAV keeps uploads
-- small and is what speech models are trained on.
M.recorders = {
  { "pw-record", "--rate", "16000", "--channels", "1", "--format", "s16" },
  { "arecord", "--quiet", "--format", "S16_LE", "--rate", "16000", "--channels", "1" },
  {
    "ffmpeg",
    "-loglevel",
    "quiet",
    "-y",
    "-f",
    "pulse",
    "-i",
    "default",
    "-ac",
    "1",
    "-ar",
    "16000",
  },
}
-- pw-play/paplay/aplay decode WAV only, so MP3 needs a real decoder.
M.players = {
  wav = {
    { "pw-play" },
    { "paplay" },
    { "aplay", "--quiet" },
    { "mpv", "--no-video", "--really-quiet" },
    { "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet" },
  },
  mp3 = {
    { "mpv", "--no-video", "--really-quiet" },
    { "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet" },
  },
}
M.record_seconds_max = 600
M.play_seconds_max = 600
M.stop_grace_ms = 3000
-- A canonical PCM WAV header is 44 bytes; anything not larger holds no samples.
M.wav_header_bytes = 44

local function argv_valid(argv)
  if type(argv) ~= "table" or #argv == 0 or #argv > 64 then
    return false
  end
  for index = 1, #argv do
    if type(argv[index]) ~= "string" or argv[index] == "" or argv[index]:find("\0", 1, true) then
      return false
    end
  end
  return true
end

-- Picks the configured command or the first installed candidate. Returns a
-- fresh copy so callers may append the path without mutating the tables above.
---@return string[]? argv
---@return string? error
function M.detect(candidates, configured, kind)
  assert(type(candidates) == "table", "candidates must be a list")
  assert(type(kind) == "string", "kind must be a string")
  if configured ~= nil then
    assert(argv_valid(configured), "speech." .. kind .. ".cmd must be a non-empty argv table")
    if vim.fn.executable(configured[1]) ~= 1 then
      return nil, kind .. " command not found: " .. configured[1]
    end
    return (vim.deepcopy(configured))
  end
  for index = 1, #candidates do
    local candidate = candidates[index]
    assert(argv_valid(candidate), "built-in candidate must be valid")
    if vim.fn.executable(candidate[1]) == 1 then
      return (vim.deepcopy(candidate))
    end
  end
  local names = {}
  for index = 1, #candidates do
    names[index] = candidates[index][1]
  end
  local listed = table.concat(names, ", ")
  return nil, "no " .. kind .. " tool found (" .. listed .. "); set speech." .. kind .. ".cmd"
end

local function close_timer(timer)
  if timer then
    timer:stop()
    timer:close()
  end
  return nil
end

-- Records until stop(), cancel() or max_seconds. stop() sends SIGINT first so
-- the tool can finalize the WAV header, then SIGKILL after a grace period.
function M.record(argv, path, max_seconds, callback)
  assert(argv_valid(argv), "recorder argv must be valid")
  assert(type(path) == "string", "path must be a string")
  assert(path:sub(1, 1) == "/", "path must be absolute")
  assert(type(max_seconds) == "number", "max_seconds must be a number")
  assert(max_seconds >= 1, "max_seconds must be at least 1")
  assert(max_seconds <= M.record_seconds_max, "max_seconds exceeds the recording limit")
  assert(type(callback) == "function", "callback must be a function")
  local token, started_ns = {}, uv.hrtime()
  ---@type vim.SystemObj?
  local handle
  local done, cancelled, stopping, timer, grace = false, false, false, nil, nil
  local function finish(err, result)
    if done then
      return
    end
    done = true
    timer, grace = close_timer(timer), close_timer(grace)
    deliver.later(callback, err, result)
  end
  local function exited(result)
    if cancelled then
      uv.fs_unlink(path)
      return
    end
    local stat = uv.fs_stat(path)
    if not stat or stat.size <= M.wav_header_bytes then
      uv.fs_unlink(path)
      finish("recorder produced no audio (exit code " .. tostring(result.code) .. ")")
      return
    end
    local seconds = (uv.hrtime() - started_ns) / 1e9
    assert(seconds >= 0, "recording duration must be non-negative")
    finish(nil, { path = path, bytes = stat.size, seconds = seconds })
  end
  function token.stop()
    if done or stopping or not handle then
      return
    end
    stopping = true
    pcall(handle.kill, handle, 2)
    grace = uv.new_timer()
    if not grace then
      cancelled = true
      finish("could not create recorder stop timer")
      pcall(handle.kill, handle, 9)
      return
    end
    grace:start(M.stop_grace_ms, 0, function()
      if handle then
        pcall(handle.kill, handle, 9)
      end
    end)
  end
  function token.cancel()
    if done then
      return
    end
    cancelled = true
    finish("cancelled")
    if handle then
      pcall(handle.kill, handle, 9)
    end
  end
  timer = uv.new_timer()
  if not timer then
    finish("could not create recorder timeout timer")
    return token
  end
  local command = vim.deepcopy(argv)
  command[#command + 1] = path
  local silent = { stdin = false, stdout = false, stderr = false }
  local ok, result = pcall(vim.system, command, silent, exited)
  if not ok then
    finish("could not start recorder")
    return token
  end
  handle = result
  if timer then
    timer:start(max_seconds * 1000, 0, token.stop)
  end
  return token
end

-- Plays one file to completion, bounded by play_seconds_max.
function M.play(argv, path, callback)
  assert(argv_valid(argv), "player argv must be valid")
  assert(type(path) == "string", "path must be a string")
  assert(path:sub(1, 1) == "/", "path must be absolute")
  assert(type(callback) == "function", "callback must be a function")
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return deliver.rejected(callback, "audio file does not exist")
  end
  local token, done, timer = {}, false, nil
  ---@type vim.SystemObj?
  local handle
  local function finish(err)
    if done then
      return
    end
    done = true
    timer = close_timer(timer)
    deliver.later(callback, err)
  end
  function token.cancel()
    if done then
      return
    end
    finish("cancelled")
    if handle then
      pcall(handle.kill, handle, 9)
    end
  end
  timer = uv.new_timer()
  if not timer then
    finish("could not create playback timeout timer")
    return token
  end
  local command = vim.deepcopy(argv)
  command[#command + 1] = path
  local silent = { stdin = false, stdout = false, stderr = false }
  local function exited(exit)
    if exit.code == 0 then
      finish(nil)
    else
      finish("player exited with code " .. tostring(exit.code))
    end
  end
  local ok, result = pcall(vim.system, command, silent, exited)
  if not ok then
    finish("could not start player")
    return token
  end
  handle = result
  if timer then
    timer:start(M.play_seconds_max * 1000, 0, function()
      finish("playback exceeded the time limit")
      if handle then
        pcall(handle.kill, handle, 9)
      end
    end)
  end
  return token
end

return M
