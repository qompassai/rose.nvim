-- Authenticated cloud transport, intentionally separate from native Ollama HTTP.
-- Credentials AND request JSON travel only through an anonymous stdin pipe.
-- No shell, temporary request files, curlrc, proxy, redirects, or inherited secrets.
local M = { active = {} }
local uv = vim.uv or vim.loop

-- Escape one curl config value so quotes, backslashes and line breaks cannot end the entry.
local function quote(value)
  assert(type(value) == "string", "quote: value must be a string")
  local escaped = value:gsub("\\", "\\\\"):gsub('"', '\\"')
  escaped = escaped:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub("\v", "\\v")
  return '"' .. escaped .. '"'
end

function M.endpoint(url)
  if type(url) ~= "string" or url:find("[%s%c\\?#]") then
    return nil, "provider endpoint must be an HTTP(S) base URL without query, fragment or backslash"
  end
  local scheme, authority, path = url:match("^(https?)://([^/]+)(.*)$")
  if not scheme or authority:find("@", 1, true) then
    return nil, "invalid provider endpoint authority"
  end
  local host, port
  if authority:sub(1, 1) == "[" then
    host, port = authority:match("^(%[[%x:]+%])(:%d*)$")
    if not host then
      host = authority:match("^(%[[%x:]+%])$")
    end
  else
    host, port = authority:match("^([%w%.%-]+)(:%d+)$")
    if not host then
      host = authority:match("^([%w%.%-]+)$")
    end
  end
  local canonical = host ~= nil and authority:lower() == authority
  if canonical and port then
    -- port keeps its leading ":"; an empty or out-of-range number is rejected.
    local port_number = tonumber(port:sub(2))
    canonical = port_number ~= nil and port_number >= 1 and port_number <= 65535
  end
  if not canonical then
    return nil, "provider endpoint must use a canonical lowercase host and valid port"
  end
  if
    not path:match("^[%w%-%._/]*$")
    or path:find("//", 1, true)
    or ("/" .. path .. "/"):find("/%.%./")
    or ("/" .. path .. "/"):find("/%./")
  then
    return nil, "invalid provider endpoint base path"
  end
  return {
    scheme = scheme,
    authority = authority,
    host = host,
    base = url:gsub("/+$", ""),
    loopback = host == "127.0.0.1" or host == "localhost" or host == "[::1]",
  }
end

function M.path(path)
  if
    type(path) ~= "string"
    or path:sub(1, 1) ~= "/"
    or path:sub(1, 2) == "//"
    or path:find("[%s%c\\#]")
    or path:find("://", 1, true)
    or path:find("%%[^%x]")
    or path:find("%%[%x]$")
    or path:sub(-1) == "%"
  then
    return nil, "request.path must be a safe relative API path beginning with /"
  end
  local decoded = path:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  local route = decoded:match("^[^?]*")
  if
    decoded:find("[%c\\]")
    or route:find("//", 1, true)
    or route:find("%%", 1, true)
    or (route .. "/"):find("/%.%./")
    or (route .. "/"):find("/%./")
  then
    return nil, "unsafe provider API path"
  end
  return true
end

-- Multipart form upload (speech audio). Entries are ordered because some APIs
-- (xAI STT) parse option fields before the file part. Every value goes through
-- `form-string`, so a leading "@" or "<" can never make curl read a local file.
-- Only the single explicit `path` entry becomes a `form` file part.
local function form_file(entry, max_upload_bytes)
  assert(type(entry) == "table", "form file entry must be a table")
  assert(type(entry.name) == "string", "form file entry must be named")
  local path = entry.path
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find('[%c;,"\\]') then
    return nil, "multipart file path must be absolute without control or separator characters"
  end
  local filename = entry.filename or path:match("([^/]+)$")
  if type(filename) ~= "string" or not filename:match("^[%w%._%-]+$") then
    return nil, "multipart file name must be a simple file name"
  end
  if type(entry.mime) ~= "string" or not entry.mime:match("^[%w%-%+%.]+/[%w%-%+%.]+$") then
    return nil, "multipart file mime type must look like type/subtype"
  end
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, "multipart file does not exist"
  end
  if stat.size == 0 then
    return nil, "multipart file is empty"
  end
  if stat.size > max_upload_bytes then
    return nil, "provider upload exceeds size limit"
  end
  local part = entry.name .. "=@" .. path .. ";type=" .. entry.mime .. ";filename=" .. filename
  return "form = " .. quote(part)
end

function M.form(entries, max_upload_bytes)
  assert(type(entries) == "table", "form entries must be a list")
  assert(type(max_upload_bytes) == "number", "max_upload_bytes must be a number")
  assert(max_upload_bytes >= 1, "max_upload_bytes must be positive")
  if #entries == 0 or #entries > 32 then
    return nil, "multipart form must contain between 1 and 32 fields"
  end
  local lines, file_count = {}, 0
  for index = 1, #entries do
    local entry = entries[index]
    if type(entry) ~= "table" or type(entry.name) ~= "string" then
      return nil, "multipart form field must be a named table"
    end
    if not entry.name:match("^[%w_%-]+$") then
      return nil, "multipart form field name must be a simple token"
    end
    if entry.path ~= nil then
      file_count = file_count + 1
      if file_count > 1 then
        return nil, "multipart form supports exactly one file field"
      end
      local line, file_error = form_file(entry, max_upload_bytes)
      if not line then
        return nil, file_error
      end
      lines[#lines + 1] = line
    else
      if type(entry.value) ~= "string" or #entry.value > 16384 then
        return nil, "multipart form value must be a string of at most 16384 bytes"
      end
      lines[#lines + 1] = "form-string = " .. quote(entry.name .. "=" .. entry.value)
    end
  end
  assert(#lines == #entries, "every form entry must produce one curl line")
  return lines
end

-- Binary responses (speech audio) stream to a 0600 file instead of memory. The
-- body is written only for 2xx statuses and only up to max_output_bytes; on any
-- error or cancel the partial file is unlinked so no half-written audio remains.
local function open_sink(path, max_output_bytes)
  assert(type(path) == "string", "output path must be a string")
  assert(path:sub(1, 1) == "/", "output path must be absolute")
  assert(type(max_output_bytes) == "number", "max_output_bytes must be a number")
  assert(max_output_bytes >= 1, "max_output_bytes must be positive")
  local descriptor = uv.fs_open(path, "w", 384)
  if not descriptor then
    return nil, "could not create provider response file"
  end
  local sink, written = {}, 0
  function sink.write(data)
    assert(descriptor, "sink.write after close")
    if written + #data > max_output_bytes then
      return nil, "provider response exceeds size limit"
    end
    local wrote = uv.fs_write(descriptor, data, -1)
    if wrote ~= #data then
      return nil, "could not write provider response file"
    end
    written = written + #data
    return true
  end
  function sink.close()
    if descriptor then
      uv.fs_close(descriptor)
      descriptor = nil
    end
    return written
  end
  function sink.discard()
    sink.close()
    uv.fs_unlink(path)
  end
  return sink
end

-- Named limits and defaults for one request. Callers may lower the byte limits per request.
local request_methods = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true }
local response_bytes_max_default = 8 * 1024 * 1024
local request_bytes_max_default = 4 * 1024 * 1024
local upload_bytes_max_default = 25 * 1024 * 1024
local timeout_ms_default = 120000
local connect_timeout_seconds_max = 15
local header_block_bytes_max = 65536
local header_value_bytes_max = 16384
local headers_max = 64
-- Servers may send 1xx interim responses before the final status; bound how many we skip.
local interim_responses_max = 8

-- Validate the request shape before any process starts. Programmer errors (wrong types for
-- opts/callback) assert; every wire-facing problem is returned so the caller sees a reason.
-- Returns endpoint, form_lines (or nil) on success, or nil, nil, error.
local function request_prepare(opts)
  local endpoint, invalid = M.endpoint(opts.endpoint)
  local path_ok, path_err = M.path(opts.path)
  if not endpoint or not path_ok then
    return nil, nil, invalid or path_err
  end
  if endpoint.authority ~= opts.credential_host then
    return nil, nil, "provider credential host does not match endpoint"
  end
  local insecure_allowed = endpoint.loopback and opts.allow_insecure_local == true
  if endpoint.scheme ~= "https" and not insecure_allowed then
    return nil,
      nil,
      "provider transport requires HTTPS; only explicitly allowed loopback HTTP is supported"
  end
  if not request_methods[opts.method or "POST"] then
    return nil, nil, "unsupported JSON request method"
  end
  if type(vim.system) ~= "function" or vim.fn.executable("curl") ~= 1 then
    return nil, nil, "provider transport requires Neovim 0.10+ and curl"
  end
  local body = opts.body
  if body ~= nil then
    local request_bytes_max = opts.max_request_bytes or request_bytes_max_default
    if type(body) ~= "string" or #body > request_bytes_max then
      return nil, nil, "provider request exceeds size limit"
    end
    if opts.form then
      return nil, nil, "provider request cannot combine a JSON body with a multipart form"
    end
  end
  local form_lines = nil
  if opts.form then
    local form_error
    form_lines, form_error = M.form(opts.form, opts.max_upload_bytes or upload_bytes_max_default)
    if not form_lines then
      return nil, nil, form_error
    end
  end
  if opts.output_path and opts.on_chunk then
    return nil, nil, "provider request cannot combine a file output with a stream handler"
  end
  return endpoint, form_lines
end

local function header_valid(name, value)
  if type(name) ~= "string" or not name:match("^[%w%-]+$") then
    return false
  end
  if type(value) ~= "string" or value:find("[%c]") then
    return false
  end
  return #value <= header_value_bytes_max
end

-- Build the curl config text. Header values, body and URL never enter process argv.
-- Returns the config string, or nil plus an error for an invalid caller header.
local function request_curl_config(opts, endpoint, form_lines, timeout_ms)
  assert(type(endpoint) == "table", "request_curl_config: endpoint must be resolved")
  assert(timeout_ms >= 1, "request_curl_config: timeout_ms must be positive")
  local content_type = 'header = "Content-Type: application/json"'
  if form_lines then
    -- Multipart requests let curl compute the boundary Content-Type itself.
    content_type = 'header = "Accept: */*"'
  end
  local lines = {
    "silent",
    "show-error",
    "include",
    "no-buffer",
    'proto = "=http,https"',
    'proto-redir = "=https"',
    "max-redirs = 0",
    'proxy = ""',
    'noproxy = "*"',
    "retry = 0",
    "max-time = " .. tostring(timeout_ms / 1000),
    "connect-timeout = " .. tostring(math.min(timeout_ms / 1000, connect_timeout_seconds_max)),
    "request = " .. quote(opts.method or "POST"),
    "url = " .. quote(endpoint.base .. opts.path),
    content_type,
    'header = "Expect:"',
  }
  if form_lines then
    vim.list_extend(lines, form_lines)
  end
  if endpoint.host == "localhost" then
    local default_port = "80"
    if endpoint.scheme == "https" then
      default_port = "443"
    end
    local port = endpoint.authority:match(":(%d+)$") or default_port
    lines[#lines + 1] = "resolve = " .. quote("localhost:" .. port .. ":127.0.0.1")
  end
  local header_count = 0
  for name, value in pairs(opts.headers or {}) do
    header_count = header_count + 1
    if header_count > headers_max or not header_valid(name, value) then
      return nil, "invalid provider HTTP header"
    end
    lines[#lines + 1] = "header = " .. quote(name .. ": " .. value)
  end
  if opts.body then
    lines[#lines + 1] = "data-binary = " .. quote(opts.body)
  end
  return table.concat(lines, "\n") .. "\n"
end

-- Peel interim (1xx) and final header blocks off the buffered response. Returns the body
-- remainder once the final status line is known, nil while more header bytes are needed,
-- or nil plus an error when the header block is malformed or oversized.
local function response_consume_header(state, data)
  assert(not state.in_body, "response_consume_header: already in body")
  state.header = state.header .. data
  local interim_count = 0
  while not state.in_body do
    local a, b = state.header:find("\r\n\r\n", 1, true)
    if not a then
      a, b = state.header:find("\n\n", 1, true)
    end
    if not a then
      if #state.header > header_block_bytes_max then
        return nil, "provider HTTP headers exceed size limit"
      end
      return nil
    end
    local block = state.header:sub(1, a - 1)
    state.status = tonumber(block:match("^HTTP/%S+%s+(%d%d%d)"))
    if not state.status then
      return nil, "invalid provider HTTP response"
    end
    data, state.header = state.header:sub(b + 1), ""
    if state.status >= 100 and state.status < 200 then
      interim_count = interim_count + 1
      if interim_count > interim_responses_max then
        return nil, "invalid provider HTTP response"
      end
      state.header = data
    else
      state.in_body = true
    end
  end
  assert(state.status >= 200, "final status must not be interim")
  return data
end

-- Hand one body chunk to the stream handler, the file sink or the in-memory buffer.
-- Returns nil, error when the consumer failed; the caller aborts the request.
local function response_deliver(state, opts, data)
  if opts.on_chunk then
    local ok = pcall(opts.on_chunk, data)
    if not ok then
      return nil, "provider stream handler failed"
    end
  elseif state.sink then
    local written, write_error = state.sink.write(data)
    if not written then
      return nil, write_error
    end
  else
    state.parts[#state.parts + 1] = data
  end
  return true
end

-- Translate curl's exit code and the parsed status into the caller-facing result (err, body).
local function request_result(exit_code, state, opts)
  if exit_code ~= 0 then
    return "provider request failed (curl exit " .. tostring(exit_code) .. ")"
  end
  if not state.status or not state.in_body then
    return "invalid provider HTTP response"
  end
  if state.status < 200 or state.status >= 300 then
    -- Upstream error bodies are withheld because they may echo secrets or source text.
    local hint = " (response details withheld)"
    if state.status >= 300 and state.status < 400 then
      hint = " (redirects are not followed)"
    end
    return "provider HTTP status " .. state.status .. hint
  end
  if state.sink then
    return nil, opts.output_path
  end
  if opts.on_chunk then
    return nil, ""
  end
  return nil, table.concat(state.parts)
end

-- Complete exactly once: release the timer and sink, then deliver on the main loop.
local function request_finish(state, callback, err, body)
  if state.done then
    return
  end
  state.done = true
  M.active[state.token] = nil
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  local bytes = nil
  if state.sink then
    if err then
      state.sink.discard()
    else
      bytes = state.sink.close()
    end
  end
  local status = state.status
  vim.schedule(function()
    callback(err, body, { status = status, bytes = bytes })
  end)
end

local function request_terminate(state)
  if state.handle then
    pcall(state.handle.kill, state.handle, 9)
  end
end

-- Account one stdout chunk against the response limit and route it to its consumer.
-- Returns nil when the chunk was handled, or the error that must abort the request.
local function response_consume(state, opts, response_bytes_max, data)
  assert(type(data) == "string", "response_consume: data must be a string")
  state.count = state.count + #data
  if state.count > response_bytes_max then
    return "provider response exceeds size limit"
  end
  if not state.in_body then
    local remainder, header_error = response_consume_header(state, data)
    if remainder == nil then
      return header_error
    end
    data = remainder
  end
  if state.status < 200 or state.status >= 300 then
    return nil
  end
  local delivered, deliver_error = response_deliver(state, opts, data)
  if not delivered then
    return deliver_error
  end
  return nil
end

-- curl reads its whole config (URL, headers, credentials, body) from stdin, never argv.
-- stderr is deliberately discarded: an upstream error or URL might contain a secret.
local function request_spawn(config, on_stdout, on_exit)
  return pcall(vim.system, { "curl", "--disable", "--config", "-" }, {
    stdin = config,
    text = false,
    clear_env = true,
    env = { PATH = vim.env.PATH or "/usr/bin:/bin", LANG = "C" },
    stdout = on_stdout,
    stderr = function() end,
  }, on_exit)
end

function M.request(opts, callback)
  assert(type(opts) == "table", "transport.request: opts must be a table")
  assert(type(callback) == "function", "transport.request: callback must be a function")
  local token = {}
  local state = { token = token, done = false, count = 0, header = "", in_body = false, parts = {} }
  local response_bytes_max = opts.max_response_bytes or response_bytes_max_default
  local function finish(err, body)
    request_finish(state, callback, err, body)
  end
  local function fail(err)
    finish(err)
    request_terminate(state)
  end
  function token.cancel()
    if state.done then
      return
    end
    fail("cancelled")
  end
  M.active[token] = true
  local endpoint, form_lines, invalid = request_prepare(opts)
  if not endpoint then
    finish(invalid)
    return token
  end
  if opts.output_path then
    local sink_error
    state.sink, sink_error =
      open_sink(opts.output_path, opts.max_output_bytes or response_bytes_max)
    if not state.sink then
      finish(sink_error)
      return token
    end
  end
  local timeout_ms = opts.timeout or timeout_ms_default
  local config, config_error = request_curl_config(opts, endpoint, form_lines, timeout_ms)
  if not config then
    finish(config_error)
    return token
  end
  state.timer = uv.new_timer()
  if not state.timer then
    finish("could not create provider timeout timer")
    return token
  end
  state.timer:start(timeout_ms, 0, function()
    fail("provider request timeout")
  end)
  local ok, result = request_spawn(config, function(err, data)
    if state.done or (data == nil and not err) then
      return
    end
    local consume_error = err and "provider response read failed"
      or response_consume(state, opts, response_bytes_max, data)
    if consume_error then
      fail(consume_error)
    end
  end, function(res)
    if state.done then
      return
    end
    finish(request_result(res.code, state, opts))
  end)
  config = nil -- drop the only reference to credentials and body text
  if not ok then
    finish("could not start provider transport")
  else
    state.handle = result
  end
  return token
end

function M.stop()
  local tokens = {}
  for token in pairs(M.active) do
    tokens[#tokens + 1] = token
  end
  for _, token in ipairs(tokens) do
    token.cancel()
  end
end

return M
