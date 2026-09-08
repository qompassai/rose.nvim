-- Bounded HTTP/1.1 server for the local web UI, built on vim.uv TCP handles.
-- It serves exactly one page and a handful of JSON/audio routes, binds to the
-- loopback interface only, and requires a per-session bearer token on /api.
-- Every buffer, count and wait has an explicit limit; nothing here is a general
-- purpose web server and it must never become one (no directory serving).
local M = { state = nil }
local uv = vim.uv or vim.loop

M.defaults = {
  enabled = false,
  host = "127.0.0.1",
  port = 0,
  open = true,
  max_request_bytes = 16 * 1024 * 1024,
  max_clients = 8,
  idle_timeout_ms = 30000,
}

-- Fixed protocol limits. They are constants rather than configuration because
-- a browser never legitimately needs more, and a smaller surface is safer.
M.limits = {
  header_bytes_max = 8192,
  header_count_max = 64,
  request_target_bytes_max = 2048,
  query_params_max = 32,
  handler_timeout_ms = 3600000, -- ceiling; providers and Flow enforce tighter timeouts
  chat_messages_max = 64,
  flow_task_chars_max = 8192,
  speak_text_chars_max = 4096,
  audio_bytes_max = 25 * 1024 * 1024,
  multipart_parts_max = 8,
  token_bytes = 16,
  listen_backlog = 16,
}
assert(M.limits.header_bytes_max < M.defaults.max_request_bytes)
assert(M.limits.audio_bytes_max > M.limits.header_bytes_max)

local reasons = {
  [200] = "OK",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [408] = "Request Timeout",
  [411] = "Length Required",
  [413] = "Payload Too Large",
  [415] = "Unsupported Media Type",
  [431] = "Request Header Fields Too Large",
  [500] = "Internal Server Error",
  [502] = "Bad Gateway",
  [503] = "Service Unavailable",
  [504] = "Gateway Timeout",
}

local content_types = {
  html = "text/html; charset=utf-8",
  json = "application/json; charset=utf-8",
}

local audio_extensions = {
  ["audio/webm"] = "webm",
  ["audio/ogg"] = "ogg",
  ["audio/wav"] = "wav",
  ["audio/x-wav"] = "wav",
  ["audio/wave"] = "wav",
  ["audio/mpeg"] = "mp3",
  ["audio/mp3"] = "mp3",
  ["audio/mp4"] = "m4a",
  ["audio/x-m4a"] = "m4a",
  ["audio/flac"] = "flac",
  ["audio/aac"] = "aac",
}

local security_headers = table.concat({
  "Connection: close",
  "Cache-Control: no-store",
  "X-Content-Type-Options: nosniff",
  "Referrer-Policy: no-referrer",
  "X-Frame-Options: DENY",
  "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; "
    .. "style-src 'unsafe-inline'; connect-src 'self'; media-src blob:; img-src data:; "
    .. "base-uri 'none'; form-action 'none'",
}, "\r\n")

--- Loopback is the only acceptable bind address and peer address. "localhost"
--- is accepted as an alias but always resolved to IPv4 so the URL is unambiguous.
function M.loopback_address(host)
  assert(type(host) == "string", "host must be a string")
  if host == "localhost" then
    return "127.0.0.1"
  end
  if host == "::1" then
    return "::1"
  end
  if host:match("^127%.%d+%.%d+%.%d+$") then
    return host
  end
  return nil
end

function M.validate(section)
  assert(type(section) == "table", "webui must be a configuration table")
  assert(type(section.enabled) == "boolean", "webui.enabled must be a boolean")
  assert(type(section.open) == "boolean", "webui.open must be a boolean")
  assert(M.loopback_address(section.host) ~= nil, "webui.host must be a loopback address")
  local function integer(value, low, high, name)
    assert(type(value) == "number", name .. " must be a number")
    assert(value % 1 == 0, name .. " must be an integer")
    assert(value >= low, name .. " must be >= " .. low)
    assert(value <= high, name .. " must be <= " .. high)
  end
  integer(section.port, 0, 65535, "webui.port")
  integer(section.max_request_bytes, 4096, 256 * 1024 * 1024, "webui.max_request_bytes")
  integer(section.max_clients, 1, 64, "webui.max_clients")
  integer(section.idle_timeout_ms, 100, 600000, "webui.idle_timeout_ms")
  return section
end

local function random_token()
  local bytes = assert(uv.random(M.limits.token_bytes), "uv.random unavailable")
  assert(#bytes == M.limits.token_bytes)
  local hex = bytes:gsub(".", function(character)
    return string.format("%02x", character:byte())
  end)
  assert(#hex == M.limits.token_bytes * 2)
  return hex
end

local function response_bytes(status, content_type, body)
  assert(reasons[status], "unknown HTTP status " .. tostring(status))
  assert(type(content_type) == "string")
  assert(type(body) == "string")
  return table.concat({
    "HTTP/1.1 " .. status .. " " .. reasons[status],
    "Content-Type: " .. content_type,
    "Content-Length: " .. #body,
    security_headers,
    "",
    body,
  }, "\r\n")
end

local function client_close(state, client)
  if client.closed then
    return
  end
  client.closed = true
  if client.timer then
    client.timer:stop()
    client.timer:close()
    client.timer = nil
  end
  if client.token and type(client.token.cancel) == "function" then
    pcall(client.token.cancel)
    client.token = nil
  end
  if not client.handle:is_closing() then
    client.handle:close()
  end
  if state.clients[client] then
    state.clients[client] = nil
    state.client_count = state.client_count - 1
  end
  assert(state.client_count >= 0)
end

--- Send one complete response and close. Connection: close keeps the state
--- machine trivial: one request per TCP connection, no pipelining, no keep-alive.
local function respond(state, client, status, content_type, body)
  if client.closed then
    return
  end
  if client.responded then
    return
  end
  client.responded = true
  state.requests_served = state.requests_served + 1
  local data = response_bytes(status, content_type, body)
  client.handle:write(data, function()
    client_close(state, client)
  end)
end

local function respond_json(state, client, status, payload)
  assert(type(payload) == "table")
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then
    status, encoded = 500, '{"error":"response could not be encoded"}'
  end
  respond(state, client, status, content_types.json, encoded)
end

local function respond_error(state, client, status, message)
  assert(status >= 400)
  respond_json(state, client, status, { error = message, status = status })
end

local function parse_query(query)
  local params, count = {}, 0
  for pair in (query or ""):gmatch("[^&]+") do
    count = count + 1
    if count > M.limits.query_params_max then
      return nil, "too many query parameters"
    end
    local key, value = pair:match("^([^=]+)=?(.*)$")
    if key then
      params[key] = value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
      end)
    end
  end
  return params
end

--- Parse the request line and headers. Header names are lower-cased; any
--- control character, missing colon or over-limit count is a hard 400.
local function parse_request_head(head)
  assert(type(head) == "string")
  assert(#head <= M.limits.header_bytes_max)
  local lines, line_count = {}, 0
  for line in (head .. "\r\n"):gmatch("(.-)\r\n") do
    line_count = line_count + 1
    if line_count > M.limits.header_count_max + 1 then
      return nil, "too many header fields"
    end
    lines[line_count] = line
  end
  local method, target, version = (lines[1] or ""):match("^(%u+) (%S+) HTTP/(1%.[01])$")
  if not method then
    return nil, "malformed request line"
  end
  assert(version ~= nil)
  if #target > M.limits.request_target_bytes_max then
    return nil, "request target too long"
  end
  local request = { method = method, target = target, headers = {} }
  for index = 2, line_count do
    local name, value = lines[index]:match("^([%w%-]+):[ \t]*(.-)[ \t]*$")
    if not name then
      return nil, "malformed header field"
    end
    if value:find("%c") then
      return nil, "control character in header value"
    end
    name = name:lower()
    if request.headers[name] ~= nil then
      if name == "content-length" then
        return nil, "duplicate Content-Length"
      end
      value = request.headers[name] .. ", " .. value
    end
    request.headers[name] = value
  end
  request.path, request.query = target:match("^([^?#]*)%??([^#]*)")
  if request.path:sub(1, 1) ~= "/" then
    return nil, "request target must be an absolute path"
  end
  local params, query_error = parse_query(request.query)
  if not params then
    return nil, query_error
  end
  request.params = params
  return request
end

--- Decide how many body bytes to expect. Chunked bodies are refused because a
--- bounded server needs the size up front; browsers always send Content-Length.
local function body_length(request, max_request_bytes)
  if request.headers["transfer-encoding"] then
    return nil, 411, "chunked transfer encoding is not supported; send Content-Length"
  end
  local header = request.headers["content-length"]
  if header == nil then
    if request.method == "GET" or request.method == "HEAD" then
      return 0
    end
    return nil, 411, "Content-Length is required"
  end
  if not header:match("^%d+$") or #header > 15 then
    return nil, 400, "invalid Content-Length"
  end
  local length = tonumber(header)
  if length > max_request_bytes then
    return nil, 413, "request body exceeds webui.max_request_bytes"
  end
  if request.method == "GET" and length > 0 then
    return nil, 400, "GET must not carry a body"
  end
  return length
end

local function authorized(state, request)
  local header = request.headers["authorization"] or ""
  local bearer = header:match("^[Bb]earer%s+(%S+)$")
  if bearer == state.token then
    return true
  end
  if request.params.token == state.token then
    return true
  end
  return false
end

local function decode_json_object(body)
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok then
    return nil, "request body is not valid JSON"
  end
  if type(decoded) ~= "table" then
    return nil, "request body must be a JSON object"
  end
  return decoded
end

local function speech_module()
  local ok, speech = pcall(require, "rose.speech")
  if not ok then
    local reason = "rose.speech module not installed"
    if not tostring(speech):find("module 'rose.speech' not found", 1, true) then
      reason = "rose.speech failed to load"
    end
    return nil, reason
  end
  if type(speech) ~= "table" then
    return nil, "rose.speech did not return a module table"
  end
  return speech
end

local function speech_state(fullconfig)
  local speech, reason = speech_module()
  if not speech then
    return { available = false, reason = reason }
  end
  if type(speech.capabilities) ~= "function" then
    return { available = false, reason = "rose.speech.capabilities missing" }
  end
  local ok, capabilities = pcall(speech.capabilities, fullconfig)
  if not ok then
    return { available = false, reason = "rose.speech.capabilities failed" }
  end
  local section = fullconfig.speech or {}
  return { available = true, enabled = section.enabled == true, capabilities = capabilities }
end

local function flow_backend(fullconfig)
  local rose = package.loaded["rose"]
  if type(rose) == "table" and rose.did_setup and type(rose.flow) == "function" then
    return function(task, callback)
      return rose.flow(task, callback)
    end
  end
  local flow = package.loaded["rose.native.flow"]
  if type(flow) == "table" and type(flow.config) == "table" and type(flow.call) == "function" then
    return function(task, callback)
      return flow.call("flow_run", { task = task }, callback)
    end
  end
  assert(fullconfig ~= nil)
  return nil, "Flow integration unavailable: require('rose').setup() has not configured it"
end

local function flow_state(fullconfig)
  local backend, reason = flow_backend(fullconfig)
  local flow = package.loaded["rose.native.flow"]
  local bridge = package.loaded["rose.native.bridge"]
  local command = type(fullconfig.flow) == "table" and fullconfig.flow.cmd or nil
  local executable = type(command) == "table" and type(command[1]) == "string" and command[1]
  local result = {
    available = backend ~= nil,
    reason = reason,
    cmd = executable or vim.NIL,
    executable = executable and vim.fn.executable(executable) == 1 or false,
    connected = flow ~= nil and flow.client ~= nil and flow.client.ready == true or false,
    bridge = bridge ~= nil and bridge.socket ~= nil,
  }
  if flow and flow.bridge_error then
    result.bridge_error = flow.bridge_error
  end
  return result
end

local function provider_state(fullconfig)
  local ok, model = pcall(require, "rose.native.model")
  if not ok or type(model.describe) ~= "function" then
    return { provider = "unknown", model = vim.NIL, cloud = false }
  end
  local described, info = pcall(model.describe, fullconfig)
  if not described or type(info) ~= "table" then
    return { provider = "unknown", model = vim.NIL, cloud = false }
  end
  return { provider = info.provider, model = info.model or vim.NIL, cloud = info.cloud == true }
end

local function route_page(state, client)
  respond(state, client, 200, content_types.html, state.page)
end

local function route_health(state, client)
  respond_json(state, client, 200, {
    ok = true,
    clients = state.client_count,
    requests_served = state.requests_served,
    uptime_ms = uv.now() - state.started_at,
  })
end

local function route_state(state, client)
  local config = state.config
  respond_json(state, client, 200, {
    config = {
      host = state.host,
      port = state.port,
      max_request_bytes = config.max_request_bytes,
      max_clients = config.max_clients,
      idle_timeout_ms = config.idle_timeout_ms,
    },
    limits = M.limits,
    provider = provider_state(state.fullconfig),
    flow = flow_state(state.fullconfig),
    speech = speech_state(state.fullconfig),
  })
end

local function validate_messages(messages)
  if type(messages) ~= "table" then
    return nil, "messages must be an array"
  end
  if #messages == 0 then
    return nil, "messages must not be empty"
  end
  if #messages > M.limits.chat_messages_max then
    return nil, "messages exceed chat_messages_max"
  end
  local clean = {}
  for index = 1, #messages do
    local message = messages[index]
    if type(message) ~= "table" then
      return nil, "each message must be an object"
    end
    local role, content = message.role, message.content
    if role ~= "user" and role ~= "assistant" and role ~= "system" then
      return nil, "message role must be user, assistant or system"
    end
    if type(content) ~= "string" then
      return nil, "message content must be a string"
    end
    clean[index] = { role = role, content = content }
  end
  return clean
end

local function route_chat(state, client, _, body)
  local payload, decode_error = decode_json_object(body)
  if not payload then
    respond_error(state, client, 400, decode_error)
    return
  end
  local messages, message_error = validate_messages(payload.messages)
  if not messages then
    respond_error(state, client, 400, message_error)
    return
  end
  local ok, model = pcall(require, "rose.native.model")
  if not ok or type(model.chat) ~= "function" then
    respond_error(state, client, 503, "model router unavailable")
    return
  end
  client.token = model.chat(state.fullconfig, messages, nil, function(err, message)
    client.token = nil
    if err then
      respond_error(state, client, 502, tostring(err))
      return
    end
    if type(message) ~= "table" or type(message.content) ~= "string" then
      respond_error(state, client, 502, "model returned no chat text")
      return
    end
    respond_json(state, client, 200, {
      message = { role = "assistant", content = message.content },
      provider = provider_state(state.fullconfig),
    })
  end)
end

local function route_flow_run(state, client, _, body)
  local payload, decode_error = decode_json_object(body)
  if not payload then
    respond_error(state, client, 400, decode_error)
    return
  end
  local task = payload.task
  if type(task) ~= "string" or task:match("^%s*$") then
    respond_error(state, client, 400, "task must be a non-empty string")
    return
  end
  if #task > M.limits.flow_task_chars_max then
    respond_error(state, client, 413, "task exceeds flow_task_chars_max")
    return
  end
  local backend, reason = flow_backend(state.fullconfig)
  if not backend then
    respond_error(state, client, 503, reason)
    return
  end
  client.token = backend(task, function(err, report)
    client.token = nil
    if err then
      respond_json(state, client, 502, { error = tostring(err), status = 502, report = report })
      return
    end
    if type(report) ~= "table" then
      report = { status = "ok", result = report }
    end
    respond_json(state, client, 200, report)
  end)
end

--- Extract the first file part from a multipart body. The scan is bounded by
--- multipart_parts_max and never copies more than the body itself.
local function multipart_file(body, boundary)
  assert(type(body) == "string")
  assert(type(boundary) == "string")
  if boundary == "" or #boundary > 200 then
    return nil, "invalid multipart boundary"
  end
  local delimiter = "--" .. boundary
  local position = 1
  for _ = 1, M.limits.multipart_parts_max do
    local start_at, start_end = body:find(delimiter, position, true)
    if not start_at then
      return nil, "multipart boundary not found"
    end
    if body:sub(start_end + 1, start_end + 2) == "--" then
      return nil, "multipart body has no file part"
    end
    local head_start = start_end + 3
    local head_at, head_end = body:find("\r\n\r\n", head_start, true)
    if not head_at then
      return nil, "multipart part headers incomplete"
    end
    local next_at = body:find("\r\n" .. delimiter, head_end + 1, true)
    if not next_at then
      return nil, "multipart part body unterminated"
    end
    local part_head = body:sub(head_start, head_at - 1)
    local disposition = part_head:match("[Cc]ontent%-[Dd]isposition:%s*([^\r\n]+)") or ""
    if disposition:find("filename=", 1, true) or disposition:find('name="file"', 1, true) then
      local mime = part_head:match("[Cc]ontent%-[Tt]ype:%s*([^\r\n;%s]+)")
      return body:sub(head_end + 1, next_at - 1), (mime or "application/octet-stream"):lower()
    end
    position = next_at + 2
  end
  return nil, "multipart part limit exceeded"
end

local function audio_directory()
  local directory = vim.fn.stdpath("cache") .. "/rose/webui"
  vim.fn.mkdir(directory, "p")
  return directory
end

local function write_temp_audio(bytes, extension)
  assert(#bytes <= M.limits.audio_bytes_max)
  assert(extension:match("^%l+$"))
  local name = string.format("%s-%d.%s", random_token(), uv.hrtime(), extension)
  local path = audio_directory() .. "/" .. name
  local descriptor, open_error = uv.fs_open(path, "w", 384) -- 0600: audio may be private speech
  if not descriptor then
    return nil, "cannot create temporary audio file: " .. tostring(open_error)
  end
  local written, write_error = uv.fs_write(descriptor, bytes, 0)
  uv.fs_close(descriptor)
  if written ~= #bytes then
    uv.fs_unlink(path)
    return nil, "cannot write temporary audio file: " .. tostring(write_error)
  end
  return path
end

local function read_file_bounded(path, bytes_max)
  local stat = uv.fs_stat(path)
  if not stat then
    return nil, "audio file missing"
  end
  if stat.size > bytes_max then
    return nil, "audio file exceeds audio_bytes_max"
  end
  local descriptor = uv.fs_open(path, "r", 256)
  if not descriptor then
    return nil, "cannot open audio file"
  end
  local data = uv.fs_read(descriptor, stat.size, 0)
  uv.fs_close(descriptor)
  if type(data) ~= "string" or #data ~= stat.size then
    return nil, "short read of audio file"
  end
  return data
end

local function route_speech_transcribe(state, client, request, body)
  local speech, reason = speech_module()
  if not speech or type(speech.transcribe) ~= "function" then
    respond_error(state, client, 503, reason or "rose.speech.transcribe missing")
    return
  end
  local content_type = (request.headers["content-type"] or ""):lower()
  local audio, mime = body, content_type:match("^([^;%s]+)")
  if content_type:find("^multipart/form%-data") then
    local boundary = request.headers["content-type"]:match('boundary="?([^";]+)"?')
    audio, mime = multipart_file(body, boundary or "")
    if not audio then
      respond_error(state, client, 400, mime)
      return
    end
  end
  local extension = audio_extensions[mime or ""]
  if not extension then
    respond_error(state, client, 415, "unsupported audio Content-Type: " .. tostring(mime))
    return
  end
  if #audio == 0 then
    respond_error(state, client, 400, "audio body is empty")
    return
  end
  if #audio > M.limits.audio_bytes_max then
    respond_error(state, client, 413, "audio exceeds audio_bytes_max")
    return
  end
  local path, write_error = write_temp_audio(audio, extension)
  if not path then
    respond_error(state, client, 500, write_error)
    return
  end
  local options = {
    path = path,
    mime = mime,
    provider = request.params.provider,
    language = request.params.language,
  }
  client.token = speech.transcribe(state.fullconfig, options, function(err, result)
    client.token = nil
    uv.fs_unlink(path)
    if err then
      respond_error(state, client, 502, tostring(err))
      return
    end
    if type(result) ~= "table" or type(result.text) ~= "string" then
      respond_error(state, client, 502, "speech module returned no text")
      return
    end
    respond_json(state, client, 200, result)
  end)
end

local function route_speech_speak(state, client, _, body)
  local speech, reason = speech_module()
  if not speech or type(speech.speak) ~= "function" then
    respond_error(state, client, 503, reason or "rose.speech.speak missing")
    return
  end
  local payload, decode_error = decode_json_object(body)
  if not payload then
    respond_error(state, client, 400, decode_error)
    return
  end
  local text = payload.text
  if type(text) ~= "string" or text:match("^%s*$") then
    respond_error(state, client, 400, "text must be a non-empty string")
    return
  end
  if #text > M.limits.speak_text_chars_max then
    respond_error(state, client, 413, "text exceeds speak_text_chars_max")
    return
  end
  local options = { text = text, format = payload.format or "mp3", keep = true }
  if type(payload.provider) == "string" then
    options.provider = payload.provider
  end
  if type(payload.voice) == "string" then
    options.voice = payload.voice
  end
  client.token = speech.speak(state.fullconfig, options, function(err, result)
    client.token = nil
    if err then
      respond_error(state, client, 502, tostring(err))
      return
    end
    if type(result) ~= "table" or type(result.path) ~= "string" then
      respond_error(state, client, 502, "speech module returned no audio path")
      return
    end
    local audio, read_error = read_file_bounded(result.path, M.limits.audio_bytes_max)
    uv.fs_unlink(result.path)
    if not audio then
      respond_error(state, client, 502, read_error)
      return
    end
    local mime = type(result.mime) == "string" and result.mime or "application/octet-stream"
    respond(state, client, 200, mime, audio)
  end)
end

local routes = {
  ["GET /"] = route_page,
  ["GET /api/health"] = route_health,
  ["GET /api/state"] = route_state,
  ["POST /api/chat"] = route_chat,
  ["POST /api/flow/run"] = route_flow_run,
  ["POST /api/speech/transcribe"] = route_speech_transcribe,
  ["POST /api/speech/speak"] = route_speech_speak,
}
local known_paths = {}
for key in pairs(routes) do
  known_paths[key:match("^%u+ (.+)$")] = true
end

--- Runs on the main loop (vim.schedule) because route handlers call vim.fn,
--- vim.system and provider code that is not allowed in libuv fast callbacks.
local function dispatch(state, client, request, body)
  if client.closed then
    return
  end
  if M.state ~= state then
    return -- The server stopped while this request was queued.
  end
  if request.path:sub(1, 5) == "/api/" then
    if not authorized(state, request) then
      respond_error(state, client, 401, "missing or invalid session token")
      return
    end
  end
  local handler = routes[request.method .. " " .. request.path]
  if not handler then
    if known_paths[request.path] then
      respond_error(state, client, 405, "method not allowed for " .. request.path)
    else
      respond_error(state, client, 404, "no such route")
    end
    return
  end
  local ok, err = pcall(handler, state, client, request, body)
  if not ok then
    -- Never leak Lua tracebacks to the browser; the message is enough to debug.
    respond_error(state, client, 500, "handler failed: " .. tostring(err):sub(1, 200))
  end
end

local function client_arm_timer(state, client, timeout_ms, status, message)
  assert(client.timer ~= nil)
  assert(timeout_ms > 0)
  client.timer:stop()
  client.timer:start(timeout_ms, 0, function()
    if client.responded then
      client_close(state, client)
      return
    end
    respond_error(state, client, status, message)
  end)
end

--- Accumulate bytes until the head and the declared body have fully arrived,
--- then hand the request to the main loop exactly once.
local function client_on_data(state, client, chunk)
  assert(type(chunk) == "string")
  if client.dispatched then
    return -- Trailing bytes after a complete request are ignored (Connection: close).
  end
  client.bytes = client.bytes + #chunk
  client.chunks[#client.chunks + 1] = chunk
  if client.request == nil then
    local text = table.concat(client.chunks)
    client.chunks = { text }
    local head_at, head_end = text:find("\r\n\r\n", 1, true)
    if not head_at then
      if client.bytes > M.limits.header_bytes_max then
        respond_error(state, client, 431, "request head exceeds header_bytes_max")
      end
      return
    end
    if head_at - 1 > M.limits.header_bytes_max then
      respond_error(state, client, 431, "request head exceeds header_bytes_max")
      return
    end
    local request, parse_error = parse_request_head(text:sub(1, head_at - 1))
    if not request then
      respond_error(state, client, 400, parse_error)
      return
    end
    local length, status, length_error = body_length(request, state.config.max_request_bytes)
    if not length then
      respond_error(state, client, status, length_error)
      return
    end
    local remaining = text:sub(head_end + 1)
    client.request, client.body_expected = request, length
    client.chunks, client.bytes = { remaining }, #remaining
  end
  if client.bytes >= client.body_expected then
    local body = table.concat(client.chunks):sub(1, client.body_expected)
    assert(#body == client.body_expected)
    client.chunks, client.dispatched = {}, true
    client_arm_timer(state, client, M.limits.handler_timeout_ms, 504, "handler timeout")
    vim.schedule(function()
      dispatch(state, client, client.request, body)
    end)
  end
end

local function server_on_connection(state, accept_error)
  if accept_error then
    return
  end
  if M.state ~= state then
    return
  end
  local handle = uv.new_tcp()
  local accepted = state.server:accept(handle)
  if not accepted then
    handle:close()
    return
  end
  local peer = handle:getpeername()
  if not peer or M.loopback_address(peer.ip) == nil then
    handle:close() -- Only loopback peers; the bind already guarantees this.
    return
  end
  if state.client_count >= state.config.max_clients then
    local refusal = '{"error":"too many clients","status":503}'
    local body = response_bytes(503, content_types.json, refusal)
    handle:write(body, function()
      handle:close()
    end)
    return
  end
  local client = {
    handle = handle,
    chunks = {},
    bytes = 0,
    timer = uv.new_timer(),
    dispatched = false,
    responded = false,
    closed = false,
  }
  state.clients[client] = true
  state.client_count = state.client_count + 1
  assert(state.client_count <= state.config.max_clients)
  client_arm_timer(state, client, state.config.idle_timeout_ms, 408, "idle timeout")
  handle:read_start(function(read_error, chunk)
    if read_error or chunk == nil then
      client_close(state, client)
      return
    end
    client_on_data(state, client, chunk)
  end)
end

--- Start listening. Idempotent: a running server is returned unchanged.
--- Returns state or nil, error. Bind failures are operating errors, not bugs.
function M.start(fullconfig)
  assert(type(fullconfig) == "table", "start requires the full Rose configuration")
  if M.state then
    return M.state
  end
  local config = M.validate(fullconfig.webui or M.defaults)
  local host = M.loopback_address(config.host)
  assert(host ~= nil)
  local page = require("rose.webui.page").html()
  local server = uv.new_tcp()
  local bound, bind_error = server:bind(host, config.port)
  if not bound then
    server:close()
    return nil, "cannot bind " .. host .. ":" .. config.port .. ": " .. tostring(bind_error)
  end
  local state = {
    server = server,
    host = host,
    token = random_token(),
    config = config,
    fullconfig = fullconfig,
    page = page,
    clients = {},
    client_count = 0,
    requests_served = 0,
    started_at = uv.now(),
  }
  local listening, listen_error = server:listen(M.limits.listen_backlog, function(accept_error)
    server_on_connection(state, accept_error)
  end)
  if not listening then
    server:close()
    return nil, "cannot listen on " .. host .. ": " .. tostring(listen_error)
  end
  local address = server:getsockname()
  assert(address ~= nil)
  assert(M.loopback_address(address.ip) ~= nil)
  state.port = address.port
  assert(state.port > 0)
  M.state = state
  return state
end

function M.url()
  if not M.state then
    return nil
  end
  local host = M.state.host
  if host:find(":", 1, true) then
    host = "[" .. host .. "]"
  end
  return string.format("http://%s:%d/?token=%s", host, M.state.port, M.state.token)
end

function M.status()
  local state = M.state
  if not state then
    return { running = false }
  end
  return {
    running = true,
    host = state.host,
    port = state.port,
    url = M.url(),
    clients = state.client_count,
    requests_served = state.requests_served,
  }
end

--- Stop listening and close every client handle, cancelling pending work.
function M.stop()
  local state = M.state
  if not state then
    return
  end
  M.state = nil
  local clients = {}
  for client in pairs(state.clients) do
    clients[#clients + 1] = client
  end
  for _, client in ipairs(clients) do
    client_close(state, client)
  end
  assert(state.client_count == 0)
  if not state.server:is_closing() then
    state.server:close()
  end
end

return M
