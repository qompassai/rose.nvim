-- Native speech: dictation (speech-to-text) and spoken responses (text-to-speech).
-- Cloud engines reuse the provider transport and its host-bound credentials;
-- local engines (whisper.cpp, piper) run only when explicitly configured.
-- There is no realtime or streaming audio: record, then transcribe; synthesize,
-- then play. Every step has a byte, character or time limit.
local deliver = require("rose.speech.deliver")
local http = require("rose.speech.http")
local audio = require("rose.speech.audio")
local piper = require("rose.speech.piper")
local whisper = require("rose.speech.whisper")
local M = { active = {} }
local uv = vim.uv or vim.loop

M.defaults = {
  enabled = false, -- master gate; cloud speech additionally requires providers.allow_cloud
  stt = { provider = "auto", model = nil, language = "auto" },
  tts = { provider = "auto", model = nil, voice = nil, format = "mp3" },
  record = { cmd = nil, max_seconds = 60 }, -- cmd: explicit argv table; nil = detect
  play = { cmd = nil }, -- nil = detect pw-play/paplay/aplay/mpv/ffplay
  whisper = { url = nil }, -- local whisper.cpp server, loopback http only
  piper = { cmd = nil, model = nil }, -- local piper TTS executable
  max_audio_bytes = 25 * 1024 * 1024,
  max_text_chars = 4096,
}
M.stt_names = { "openai", "xai", "whisper", "anthropic", "perplexity", "nvidia" }
M.tts_names = { "openai", "xai", "piper", "anthropic", "perplexity", "nvidia" }
M.formats = { mp3 = "audio/mpeg", wav = "audio/wav" }
M.mime_by_extension = {
  wav = "audio/wav",
  mp3 = "audio/mpeg",
  mpga = "audio/mpeg",
  mpeg = "audio/mpeg",
  webm = "audio/webm",
  ogg = "audio/ogg",
  oga = "audio/ogg",
  m4a = "audio/mp4",
  mp4 = "audio/mp4",
  flac = "audio/flac",
}
M.extension_by_mime = {
  ["audio/wav"] = "wav",
  ["audio/x-wav"] = "wav",
  ["audio/wave"] = "wav",
  ["audio/mpeg"] = "mp3",
  ["audio/webm"] = "webm",
  ["audio/ogg"] = "ogg",
  ["audio/mp4"] = "m4a",
  ["audio/flac"] = "flac",
}
local sequence = 0

local function integer(value, lo, hi, name)
  assert(type(value) == "number", name .. " must be a number")
  assert(value % 1 == 0, name .. " must be an integer")
  assert(value >= lo, name .. " must be at least " .. lo)
  assert(value <= hi, name .. " must be at most " .. hi)
end

local function optional_string(value, name)
  assert(value == nil or type(value) == "string", name .. " must be a string or nil")
  if value ~= nil then
    assert(value:match("%S"), name .. " must not be blank")
    assert(not value:find("[%c]"), name .. " must not contain control characters")
    assert(#value <= 256, name .. " is too long")
  end
end

-- Until config.lua wiring lands the section may be partial or absent, so the
-- defaults are merged here. Configuration mistakes are programmer errors.
function M.config(fullconfig)
  assert(type(fullconfig) == "table", "fullconfig must be a table")
  local section = fullconfig.speech or M.defaults
  assert(type(section) == "table", "speech configuration must be a table")
  local speech = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), section)
  assert(type(speech.enabled) == "boolean", "speech.enabled must be a boolean")
  for _, kind in ipairs({ "stt", "tts" }) do
    assert(type(speech[kind]) == "table", "speech." .. kind .. " must be a table")
    local provider = speech[kind].provider
    assert(type(provider) == "string", "speech." .. kind .. ".provider must be a string")
    optional_string(speech[kind].model, "speech." .. kind .. ".model")
  end
  optional_string(speech.stt.language, "speech.stt.language")
  optional_string(speech.tts.voice, "speech.tts.voice")
  assert(M.formats[speech.tts.format], "speech.tts.format must be mp3 or wav")
  assert(type(speech.record) == "table", "speech.record must be a table")
  assert(type(speech.play) == "table", "speech.play must be a table")
  assert(type(speech.whisper) == "table", "speech.whisper must be a table")
  assert(type(speech.piper) == "table", "speech.piper must be a table")
  integer(speech.record.max_seconds, 1, audio.record_seconds_max, "speech.record.max_seconds")
  integer(speech.max_audio_bytes, 1024, 256 * 1024 * 1024, "speech.max_audio_bytes")
  integer(speech.max_text_chars, 1, 100000, "speech.max_text_chars")
  optional_string(speech.whisper.url, "speech.whisper.url")
  return speech
end

-- All temporary audio lives in one private directory so cleanup is auditable.
function M.temp_dir()
  local dir = vim.fn.stdpath("cache") .. "/rose/speech"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p", 448)
  end
  assert(vim.fn.isdirectory(dir) == 1, "speech cache directory must exist")
  return dir
end

function M.temp_path(kind, extension)
  assert(type(kind) == "string", "kind must be a string")
  assert(kind:match("^%l+$"), "kind must be lowercase letters")
  assert(M.mime_by_extension[extension], "extension must be a known audio extension")
  sequence = (sequence + 1) % 1000000
  local stamp = math.floor(uv.hrtime() % 1000000000)
  local name = string.format("%s-%d-%d-%06d.%s", kind, uv.os_getpid(), stamp, sequence, extension)
  local path = M.temp_dir() .. "/" .. name
  assert(path:sub(1, 1) == "/", "temp path must be absolute")
  return path
end

-- Deletes a file only if it lives in the speech cache; user files are never
-- touched. Returns whether a deletion was attempted.
function M.remove(path)
  assert(type(path) == "string", "path must be a string")
  local dir = M.temp_dir() .. "/"
  if path:sub(1, #dir) ~= dir then
    return false
  end
  assert(not path:find("/../", 1, true), "temp paths never contain parent segments")
  uv.fs_unlink(path)
  return true
end

local function availability(fullconfig, speech, kind, name)
  assert(kind == "stt" or kind == "tts", "kind must be stt or tts")
  if speech.enabled ~= true then
    return false, "speech is disabled; set speech.enabled = true"
  end
  if http.unavailable[name] then
    return false, http.unavailable[name]
  end
  if name == "whisper" then
    if speech.whisper.url == nil then
      return false, "speech.whisper.url is not configured"
    end
    local ok, err = pcall(http.resolve_whisper, speech)
    if not ok then
      return false, deliver.safe_error(err)
    end
    return true
  end
  if name == "piper" then
    local argv, reason = piper.resolve(speech)
    if not argv then
      return false, reason
    end
    return true
  end
  assert(http.descriptors[name], "cloud availability asked for unknown provider")
  local consented, consent_reason = http.consent(fullconfig)
  if not consented then
    return false, consent_reason
  end
  local ok, err = pcall(http.resolve_cloud, fullconfig, name)
  if not ok then
    return false, deliver.safe_error(err)
  end
  if vim.fn.executable("curl") ~= 1 then
    return false, "curl is required for cloud speech"
  end
  return true
end

-- Model/voice overrides apply only to the provider they were configured for
-- (speech.<kind>.provider == name); "auto" always uses provider defaults so an
-- OpenAI model name can never be sent to xAI.
local function selection(speech, kind, name)
  local descriptor = http.descriptors[name]
  local model, voice = nil, nil
  if descriptor then
    model = descriptor[kind].model
    if kind == "tts" then
      voice = descriptor.tts.voice
    end
  end
  if name == "piper" then
    model = speech.piper.model
  end
  if speech[kind].provider == name then
    if speech[kind].model ~= nil then
      model = speech[kind].model
    end
    if kind == "tts" and speech.tts.voice ~= nil then
      voice = speech.tts.voice
    end
  end
  return model, voice
end

local function entry(fullconfig, speech, kind, name)
  local available, reason = availability(fullconfig, speech, kind, name)
  if available then
    assert(reason == nil, "available providers carry no reason")
  else
    assert(type(reason) == "string", "unavailable providers must explain why")
  end
  local model, voice = selection(speech, kind, name)
  local item = { provider = name, model = model, available = available, reason = reason }
  if kind == "tts" then
    item.voice = voice
  end
  return item
end

function M.capabilities(fullconfig)
  local speech = M.config(fullconfig)
  local result = { stt = {}, tts = {} }
  for index = 1, #M.stt_names do
    result.stt[index] = entry(fullconfig, speech, "stt", M.stt_names[index])
  end
  for index = 1, #M.tts_names do
    result.tts[index] = entry(fullconfig, speech, "tts", M.tts_names[index])
  end
  assert(#result.stt == #M.stt_names, "every STT provider must be listed")
  assert(#result.tts == #M.tts_names, "every TTS provider must be listed")
  return result
end

local function options_text(fullconfig, speech, kind)
  local names = kind == "stt" and M.stt_names or M.tts_names
  local available = {}
  for index = 1, #names do
    if availability(fullconfig, speech, kind, names[index]) then
      available[#available + 1] = names[index]
    end
  end
  if #available == 0 then
    return "none available; configure speech.whisper.url or speech.piper.cmd, or set "
      .. "providers.provider to openai or xai with providers.enabled and providers.allow_cloud"
  end
  return "available: " .. table.concat(available, ", ")
end

-- "auto" prefers a configured local engine, then the chat provider when it can
-- speak and cloud is allowed. A configured local engine that is broken fails
-- loudly instead of silently sending audio to the cloud.
local function select_provider(fullconfig, speech, kind, requested)
  assert(requested == nil or type(requested) == "string", "provider must be a string or nil")
  local names = kind == "stt" and M.stt_names or M.tts_names
  local wanted = requested or speech[kind].provider
  if wanted == "auto" then
    local local_configured
    if kind == "stt" then
      local_configured = speech.whisper.url ~= nil
    else
      local_configured = speech.piper.cmd ~= nil
    end
    if local_configured then
      wanted = kind == "stt" and "whisper" or "piper"
    else
      local chat_provider = (fullconfig.providers or {}).provider
      if http.descriptors[chat_provider] then
        wanted = chat_provider
      else
        return nil, "no speech provider selected (" .. options_text(fullconfig, speech, kind) .. ")"
      end
    end
  end
  if not vim.tbl_contains(names, wanted) then
    return nil, "unknown speech provider: " .. wanted
  end
  local available, reason = availability(fullconfig, speech, kind, wanted)
  if not available then
    return nil, wanted .. ": " .. reason
  end
  return wanted
end

-- Tracks a token so :RoseSpeechStop and M.stop can cancel everything at once.
local function track(kind, callback, start)
  local slot = { kind = kind }
  M.active[slot] = true
  local token = start(function(err, result)
    M.active[slot] = nil
    callback(err, result)
  end)
  assert(type(token) == "table", "speech operations return a token")
  assert(type(token.cancel) == "function", "speech tokens must be cancellable")
  slot.token = token
  return token
end

local function upload_of(request, max_audio_bytes)
  local stat = uv.fs_stat(request.path)
  if not stat or stat.type ~= "file" then
    return nil, "audio file does not exist"
  end
  if stat.size == 0 then
    return nil, "audio file is empty"
  end
  if stat.size > max_audio_bytes then
    return nil, "audio file exceeds speech.max_audio_bytes"
  end
  local extension = (request.path:match("%.(%w+)$") or ""):lower()
  local mime = request.mime or M.mime_by_extension[extension]
  if type(mime) ~= "string" or not M.extension_by_mime[mime] then
    return nil, "unsupported audio mime type; use wav, mp3, webm, ogg, m4a or flac"
  end
  -- The upload name is synthesized so odd local file names never hit the wire.
  return { path = request.path, mime = mime, filename = "audio." .. M.extension_by_mime[mime] }
end

local function language_of(request, speech)
  local language = request.language or speech.stt.language
  if language == nil or language == "auto" then
    return true, nil
  end
  if type(language) ~= "string" or #language > 16 or not language:match("^%a[%a%-]*$") then
    return false, "invalid language code"
  end
  return true, language
end

function M.transcribe(fullconfig, request, callback)
  assert(type(request) == "table", "transcribe request must be a table")
  assert(type(request.path) == "string", "request.path must be a string")
  assert(request.path:sub(1, 1) == "/", "request.path must be absolute")
  assert(request.mime == nil or type(request.mime) == "string", "request.mime must be a string")
  assert(request.keep == nil or type(request.keep) == "boolean", "request.keep must be a boolean")
  assert(type(callback) == "function", "callback must be a function")
  local speech = M.config(fullconfig)
  local function finish(err, result)
    if request.keep ~= true then
      M.remove(request.path)
    end
    callback(err, result)
  end
  local name, reason = select_provider(fullconfig, speech, "stt", request.provider)
  if not name then
    return deliver.rejected(finish, reason)
  end
  local upload, upload_error = upload_of(request, speech.max_audio_bytes)
  if not upload then
    return deliver.rejected(finish, upload_error)
  end
  local language_ok, language = language_of(request, speech)
  if not language_ok then
    return deliver.rejected(finish, language)
  end
  local descriptor = name == "whisper" and whisper or http.descriptors[name]
  local model = selection(speech, "stt", name)
  if model ~= nil and descriptor.stt.model == nil then
    return deliver.rejected(finish, name .. " does not accept a model; unset speech.stt.model")
  end
  local resolved, config
  if name == "whisper" then
    resolved, config = pcall(http.resolve_whisper, speech)
  else
    resolved, config = pcall(http.resolve_cloud, fullconfig, name)
  end
  if not resolved then
    return deliver.rejected(finish, deliver.safe_error(config))
  end
  return track("transcribe", finish, function(done)
    return http.request(config, {
      path = descriptor.stt.path,
      form = descriptor.stt_form(upload, model, language),
      max_upload_bytes = speech.max_audio_bytes,
    }, function(err, response)
      if err then
        done(err)
        return
      end
      local decoded, decode_error = descriptor.stt_decode(response)
      if not decoded then
        done(decode_error)
        return
      end
      done(nil, {
        text = decoded.text,
        provider = name,
        model = model,
        duration = decoded.duration,
      })
    end)
  end)
end

local function speak_piper(speech, text, callback)
  local argv, reason = piper.resolve(speech)
  if not argv then
    return deliver.rejected(callback, reason)
  end
  local output = M.temp_path("speech", "wav")
  return track("speak", callback, function(done)
    return piper.speak(argv, text, output, function(err, result)
      if err then
        done(err)
        return
      end
      done(nil, {
        path = result.path,
        mime = "audio/wav",
        bytes = result.bytes,
        provider = "piper",
        model = speech.piper.model,
        voice = nil,
      })
    end)
  end)
end

local function speak_cloud(fullconfig, speech, name, request, callback)
  local descriptor = http.descriptors[name]
  assert(descriptor, "cloud speech requires a descriptor")
  local text = request.text
  if #text > descriptor.tts.text_chars_max then
    return deliver.rejected(
      callback,
      name .. " speech accepts at most " .. descriptor.tts.text_chars_max .. " characters"
    )
  end
  local format = request.format or speech.tts.format
  assert(M.formats[format], "format must be mp3 or wav")
  local model, voice = selection(speech, "tts", name)
  if request.voice ~= nil then
    voice = request.voice
  end
  if model ~= nil and descriptor.tts.model == nil then
    return deliver.rejected(callback, name .. " does not accept a model; unset speech.tts.model")
  end
  if type(voice) ~= "string" or #voice > 64 or not voice:match("^[%w_%-]+$") then
    return deliver.rejected(callback, "invalid voice name")
  end
  local resolved, config = pcall(http.resolve_cloud, fullconfig, name)
  if not resolved then
    return deliver.rejected(callback, deliver.safe_error(config))
  end
  local output = M.temp_path("speech", format)
  return track("speak", callback, function(done)
    return http.request(config, {
      path = descriptor.tts.path,
      body = descriptor.tts_body(text, model, voice, format),
      output_path = output,
      max_output_bytes = speech.max_audio_bytes,
    }, function(err, result)
      if err then
        done(err)
        return
      end
      if result.bytes == 0 then
        M.remove(result.path)
        done("speech provider returned empty audio")
        return
      end
      done(nil, {
        path = result.path,
        mime = M.formats[format],
        bytes = result.bytes,
        provider = name,
        model = model,
        voice = voice,
      })
    end)
  end)
end

function M.speak(fullconfig, request, callback)
  assert(type(request) == "table", "speak request must be a table")
  assert(type(request.text) == "string", "request.text must be a string")
  assert(request.voice == nil or type(request.voice) == "string", "request.voice must be a string")
  assert(request.format == nil or M.formats[request.format], "request.format must be mp3 or wav")
  assert(type(callback) == "function", "callback must be a function")
  local speech = M.config(fullconfig)
  if request.text:match("^%s*$") then
    return deliver.rejected(callback, "text is empty")
  end
  if #request.text > speech.max_text_chars then
    return deliver.rejected(callback, "text exceeds speech.max_text_chars")
  end
  local name, reason = select_provider(fullconfig, speech, "tts", request.provider)
  if not name then
    return deliver.rejected(callback, reason)
  end
  if name == "piper" then
    -- piper writes WAV only; the result reports the real mime type.
    return speak_piper(speech, request.text, callback)
  end
  return speak_cloud(fullconfig, speech, name, request, callback)
end

function M.record(fullconfig, request, callback)
  assert(type(request) == "table", "record request must be a table")
  assert(type(callback) == "function", "callback must be a function")
  local speech = M.config(fullconfig)
  if speech.enabled ~= true then
    return deliver.rejected(callback, "speech is disabled; set speech.enabled = true")
  end
  local max_seconds = request.max_seconds or speech.record.max_seconds
  assert(type(max_seconds) == "number", "max_seconds must be a number")
  if max_seconds % 1 ~= 0 or max_seconds < 1 or max_seconds > audio.record_seconds_max then
    local limit = audio.record_seconds_max
    return deliver.rejected(callback, "max_seconds must be an integer between 1 and " .. limit)
  end
  local argv, reason = audio.detect(audio.recorders, speech.record.cmd, "record")
  if not argv then
    return deliver.rejected(callback, reason)
  end
  local path = M.temp_path("record", "wav")
  return track("record", callback, function(done)
    return audio.record(argv, path, max_seconds, done)
  end)
end

function M.play(fullconfig, path, callback)
  assert(type(path) == "string", "path must be a string")
  assert(path:sub(1, 1) == "/", "path must be absolute")
  assert(type(callback) == "function", "callback must be a function")
  local speech = M.config(fullconfig)
  if speech.enabled ~= true then
    return deliver.rejected(callback, "speech is disabled; set speech.enabled = true")
  end
  local extension = (path:match("%.(%w+)$") or ""):lower()
  local candidates = audio.players[extension]
  if not candidates then
    return deliver.rejected(callback, "playback supports .wav and .mp3 files only")
  end
  local argv, reason = audio.detect(candidates, speech.play.cmd, "play")
  if not argv then
    return deliver.rejected(callback, reason)
  end
  return track("play", callback, function(done)
    return audio.play(argv, path, done)
  end)
end

-- Cancels every tracked operation. Bounded by the number of live slots.
function M.stop()
  local slots = {}
  for slot in pairs(M.active) do
    slots[#slots + 1] = slot
  end
  for index = 1, #slots do
    local token = slots[index].token
    if token then
      token.cancel()
    end
  end
  return #slots
end

function M.setup(fullconfig)
  M.config(fullconfig)
  require("rose.speech.commands").register(fullconfig)
end

return M
