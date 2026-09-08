-- piper, local text-to-speech. The executable reads text on stdin and writes a
-- WAV file to `--output_file`. Rose never downloads voices; `speech.piper.model`
-- is passed through as `--model` when set.
local deliver = require("rose.speech.deliver")
local M = { name = "piper", timeout_ms = 120000 }
local uv = vim.uv or vim.loop
-- A canonical PCM WAV header is 44 bytes; anything not larger holds no samples.
local wav_header_bytes = 44

-- Returns the argv to run, or nil plus the reason piper is unavailable.
function M.resolve(speech)
  assert(type(speech) == "table", "speech configuration must be a table")
  assert(type(speech.piper) == "table", "speech.piper must be a table")
  local cmd, model = speech.piper.cmd, speech.piper.model
  if cmd == nil then
    return nil, "speech.piper.cmd is not configured"
  end
  assert(type(cmd) == "table", "speech.piper.cmd must be an argv table")
  assert(#cmd >= 1, "speech.piper.cmd must not be empty")
  assert(#cmd <= 64, "speech.piper.cmd has too many arguments")
  for index = 1, #cmd do
    assert(type(cmd[index]) == "string", "speech.piper.cmd entries must be strings")
    assert(cmd[index] ~= "", "speech.piper.cmd entries must not be empty")
  end
  assert(model == nil or type(model) == "string", "speech.piper.model must be a string")
  if vim.fn.executable(cmd[1]) ~= 1 then
    return nil, "piper executable not found: " .. cmd[1]
  end
  local argv = vim.deepcopy(cmd)
  if model then
    assert(model:sub(1, 1) == "/", "speech.piper.model must be an absolute path")
    argv[#argv + 1] = "--model"
    argv[#argv + 1] = model
  end
  return argv
end

function M.speak(argv, text, path, callback)
  assert(type(argv) == "table", "argv must be a table")
  assert(#argv >= 1, "argv must not be empty")
  assert(type(text) == "string", "text must be a string")
  assert(#text >= 1, "text must not be empty")
  assert(type(path) == "string", "path must be a string")
  assert(path:sub(1, 1) == "/", "path must be absolute")
  assert(type(callback) == "function", "callback must be a function")
  local token, done, timer = {}, false, nil
  ---@type vim.SystemObj?
  local handle
  local function finish(err, result)
    if done then
      return
    end
    done = true
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    if err then
      uv.fs_unlink(path)
    end
    deliver.later(callback, err, result)
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
    finish("could not create piper timeout timer")
    return token
  end
  local command = vim.deepcopy(argv)
  command[#command + 1] = "--output_file"
  command[#command + 1] = path
  local options = { stdin = text, stdout = false, stderr = false }
  local ok, result = pcall(vim.system, command, options, function(exit)
    if done then
      uv.fs_unlink(path)
      return
    end
    if exit.code ~= 0 then
      finish("piper exited with code " .. tostring(exit.code))
      return
    end
    local stat = uv.fs_stat(path)
    if not stat or stat.size <= wav_header_bytes then
      finish("piper produced no audio")
      return
    end
    finish(nil, { path = path, bytes = stat.size })
  end)
  if not ok then
    finish("could not start piper")
    return token
  end
  handle = result
  if timer then
    timer:start(M.timeout_ms, 0, function()
      finish("piper exceeded the time limit")
      if handle then
        pcall(handle.kill, handle, 9)
      end
    end)
  end
  return token
end

return M
