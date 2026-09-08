-- Run offline: ROSE_TEST_PYTHON=python3 nvim --headless -u NONE -l tests/speech.lua
-- Goal: prove the speech subsystem end to end against a loopback fixture that
-- emulates OpenAI, xAI and whisper.cpp wire formats and fake audio tools.
-- Method: each `test` block is one assertion group; `await` turns callback
-- APIs into synchronous checks with a deadline and an exactly-once guarantee.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local passed, failures = 0, {}
local function test(label, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS " .. label)
  else
    failures[#failures + 1] = label .. ": " .. err
    print("FAIL " .. label .. ": " .. err)
  end
end
local function equal(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local function await(start, timeout)
  local done, err, result, calls = false, nil, nil, 0
  local token = start(function(e, r)
    calls = calls + 1
    err, result, done = e, r, true
  end)
  assert(
    vim.wait(timeout or 5000, function()
      return done
    end, 5),
    "callback deadline exceeded"
  )
  assert(calls == 1, "callback called more than once")
  return err, result, token
end
local function contains(text, needle)
  assert(type(text) == "string", "expected a string, got " .. vim.inspect(text))
  local message = vim.inspect(text) .. " does not contain " .. vim.inspect(needle)
  assert(text:find(needle, 1, true), message)
end

local python = vim.env.ROSE_TEST_PYTHON or "python3"
local fixture_script = root .. "/tests/speech_fixture.py"
local port, server_error
local fixture = vim.system({ python, fixture_script }, {
  text = true,
  clear_env = true,
  env = { PATH = vim.env.PATH or "/usr/bin:/bin", LANG = "C" },
  stdout = function(_, chunk)
    if chunk then
      port = tonumber(chunk:match("%d+"))
    end
  end,
  stderr = function(_, chunk)
    if chunk then
      server_error = chunk
    end
  end,
})
assert(
  vim.wait(5000, function()
    return port ~= nil or server_error ~= nil
  end, 5),
  "fixture did not start"
)
assert(port, server_error)
local authority = "127.0.0.1:" .. port
local base = "http://" .. authority
local fake = "rose-fixture-fake-key"
vim.env.OPENAI_API_KEY = fake
vim.env.XAI_API_KEY = fake

local speech = require("rose.speech")
local transport = require("rose.providers.transport")
local uv = vim.uv or vim.loop

local function config(overrides, prefix)
  prefix = prefix or ""
  local cloud = function(name)
    return {
      endpoint = base .. prefix .. "/" .. name,
      credential_host = authority,
      allow_insecure_local = true,
      timeout = 4000,
    }
  end
  local cfg = {
    speech = {
      enabled = true,
      record = { cmd = { python, fixture_script, "--recorder" }, max_seconds = 5 },
      play = { cmd = { python, fixture_script, "--player" } },
    },
    providers = {
      enabled = true,
      allow_cloud = true,
      provider = "openai",
      openai = cloud("openai"),
      xai = cloud("xai"),
    },
  }
  return vim.tbl_deep_extend("force", cfg, overrides or {})
end
local function with_whisper(cfg)
  cfg.speech.whisper = { url = base .. "/whisper" }
  return cfg
end
local function with_piper(cfg)
  cfg.speech.piper = { cmd = { python, fixture_script, "--piper" } }
  return cfg
end

-- A tiny but valid 16 kHz mono WAV: header plus 800 samples of silence.
local function wav_data(samples)
  local function u32(n)
    local b0, b1 = n % 256, math.floor(n / 256) % 256
    local b2, b3 = math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256
    return string.char(b0, b1, b2, b3)
  end
  local data = string.rep("\0\0", samples)
  return "RIFF"
    .. u32(36 + #data)
    .. "WAVEfmt "
    .. u32(16)
    .. "\1\0\1\0"
    .. u32(16000)
    .. u32(32000)
    .. "\2\0\16\0"
    .. "data"
    .. u32(#data)
    .. data
end
local function write_file(path, data)
  local handle = assert(io.open(path, "wb"))
  handle:write(data)
  handle:close()
  return path
end
local function temp_wav(samples)
  return write_file(speech.temp_path("test", "wav"), wav_data(samples or 800))
end
local function exists(path)
  return uv.fs_stat(path) ~= nil
end
local function temp_files(pattern)
  return vim.fn.glob(speech.temp_dir() .. "/" .. pattern, false, true)
end
local function find(list, provider)
  for _, item in ipairs(list) do
    if item.provider == provider then
      return item
    end
  end
  error("provider " .. provider .. " missing from capabilities")
end
local function transcribe(cfg, request)
  return await(function(cb)
    return speech.transcribe(cfg, request, cb)
  end)
end
local function speak(cfg, request)
  return await(function(cb)
    return speech.speak(cfg, request, cb)
  end)
end

test("defaults match the shared contract", function()
  equal(speech.defaults.enabled, false)
  equal(speech.defaults.stt, { provider = "auto", language = "auto" })
  equal(speech.defaults.tts, { provider = "auto", format = "mp3" })
  equal(speech.defaults.record.max_seconds, 60)
  equal(speech.defaults.max_audio_bytes, 25 * 1024 * 1024)
  equal(speech.defaults.max_text_chars, 4096)
  local resolved = speech.config({})
  equal(resolved.enabled, false)
  assert(not pcall(speech.config, { speech = { enabled = "yes" } }))
  assert(not pcall(speech.config, { speech = { tts = { format = "ogg" } } }))
  assert(not pcall(speech.config, { speech = { record = { max_seconds = 0 } } }))
  assert(not pcall(speech.config, { speech = { max_audio_bytes = 10 } }))
end)

test("capabilities: everything unavailable while speech is disabled", function()
  local caps = speech.capabilities(config({ speech = { enabled = false } }))
  equal(#caps.stt, 6)
  equal(#caps.tts, 6)
  for _, kind in ipairs({ "stt", "tts" }) do
    for _, item in ipairs(caps[kind]) do
      equal(item.available, false)
      contains(item.reason, "speech.enabled")
    end
  end
end)

test("capabilities: cloud needs providers.enabled and allow_cloud; locals do not", function()
  local cfg = with_whisper(with_piper(config({ providers = { allow_cloud = false } })))
  local caps = speech.capabilities(cfg)
  contains(find(caps.stt, "openai").reason, "allow_cloud")
  contains(find(caps.tts, "xai").reason, "leave your device")
  equal(find(caps.stt, "whisper").available, true)
  equal(find(caps.tts, "piper").available, true)
  cfg = with_whisper(config({ providers = { enabled = false } }))
  equal(find(speech.capabilities(cfg).stt, "openai").available, false)
  equal(find(speech.capabilities(cfg).stt, "whisper").available, true)
end)

test("capabilities: full matrix with defaults, models and voices", function()
  local caps = speech.capabilities(config())
  local openai_stt = find(caps.stt, "openai")
  equal(openai_stt, { provider = "openai", model = "gpt-4o-mini-transcribe", available = true })
  equal(find(caps.stt, "xai"), { provider = "xai", available = true })
  equal(find(caps.tts, "openai").model, "gpt-4o-mini-tts")
  equal(find(caps.tts, "openai").voice, "marin")
  equal(find(caps.tts, "xai").voice, "eve")
  equal(find(caps.stt, "whisper").reason, "speech.whisper.url is not configured")
  equal(find(caps.tts, "piper").reason, "speech.piper.cmd is not configured")
  for _, kind in ipairs({ "stt", "tts" }) do
    equal(find(caps[kind], "anthropic").reason, "provider has no speech API")
    contains(find(caps[kind], "perplexity").reason, "no speech API")
    local nvidia = "NVIDIA speech requires a self-hosted Speech NIM; not implemented"
    equal(find(caps[kind], "nvidia").reason, nvidia)
  end
end)

test("capabilities: overrides apply only to the configured provider", function()
  local cfg = config({ speech = { stt = { provider = "openai", model = "whisper-1" } } })
  local caps = speech.capabilities(cfg)
  equal(find(caps.stt, "openai").model, "whisper-1")
  equal(find(caps.stt, "xai").model, nil)
  cfg = config({ speech = { tts = { provider = "xai", voice = "ara" } } })
  equal(find(speech.capabilities(cfg).tts, "xai").voice, "ara")
  equal(find(speech.capabilities(cfg).tts, "openai").voice, "marin")
end)

test("capabilities never read keys or spawn processes", function()
  local original_env, original_system = vim.env, vim.system
  vim.env = setmetatable({}, {
    __index = function()
      error("unexpected environment read")
    end,
  })
  vim.system = function()
    error("unexpected process")
  end
  local ok, caps = pcall(speech.capabilities, with_whisper(with_piper(config())))
  vim.env, vim.system = original_env, original_system
  assert(ok, caps)
  equal(find(caps.stt, "openai").available, true)
end)

test("consent gate: transcribe refuses without speech.enabled", function()
  local path = temp_wav()
  local err = transcribe(config({ speech = { enabled = false } }), { path = path, keep = true })
  contains(err, "speech.enabled")
  assert(exists(path))
  speech.remove(path)
end)

test("consent gate: cloud transcribe needs both provider consent flags", function()
  for _, flag in ipairs({ "enabled", "allow_cloud" }) do
    local path = temp_wav()
    local cfg = config()
    cfg.providers[flag] = false
    local err = transcribe(cfg, { path = path, provider = "openai" })
    contains(err, "leave your device")
    assert(not exists(path), "temp upload must be cleaned after rejection")
  end
end)

test("consent gate: cloud speak needs both provider consent flags", function()
  for _, flag in ipairs({ "enabled", "allow_cloud" }) do
    local cfg = config()
    cfg.providers[flag] = false
    local err = speak(cfg, { text = "hello", provider = "xai" })
    contains(err, "leave your device")
  end
end)

test("local whisper works with cloud consent withheld", function()
  local cfg = with_whisper(config({ providers = { enabled = false, allow_cloud = false } }))
  local err, result = transcribe(cfg, { path = temp_wav(800) })
  assert(not err, err)
  equal(result, { text = "whisper:1644", provider = "whisper" })
end)

test("whisper URL must be loopback http", function()
  local cfg = config()
  cfg.speech.whisper = { url = "http://example.test:8080" }
  local err = transcribe(cfg, { path = temp_wav(), provider = "whisper" })
  contains(err, "loopback")
  cfg.speech.whisper = { url = "https://127.0.0.1:8080" }
  contains(transcribe(cfg, { path = temp_wav(), provider = "whisper" }), "plain loopback http")
end)

test("openai transcription round trip with default model and temp cleanup", function()
  local path = temp_wav(800)
  local err, result = transcribe(config(), { path = path })
  assert(not err, err)
  local model = "gpt-4o-mini-transcribe"
  equal(result, { text = "openai:" .. model .. ":1644", provider = "openai", model = model })
  assert(not exists(path), "temp upload must be deleted after use")
end)

test("openai transcription honours language, model override and keep", function()
  local path = temp_wav(400)
  local stt = { provider = "openai", model = "whisper-1", language = "de" }
  local cfg = config({ speech = { stt = stt } })
  local err, result = transcribe(cfg, { path = path, keep = true })
  assert(not err, err)
  equal(result.text, "openai:whisper-1:844")
  assert(exists(path), "keep=true must preserve the upload")
  speech.remove(path)
  assert(not exists(path))
  contains(transcribe(cfg, { path = temp_wav(), language = "not a code" }), "invalid language")
end)

test("xai transcription: options precede file, duration decoded", function()
  local request = { path = temp_wav(800), provider = "xai", language = "en" }
  local err, result = transcribe(config(), request)
  assert(not err, err)
  equal(result, { text = "xai:1644", provider = "xai", duration = 1.25 })
  local cfg = config({ speech = { stt = { provider = "xai", model = "unsupported" } } })
  contains(transcribe(cfg, { path = temp_wav() }), "does not accept a model")
end)

test("user files outside the cache are never deleted", function()
  local path = write_file(vim.fn.tempname() .. ".wav", wav_data(100))
  local err, result = transcribe(config(), { path = path, provider = "openai" })
  assert(not err, err)
  equal(result.text, "openai:gpt-4o-mini-transcribe:244")
  assert(exists(path), "user file must survive")
  equal(speech.remove(path), false)
  os.remove(path)
end)

test("mime detection and unsupported types", function()
  local path = write_file(speech.temp_path("test", "webm"), string.rep("x", 100))
  local err, result = transcribe(config(), { path = path })
  assert(not err, err)
  equal(result.text, "openai:gpt-4o-mini-transcribe:100")
  path = write_file(speech.temp_dir() .. "/odd name.bin", string.rep("x", 100))
  contains(transcribe(config(), { path = path }), "unsupported audio mime")
  assert(not exists(path))
  contains(transcribe(config(), { path = speech.temp_dir() .. "/missing.wav" }), "does not exist")
end)

test("openai speech round trip writes mp3 to the cache", function()
  local err, result = speak(config(), { text = "Hello from Rose." })
  assert(not err, err)
  equal(result.provider, "openai")
  equal(result.model, "gpt-4o-mini-tts")
  equal(result.voice, "marin")
  equal(result.mime, "audio/mpeg")
  assert(result.path:sub(1, #speech.temp_dir()) == speech.temp_dir())
  local stat = assert(uv.fs_stat(result.path))
  equal(stat.size, result.bytes)
  equal(bit.band(stat.mode, 511), 384)
  local handle = assert(io.open(result.path, "rb"))
  local head = handle:read(3)
  handle:close()
  equal(head, "ID3")
  speech.remove(result.path)
  assert(not exists(result.path))
end)

test("xai speech round trip with wav format and voice override", function()
  local request = { text = "Hallo", provider = "xai", format = "wav", voice = "ara" }
  local err, result = speak(config(), request)
  assert(not err, err)
  equal(result.provider, "xai")
  equal(result.model, nil)
  equal(result.voice, "ara")
  equal(result.mime, "audio/wav")
  equal(result.path:match("%.wav$"), ".wav")
  local handle = assert(io.open(result.path, "rb"))
  equal(handle:read(4), "RIFF")
  handle:close()
  speech.remove(result.path)
  contains(speak(config(), { text = "x", provider = "xai", voice = "bad voice!" }), "invalid voice")
end)

test("piper speech is local wav regardless of the requested format", function()
  local cfg = with_piper(config({ providers = { enabled = false, allow_cloud = false } }))
  local err, result = speak(cfg, { text = "Local voice." })
  assert(not err, err)
  equal(result.provider, "piper")
  equal(result.mime, "audio/wav")
  assert(result.bytes > 44)
  speech.remove(result.path)
  cfg.speech.piper.cmd = { "rose-missing-piper-binary" }
  contains(speak(cfg, { text = "x" }), "piper executable not found")
end)

test("auto selection: local engine first, then the chat provider, else options", function()
  local err, result = transcribe(with_whisper(config()), { path = temp_wav(10) })
  assert(not err, err)
  equal(result.provider, "whisper")
  err, result = transcribe(config({ providers = { provider = "xai" } }), { path = temp_wav(10) })
  assert(not err, err)
  equal(result.provider, "xai")
  err = transcribe(config({ providers = { provider = "anthropic" } }), { path = temp_wav(10) })
  contains(err, "no speech provider selected (available: openai, xai)")
  err = speak(config({ providers = { provider = "ollama", allow_cloud = false } }), { text = "x" })
  contains(err, "none available")
  err = transcribe(config({ providers = { provider = "ollama" } }), { path = temp_wav(10) })
  contains(err, "available: openai, xai")
end)

test("unavailable providers return their reason instead of a request", function()
  local unavailable = {
    anthropic = "provider has no speech API",
    perplexity = "no speech API",
    nvidia = "self-hosted Speech NIM",
    ollama = "unknown speech provider",
  }
  for provider, reason in pairs(unavailable) do
    contains(transcribe(config(), { path = temp_wav(10), provider = provider }), reason)
    contains(speak(config(), { text = "x", provider = provider }), reason)
  end
end)

test("missing API key is an operating error and never a crash", function()
  vim.env.XAI_API_KEY = nil
  local err = transcribe(config(), { path = temp_wav(10), provider = "xai" })
  contains(err, "not set")
  vim.env.XAI_API_KEY = fake
end)

test("cancellation mid-request is delivered exactly once and leaves nothing behind", function()
  local slow = config(nil, "/slow")
  local before = #temp_files("speech-*")
  local count, message = 0, nil
  local token = speech.speak(slow, { text = "slow" }, function(e)
    count = count + 1
    message = e
  end)
  vim.defer_fn(function()
    token.cancel()
    token.cancel()
  end, 20)
  assert(vim.wait(1000, function()
    return count > 0
  end, 5))
  vim.wait(80, function()
    return false
  end, 5)
  equal(count, 1)
  equal(message, "cancelled")
  equal(#temp_files("speech-*"), before)
  equal(next(transport.active), nil)
  equal(next(speech.active), nil)
  local path = temp_wav(10)
  count = 0
  token = speech.transcribe(slow, { path = path }, function(e)
    count = count + 1
    message = e
  end)
  token.cancel()
  assert(vim.wait(1000, function()
    return count > 0
  end, 5))
  equal(message, "cancelled")
  assert(not exists(path))
end)

test("speech.stop cancels every active operation", function()
  local slow = config(nil, "/slow")
  local results = {}
  speech.speak(slow, { text = "one" }, function(e)
    results[#results + 1] = e
  end)
  speech.transcribe(slow, { path = temp_wav(10) }, function(e)
    results[#results + 1] = e
  end)
  vim.wait(50, function()
    return false
  end, 5)
  equal(speech.stop(), 2)
  assert(vim.wait(1000, function()
    return #results == 2
  end, 5))
  equal(results, { "cancelled", "cancelled" })
  equal(next(speech.active), nil)
end)

test("upload size limit is enforced before any process starts", function()
  local cfg = config({ speech = { max_audio_bytes = 1024 } })
  local original, spawned = vim.system, false
  vim.system = function(...)
    spawned = true
    return original(...)
  end
  local err = transcribe(cfg, { path = temp_wav(800) })
  vim.system = original
  contains(err, "exceeds speech.max_audio_bytes")
  equal(spawned, false)
end)

test("response size limit discards the partial audio file", function()
  local cfg = config({ speech = { max_audio_bytes = 4096 } }, "/large")
  local before = #temp_files("speech-*")
  local err = speak(cfg, { text = "big" })
  contains(err, "size limit")
  equal(#temp_files("speech-*"), before)
end)

test("text limits: speech.max_text_chars and provider limits", function()
  contains(speak(config(), { text = "   " }), "text is empty")
  local cfg = config({ speech = { max_text_chars = 8 } })
  contains(speak(cfg, { text = "nine char" }), "speech.max_text_chars")
  cfg = config({ speech = { max_text_chars = 20000 } })
  contains(speak(cfg, { text = string.rep("a", 5000), provider = "openai" }), "at most 4096")
  contains(speak(cfg, { text = string.rep("a", 15001), provider = "xai" }), "at most 15000")
end)

test("timeouts and HTTP errors are redacted operating errors", function()
  local cfg = config({ providers = { openai = { timeout = 100 } } }, "/slow")
  local err = transcribe(cfg, { path = temp_wav(10) })
  assert(err and not err:find(fake, 1, true), err)
  err = transcribe(config(nil, "/error"), { path = temp_wav(10) })
  contains(err, "HTTP status 401")
  assert(not err:find(fake, 1, true))
  err = transcribe(config(nil, "/badjson"), { path = temp_wav(10) })
  contains(err, "invalid speech provider JSON")
  err = speak(config(nil, "/error"), { text = "x" })
  contains(err, "HTTP status 401")
end)

test("curl sees ordered multipart config on stdin and never the key in argv", function()
  local original, stdin = vim.system, nil
  vim.system = function(argv, opts, cb)
    if argv[1] == "curl" then
      equal(argv, { "curl", "--disable", "--config", "-" })
      assert(opts.clear_env and opts.env.XAI_API_KEY == nil)
      stdin = opts.stdin
    end
    return original(argv, opts, cb)
  end
  local err = transcribe(config(), { path = temp_wav(10), provider = "xai", language = "fr" })
  vim.system = original
  assert(not err, err)
  local language_at = assert(stdin:find('form-string = "language=fr"', 1, true))
  local file_at = assert(stdin:find('form = "file=@', 1, true))
  assert(language_at < file_at, "option fields must precede the file")
  contains(stdin, ";type=audio/wav;filename=audio.wav")
  assert(not stdin:find("Content-Type: application/json", 1, true))
  contains(stdin, "Authorization: Bearer " .. fake)
end)

test("transport rejects malformed forms and mixed body/form", function()
  local lines, err = transport.form({}, 1024)
  assert(lines == nil and err)
  local relative = { { name = "a", value = "x" }, { name = "b", path = "rel", mime = "audio/wav" } }
  lines, err = transport.form(relative, 1024)
  contains(err, "absolute")
  lines, err = transport.form({
    { name = "f", path = temp_wav(10), mime = "audio/wav" },
    { name = "g", path = temp_wav(10), mime = "audio/wav" },
  }, 8192)
  contains(err, "exactly one file")
  lines, err = transport.form({ { name = "f", path = temp_wav(10), mime = "audio/wav" } }, 8)
  contains(err, "upload exceeds size limit")
  lines, err = transport.form({ { name = "@evil", value = "x" } }, 8)
  assert(lines == nil, "names must be simple tokens")
  contains(err, "simple token")
  lines = assert(transport.form({ { name = "prompt", value = "@/etc/passwd" } }, 8))
  equal(lines, { 'form-string = "prompt=@/etc/passwd"' })
  local status = await(function(cb)
    return transport.request({
      endpoint = base .. "/openai",
      credential_host = authority,
      allow_insecure_local = true,
      path = "/audio/transcriptions",
      body = "{}",
      form = { { name = "a", value = "b" } },
    }, cb)
  end)
  contains(status, "cannot combine")
end)

test("record: stop finalizes a WAV with duration and bytes", function()
  local started = uv.hrtime()
  local err, result, token = await(function(cb)
    local token = speech.record(config(), { max_seconds = 5 }, cb)
    vim.defer_fn(token.stop, 150)
    return token
  end)
  assert(not err, err)
  assert(result.bytes > 44, "recording must contain samples")
  assert(result.seconds >= 0.1 and result.seconds < 5, "duration must reflect the stop time")
  assert((uv.hrtime() - started) / 1e9 < 4, "stop must not wait for max_seconds")
  equal(result.path:match("%.wav$"), ".wav")
  assert(exists(result.path))
  speech.remove(result.path)
  token.stop()
end)

test("record: max_seconds bounds the capture", function()
  local err, result = await(function(cb)
    return speech.record(config(), { max_seconds = 1 }, cb)
  end, 4000)
  assert(not err, err)
  assert(result.seconds >= 1 and result.seconds < 3, "recording must stop near max_seconds")
  speech.remove(result.path)
  contains(
    await(function(cb)
      return speech.record(config(), { max_seconds = 0 }, cb)
    end),
    "between 1 and 600"
  )
  contains(
    await(function(cb)
      return speech.record(config({ speech = { enabled = false } }), {}, cb)
    end),
    "speech.enabled"
  )
end)

test("record: cancel discards the file; broken recorders report an error", function()
  local before = #temp_files("record-*")
  local err = await(function(cb)
    local token = speech.record(config(), { max_seconds = 5 }, cb)
    vim.defer_fn(token.cancel, 100)
    return token
  end)
  equal(err, "cancelled")
  vim.wait(200, function()
    return false
  end, 5)
  equal(#temp_files("record-*"), before)
  local broken = { python, fixture_script, "--recorder-broken" }
  local cfg = config({ speech = { record = { cmd = broken } } })
  contains(
    await(function(cb)
      return speech.record(cfg, {}, cb)
    end),
    "recorder produced no audio"
  )
  equal(#temp_files("record-*"), before)
  cfg = config({ speech = { record = { cmd = { "rose-missing-recorder" } } } })
  contains(
    await(function(cb)
      return speech.record(cfg, {}, cb)
    end),
    "record command not found"
  )
end)

test("play: fake player succeeds, missing files and slow players fail cleanly", function()
  local path = temp_wav(10)
  local err = await(function(cb)
    return speech.play(config(), path, cb)
  end)
  assert(not err, err)
  contains(
    await(function(cb)
      return speech.play(config(), speech.temp_dir() .. "/missing.wav", cb)
    end),
    "does not exist"
  )
  contains(
    await(function(cb)
      return speech.play(config(), speech.temp_dir() .. "/file.ogg", cb)
    end),
    ".wav and .mp3"
  )
  local cfg = config({ speech = { play = { cmd = { python, fixture_script, "--player-slow" } } } })
  err = await(function(cb)
    local token = speech.play(cfg, path, cb)
    vim.defer_fn(token.cancel, 50)
    return token
  end)
  equal(err, "cancelled")
  speech.remove(path)
end)

local notices = {}
vim.notify = function(message)
  notices[#notices + 1] = message
end

test("setup registers the four user commands", function()
  speech.setup(config())
  for _, name in ipairs({ "RoseDictate", "RoseSpeak", "RoseSpeechStop", "RoseSpeechStatus" }) do
    assert(vim.fn.exists(":" .. name) == 2, name .. " missing")
  end
  vim.cmd("RoseSpeechStatus")
  contains(notices[#notices], "stt openai     available")
  contains(notices[#notices], "tts piper      unavailable: speech.piper.cmd is not configured")
  contains(notices[#notices], "recording: false")
end)

test(":RoseDictate records, :RoseSpeechStop finishes, transcript lands at the cursor", function()
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "hello  world" })
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  vim.cmd("RoseDictate")
  contains(notices[#notices], "recording (max 5 s)")
  vim.wait(150, function()
    return false
  end, 5)
  vim.cmd("RoseSpeechStop")
  contains(notices[#notices], "finishing recording")
  assert(vim.wait(5000, function()
    return vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1] ~= "hello  world"
  end, 10))
  local line = vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1]
  assert(line:match("^hello openai:gpt%-4o%-mini%-transcribe:%d+ world$"), line)
  equal(#temp_files("record-*"), 0)
end)

test(":RoseDictate inside the chat buffer asks Rose instead of editing", function()
  local ui = require("rose.native.ui")
  local asked = nil
  package.loaded["rose"] = {
    ask = function(text)
      asked = text
    end,
  }
  local chat = ui.open()
  vim.api.nvim_set_current_win(ui.window)
  vim.cmd("RoseDictate")
  vim.wait(100, function()
    return false
  end, 5)
  vim.cmd("RoseSpeechStop")
  assert(vim.wait(5000, function()
    return asked ~= nil
  end, 10))
  contains(asked, "openai:gpt-4o-mini-transcribe:")
  equal(vim.api.nvim_buf_line_count(chat), 1)
  package.loaded["rose"] = nil
  ui.close()
end)

test(":RoseSpeak speaks a range, then the last response, and cleans up", function()
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "first line", "second line" })
  local before = #notices
  vim.cmd("1,2RoseSpeak")
  assert(vim.wait(5000, function()
    return require("rose.speech.commands").pending == nil and #notices > before
  end, 10))
  equal(notices[#notices], "synthesizing speech")
  equal(#temp_files("speech-*"), 0)
  local ui = require("rose.native.ui")
  ui.append("Ask", "The answer is forty-two.")
  vim.api.nvim_set_current_win(ui.window)
  vim.cmd("RoseSpeak")
  assert(vim.wait(5000, function()
    return require("rose.speech.commands").pending == nil
  end, 10))
  equal(#temp_files("speech-*"), 0)
  ui.close()
  vim.cmd("RoseSpeak")
  contains(notices[#notices], "no Rose response to speak")
  vim.cmd("RoseSpeechStop")
  contains(notices[#notices], "stopped 0 speech operation(s)")
end)

test("programmer errors assert instead of returning", function()
  assert(not pcall(speech.transcribe, config(), { path = "relative.wav" }, function() end))
  assert(not pcall(speech.speak, config(), { text = 42 }, function() end))
  assert(not pcall(speech.speak, config(), { text = "x", format = "ogg" }, function() end))
  assert(not pcall(speech.play, config(), "relative.mp3", function() end))
  assert(not pcall(speech.record, config(), {}, "not a function"))
  assert(not pcall(speech.temp_path, "Test", "wav"))
  assert(not pcall(speech.temp_path, "test", "exe"))
end)

speech.stop()
fixture:kill(9)
vim.env.OPENAI_API_KEY = nil
vim.env.XAI_API_KEY = nil
for _, path in ipairs(temp_files("test-*")) do
  os.remove(path)
end
print(string.format("Speech tests: %d passed, %d failed", passed, #failures))
if #failures > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
