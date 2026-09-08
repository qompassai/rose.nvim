-- Run offline: nvim --headless -u NONE -l tests/webui.lua
-- Goal: exercise the local web UI server end to end over real loopback TCP
-- using tests/webui_client.py (standard library only). Provider, Flow and
-- speech backends are stubbed through package.loaded so no model, Flow process
-- or audio engine is contacted. Every limit is probed from the invalid side too.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local python = vim.env.ROSE_TEST_PYTHON or "python3"
local client_script = root .. "/tests/webui_client.py"
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

local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")
local server = require("rose.webui.server")
local webui = require("rose.webui")
local test_section = {
  enabled = true,
  host = "127.0.0.1",
  port = 0,
  open = false,
  max_request_bytes = 64 * 1024,
  max_clients = 3,
  idle_timeout_ms = 1500,
}
--- Make `require("rose.speech")` fail exactly as if the module were absent, so
--- the "not installed" path is tested whether or not the real module is present.
local function hide_speech()
  package.loaded["rose.speech"] = nil
  package.preload["rose.speech"] = function()
    error("module 'rose.speech' not found: hidden by tests/webui.lua", 0)
  end
end
--- Restore normal module resolution for rose.speech.
local function reveal_speech()
  package.loaded["rose.speech"] = nil
  package.preload["rose.speech"] = nil
end
hide_speech()

local function config(extra)
  return require("rose.config").resolve(
    vim.tbl_deep_extend("force", { workspace = workspace, webui = test_section }, extra or {})
  )
end

--- Run the Python client synchronously and decode its JSON report.
local function client(port, args, timeout_ms)
  local argv = { python, client_script, tostring(port) }
  vim.list_extend(argv, args)
  local done, result = false, nil
  vim.system(argv, { text = true }, function(completed)
    result, done = completed, true
  end)
  assert(
    vim.wait(timeout_ms or 15000, function()
      return done
    end, 5),
    "client deadline exceeded"
  )
  assert(result.code == 0, "client failed: " .. tostring(result.stderr))
  return vim.json.decode(result.stdout)
end
local function json_body(report)
  assert(report.headers["content-type"] == "application/json; charset=utf-8", vim.inspect(report))
  return vim.json.decode(report.body_text)
end
local function api(port, token, method, path, body, extra)
  local args = { "request", "--method", method, "--path", path }
  if token then
    vim.list_extend(args, { "--token", token })
  end
  if body then
    vim.list_extend(args, { "--body", body, "--content-type", "application/json" })
  end
  vim.list_extend(args, extra or {})
  return client(port, args)
end
local function raw(port, text)
  return client(port, { "raw", "--data-b64", vim.base64.encode(text), "--read-timeout", "3" })
end

test("validate rejects every out-of-range setting", function()
  local function rejects(overrides, pattern)
    local section = vim.tbl_extend("force", vim.deepcopy(server.defaults), overrides)
    local ok, err = pcall(server.validate, section)
    assert(not ok, "expected rejection for " .. vim.inspect(overrides))
    assert(tostring(err):find(pattern, 1, true), tostring(err))
  end
  rejects({ host = "0.0.0.0" }, "loopback")
  rejects({ host = "192.168.1.10" }, "loopback")
  rejects({ host = 12 }, "host must be a string")
  rejects({ port = 70000 }, "webui.port")
  rejects({ port = 1.5 }, "webui.port")
  rejects({ max_clients = 0 }, "webui.max_clients")
  rejects({ max_clients = 65 }, "webui.max_clients")
  rejects({ max_request_bytes = 1 }, "webui.max_request_bytes")
  rejects({ idle_timeout_ms = 10 }, "webui.idle_timeout_ms")
  rejects({ enabled = "yes" }, "webui.enabled")
  rejects({ open = 1 }, "webui.open")
  assert(server.validate(vim.deepcopy(server.defaults)) ~= nil)
  equal(server.loopback_address("localhost"), "127.0.0.1")
  equal(server.loopback_address("127.0.0.5"), "127.0.0.5")
  equal(server.loopback_address("::1"), "::1")
  equal(server.loopback_address("10.0.0.1"), nil)
end)

test("start refuses a non-loopback bind and never opens a socket", function()
  -- config.resolve already rejects non-loopback hosts, so bypass it to reach the server check.
  local unsafe = config()
  unsafe.webui = vim.tbl_extend("force", unsafe.webui, { host = "0.0.0.0" })
  local ok, err = pcall(server.start, unsafe)
  assert(not ok, "non-loopback host must be refused")
  assert(tostring(err):find("loopback", 1, true), tostring(err))
  equal(server.state, nil)
  equal(server.status(), { running = false })
end)

local fullconfig = config()
local state = assert(server.start(fullconfig))
local port, token = state.port, state.token

test("start binds loopback with a random port and per-session token", function()
  assert(port > 0 and port < 65536, "port out of range")
  equal(state.host, "127.0.0.1")
  assert(#token == 32, "token must be 16 random bytes as hex")
  assert(token:match("^%x+$"), "token must be hexadecimal")
  equal(server.url(), string.format("http://127.0.0.1:%d/?token=%s", port, token))
  assert(server.start(fullconfig) == state, "start must be idempotent")
  local status = server.status()
  equal(status.running, true)
  equal(status.port, port)
  equal(status.clients, 0)
  local address = state.server:getsockname()
  equal(address.ip, "127.0.0.1")
  equal(address.port, port)
end)

test("GET / serves the self-contained page with the contract palette", function()
  local report = api(port, nil, "GET", "/")
  equal(report.status, 200)
  equal(report.headers["content-type"], "text/html; charset=utf-8")
  equal(report.headers["connection"], "close")
  equal(report.headers["x-content-type-options"], "nosniff")
  assert(report.headers["content-security-policy"]:find("default-src 'none'", 1, true))
  equal(tonumber(report.headers["content-length"]), report.body_bytes)
  local page = report.body_text
  for name, colour in pairs(require("rose.webui.page").palette) do
    assert(page:find(colour, 1, true), "palette colour missing: " .. name .. " " .. colour)
  end
  assert(page:find("prefers-reduced-motion", 1, true), "reduced motion media query missing")
  assert(page:find('"Inter","Cantarell","Noto Sans",system-ui', 1, true), "system font stack")
  assert(page:find("font:16px", 1, true), "16px body text")
  for _, marker in ipairs({ 'id="dictate"', 'id="speak"', 'id="flow-run"', 'id="transcript"' }) do
    assert(page:find(marker, 1, true), "page element missing: " .. marker)
  end
  assert(not page:find("https://", 1, true), "page must not reference network assets")
  assert(not page:find("<link", 1, true), "page must not load external stylesheets")
end)

test("token is required on /api and accepted as bearer or query", function()
  equal(api(port, nil, "GET", "/api/health").status, 401)
  equal(api(port, "wrong-token", "GET", "/api/health").status, 401)
  local report = api(port, token, "GET", "/api/health")
  equal(report.status, 200)
  local health = json_body(report)
  equal(health.ok, true)
  assert(type(health.uptime_ms) == "number")
  equal(api(port, nil, "GET", "/api/health?token=" .. token).status, 200)
  equal(api(port, nil, "GET", "/api/health?token=" .. token:sub(2)).status, 401)
end)

test("GET /api/state reports config, provider, Flow and speech", function()
  local report = api(port, token, "GET", "/api/state")
  equal(report.status, 200)
  local data = json_body(report)
  equal(data.config.port, port)
  equal(data.config.max_clients, 3)
  equal(data.config.max_request_bytes, 64 * 1024)
  equal(data.provider.provider, "ollama")
  equal(data.provider.cloud, false)
  equal(data.flow.available, false)
  assert(data.flow.reason:find("Flow integration unavailable", 1, true), data.flow.reason)
  equal(data.speech.available, false)
  equal(data.speech.reason, "rose.speech module not installed")
  equal(data.limits.header_bytes_max, 8192)
end)

test("unknown routes and wrong methods are rejected", function()
  equal(api(port, token, "GET", "/api/nope").status, 404)
  equal(api(port, token, "GET", "/api/chat").status, 405)
  equal(api(port, token, "POST", "/", "{}").status, 405)
  equal(api(port, nil, "GET", "/../etc/passwd").status, 404)
  equal(api(port, nil, "GET", "/index.html").status, 404)
end)

test("oversized bodies are rejected with 413 before they are read", function()
  local report = api(port, token, "POST", "/api/chat", nil, {
    "--content-type",
    "application/json",
    "--content-length",
    tostring(64 * 1024 + 1),
  })
  equal(report.status, 413)
  assert(json_body(report).error:find("max_request_bytes", 1, true))
  equal(report.eof, true)
end)

test("chunked transfer encoding and missing Content-Length are rejected", function()
  local chunked = api(port, token, "POST", "/api/chat", '{"messages":[]}', { "--chunked" })
  equal(chunked.status, 411)
  assert(json_body(chunked).error:find("chunked", 1, true))
  local missing = api(port, token, "POST", "/api/chat", nil, { "--content-type", "text/plain" })
  equal(missing.status, 411)
  local invalid = api(port, token, "POST", "/api/chat", nil, { "--content-length", "12abc" })
  equal(invalid.status, 400)
end)

test("malformed request lines and headers are rejected", function()
  equal(raw(port, "GARBAGE\r\n\r\n").status, 400)
  equal(raw(port, "GET / HTTP/2.0\r\n\r\n").status, 400)
  equal(raw(port, "GET / HTTP/1.1\r\nno-colon-here\r\n\r\n").status, 400)
  equal(raw(port, "GET / HTTP/1.1\r\nHost: a\rb\r\n\r\n").status, 400)
  equal(raw(port, "GET / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n").status, 400)
  equal(raw(port, "GET relative HTTP/1.1\r\n\r\n").status, 400)
  local many = { "GET / HTTP/1.1" }
  for index = 1, 65 do
    many[#many + 1] = "X-H" .. index .. ": v"
  end
  equal(raw(port, table.concat(many, "\r\n") .. "\r\n\r\n").status, 400)
  local huge = "GET / HTTP/1.1\r\nX-Big: " .. string.rep("a", 9000) .. "\r\n\r\n"
  equal(raw(port, huge).status, 431)
  equal(raw(port, "GET / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello").status, 400)
end)

test("client limit answers 503 once max_clients connections are held", function()
  local report = client(port, {
    "hold",
    "--count",
    "3",
    "--hold-ms",
    "200",
    "--path",
    "/api/health",
    "--token",
    token,
  })
  equal(report.opened, 3)
  equal(report.probe.status, 503)
  equal(vim.json.decode(report.probe.body_text).error, "too many clients")
  assert(
    vim.wait(2000, function()
      return server.status().clients == 0
    end, 10),
    "held clients were not released"
  )
end)

test("idle connections are closed with 408 after idle_timeout_ms", function()
  local report = client(port, { "idle", "--wait-ms", "4000" })
  equal(report.status, 408)
  equal(report.eof, true)
  assert(report.elapsed_ms >= 1400, "closed too early: " .. report.elapsed_ms)
  assert(report.elapsed_ms < 3500, "closed too late: " .. report.elapsed_ms)
end)

test("POST /api/chat routes messages through the stubbed model router", function()
  local seen
  package.loaded["rose.native.model"] = {
    describe = function()
      return { provider = "stub", model = "echo-1", cloud = false }
    end,
    chat = function(_, messages, tools, callback)
      seen = { messages = messages, tools = tools }
      vim.schedule(function()
        if messages[#messages].content == "fail" then
          callback("stub provider exploded")
          return
        end
        callback(nil, { role = "assistant", content = "echo: " .. messages[#messages].content })
      end)
      return { cancel = function() end }
    end,
  }
  local body = vim.json.encode({ messages = { { role = "user", content = "hello" } } })
  local report = api(port, token, "POST", "/api/chat", body)
  equal(report.status, 200)
  local reply = json_body(report)
  equal(reply.message, { role = "assistant", content = "echo: hello" })
  equal(reply.provider.provider, "stub")
  equal(seen.messages, { { role = "user", content = "hello" } })
  equal(seen.tools, nil)
  local failure = vim.json.encode({ messages = { { role = "user", content = "fail" } } })
  equal(api(port, token, "POST", "/api/chat", failure).status, 502)
  equal(api(port, token, "POST", "/api/chat", "not json").status, 400)
  equal(api(port, token, "POST", "/api/chat", '{"messages":[]}').status, 400)
  local bad_role = vim.json.encode({ messages = { { role = "tool", content = "x" } } })
  equal(api(port, token, "POST", "/api/chat", bad_role).status, 400)
  local too_many = {}
  for index = 1, 65 do
    too_many[index] = { role = "user", content = "m" .. index }
  end
  equal(api(port, token, "POST", "/api/chat", vim.json.encode({ messages = too_many })).status, 400)
  equal(api(port, nil, "POST", "/api/chat", body).status, 401)
  package.loaded["rose.native.model"] = nil
end)

test("POST /api/flow/run uses the Flow integration when configured", function()
  local body = vim.json.encode({ task = "add tests" })
  local unavailable = api(port, token, "POST", "/api/flow/run", body)
  equal(unavailable.status, 503)
  local calls = {}
  package.loaded["rose.native.flow"] = {
    config = fullconfig,
    call = function(name, args, callback)
      calls[#calls + 1] = { name = name, args = args }
      vim.schedule(function()
        callback(nil, { status = "ok", task = args.task, verified = true })
      end)
      return { cancel = function() end }
    end,
  }
  local report = api(port, token, "POST", "/api/flow/run", body)
  equal(report.status, 200)
  equal(json_body(report).task, "add tests")
  equal(calls, { { name = "flow_run", args = { task = "add tests" } } })
  equal(json_body(api(port, token, "GET", "/api/state")).flow.available, true)
  equal(api(port, token, "POST", "/api/flow/run", '{"task":"  "}').status, 400)
  local long_task = vim.json.encode({ task = string.rep("x", 8193) })
  equal(api(port, token, "POST", "/api/flow/run", long_task).status, 413)
  package.loaded["rose.native.flow"] = nil
end)

local function stub_speech()
  local stub = { transcribe_calls = {}, speak_calls = {}, speak_paths = {} }
  package.loaded["rose.speech"] = {
    capabilities = function()
      return {
        stt = { { provider = "whisper", available = true } },
        tts = { { provider = "piper", available = true, voice = "amy" } },
      }
    end,
    transcribe = function(_, options, callback)
      local descriptor = assert(vim.uv.fs_open(options.path, "r", 256))
      local size = vim.uv.fs_fstat(descriptor).size
      local content = vim.uv.fs_read(descriptor, size, 0)
      vim.uv.fs_close(descriptor)
      stub.transcribe_calls[#stub.transcribe_calls + 1] = options
      vim.schedule(function()
        callback(nil, { text = "heard:" .. content, provider = "whisper", mime = options.mime })
      end)
      return { cancel = function() end }
    end,
    speak = function(_, options, callback)
      stub.speak_calls[#stub.speak_calls + 1] = options
      local path = vim.fn.tempname() .. ".wav"
      stub.speak_paths[#stub.speak_paths + 1] = path
      vim.fn.writefile({ "RIFF-fake-" .. options.text }, path, "b")
      vim.schedule(function()
        callback(nil, { path = path, mime = "audio/wav", bytes = 0, provider = "piper" })
      end)
      return { cancel = function() end }
    end,
  }
  return stub
end

test("speech routes proxy audio to the stubbed rose.speech module", function()
  local stub = stub_speech()
  local data = json_body(api(port, token, "GET", "/api/state"))
  equal(data.speech.available, true)
  equal(data.speech.capabilities.stt[1].provider, "whisper")
  local audio_path = vim.fn.tempname()
  vim.fn.writefile({ "wavbytes" }, audio_path, "b")
  local report = api(port, token, "POST", "/api/speech/transcribe?provider=whisper", nil, {
    "--body-file",
    audio_path,
    "--content-type",
    "audio/wav",
  })
  equal(report.status, 200)
  equal(json_body(report).text, "heard:wavbytes")
  equal(stub.transcribe_calls[1].mime, "audio/wav")
  equal(stub.transcribe_calls[1].provider, "whisper")
  assert(stub.transcribe_calls[1].path:find("/rose/webui/", 1, true), "temp file under cache")
  equal(vim.uv.fs_stat(stub.transcribe_calls[1].path), nil)
  local boundary = "----RoseBoundary"
  local multipart = table.concat({
    "--" .. boundary,
    'Content-Disposition: form-data; name="model"',
    "",
    "whisper-1",
    "--" .. boundary,
    'Content-Disposition: form-data; name="file"; filename="clip.webm"',
    "Content-Type: audio/webm",
    "",
    "webmbytes",
    "--" .. boundary .. "--",
    "",
  }, "\r\n")
  local multipart_path = vim.fn.tempname()
  vim.fn.writefile(vim.split(multipart, "\n", { plain = true }), multipart_path, "b")
  local part = api(port, token, "POST", "/api/speech/transcribe", nil, {
    "--body-file",
    multipart_path,
    "--content-type",
    "multipart/form-data; boundary=" .. boundary,
  })
  equal(part.status, 200)
  equal(json_body(part).text, "heard:webmbytes")
  equal(stub.transcribe_calls[2].mime, "audio/webm")
  local unsupported = api(port, token, "POST", "/api/speech/transcribe", nil, {
    "--body-file",
    audio_path,
    "--content-type",
    "text/plain",
  })
  equal(unsupported.status, 415)
  local speak = api(port, token, "POST", "/api/speech/speak", '{"text":"hi","voice":"amy"}')
  equal(speak.status, 200)
  equal(speak.headers["content-type"], "audio/wav")
  equal(speak.body_text, "RIFF-fake-hi")
  equal(speak.body_bytes, 12)
  equal(stub.speak_calls[1].voice, "amy")
  equal(stub.speak_calls[1].format, "mp3")
  equal(vim.uv.fs_stat(stub.speak_paths[1]), nil) -- Audio is deleted after it is served.
  equal(api(port, token, "POST", "/api/speech/speak", '{"text":""}').status, 400)
  local long_text = vim.json.encode({ text = string.rep("a", 4097) })
  equal(api(port, token, "POST", "/api/speech/speak", long_text).status, 413)
  hide_speech()
  equal(api(port, token, "POST", "/api/speech/speak", '{"text":"x"}').status, 503)
  equal(
    api(port, token, "POST", "/api/speech/transcribe", nil, {
      "--body",
      "wav",
      "--content-type",
      "audio/wav",
    }).status,
    503
  )
end)

test("real rose.speech module, when installed, is discovered and reports capabilities", function()
  reveal_speech()
  local ok, speech = pcall(require, "rose.speech")
  if not ok then
    hide_speech()
    print("  (rose.speech not present in this checkout; discovery test skipped)")
    return
  end
  equal(type(speech.capabilities), "function")
  local data = json_body(api(port, token, "GET", "/api/state"))
  equal(data.speech.available, true)
  equal(data.speech.enabled, false) -- No speech section in the test config.
  equal(type(data.speech.capabilities.stt), "table")
  equal(type(data.speech.capabilities.tts), "table")
  assert(#data.speech.capabilities.stt >= 1, "expected at least one stt engine entry")
  assert(#data.speech.capabilities.tts >= 1, "expected at least one tts engine entry")
  for _, kind in ipairs({ "stt", "tts" }) do
    for _, entry in ipairs(data.speech.capabilities[kind]) do
      equal(type(entry.provider), "string")
      equal(type(entry.available), "boolean")
    end
  end
  hide_speech()
end)

test("stop closes held client sockets and the listener", function()
  local done, result = false, nil
  vim.system(
    { python, client_script, tostring(port), "hold", "--count", "2", "--hold-ms", "8000" },
    { text = true },
    function(completed)
      result, done = completed, true
    end
  )
  assert(
    vim.wait(3000, function()
      return server.status().clients == 2
    end, 10),
    "held connections were not accepted"
  )
  server.stop()
  equal(server.state, nil)
  equal(server.status(), { running = false })
  assert(
    vim.wait(4000, function()
      return done
    end, 10),
    "hold client did not observe EOF"
  )
  local report = vim.json.decode(result.stdout)
  equal(report.eof_count, 2)
  assert(report.elapsed_ms < 6000, "clients were not closed promptly")
  local probe = { python, client_script, tostring(port), "idle", "--wait-ms", "200" }
  local refused = vim.system(probe):wait()
  assert(refused.code ~= 0, "listener still accepting after stop")
  server.stop() -- Idempotent.
end)

test("restart issues a fresh token on a fresh socket", function()
  local restarted = assert(server.start(fullconfig))
  assert(restarted ~= state, "restart must create new state")
  assert(restarted.token ~= token, "token must be regenerated per session")
  equal(api(restarted.port, restarted.token, "GET", "/api/health").status, 200)
  equal(api(restarted.port, token, "GET", "/api/health").status, 401)
  server.stop()
end)

test("rose.webui setup registers commands and honours the enabled gate", function()
  local original_open, opened = vim.ui.open, {}
  vim.ui.open = function(url)
    opened[#opened + 1] = url
    return nil, nil
  end
  webui.setup(config({ webui = { enabled = false } }))
  for _, name in ipairs({ "RoseWebUI", "RoseWebUIStop", "RoseWebUIStatus" }) do
    assert(vim.fn.exists(":" .. name) == 2, name .. " not registered")
  end
  local url, err = webui.start()
  equal(url, nil)
  assert(err:find("webui.enabled", 1, true), err)
  webui.setup(config({ webui = { enabled = true, open = true } }))
  url = assert(webui.start())
  assert(url:find("^http://127%.0%.0%.1:%d+/%?token=%x+$"), url)
  equal(opened, { url })
  equal(webui.start(), url) -- Idempotent, and no second browser tab.
  equal(#opened, 1)
  equal(webui.status().running, true)
  vim.cmd("RoseWebUIStop")
  equal(webui.status().running, false)
  webui.shutdown()
  equal(vim.fn.exists(":RoseWebUI"), 0)
  vim.ui.open = original_open
end)

test("unwired configuration falls back to the documented defaults", function()
  -- config.resolve now ships the same defaults; a bare table must still resolve to them.
  local resolved = require("rose.config").resolve({ workspace = workspace })
  equal(resolved.webui, server.defaults)
  local fallback = vim.tbl_extend("force", resolved, { webui = nil })
  fallback.webui = nil
  equal(fallback.webui, nil)
  equal(webui.section(fallback), server.defaults)
  webui.setup(fallback)
  local url, err = webui.start()
  equal(url, nil)
  assert(err:find("disabled", 1, true), err)
  webui.shutdown()
end)

vim.fn.delete(workspace, "rf")
print(string.format("%d passed, %d failed", passed, #failures))
for _, failure in ipairs(failures) do
  print(failure)
end
os.exit(#failures == 0 and 0 or 1)
