-- Bounded asynchronous HTTP. Never invoke a shell or read credentials.
local M = { active = {} }
local uv = vim.uv or vim.loop

local function net_api()
  local ok, net = pcall(require, "vim.net")
  return ok and type(net) == "table" and type(net.request) == "function" and net or nil
end

function M.capabilities()
  local net = net_api()
  return {
    native_request = net ~= nil,
    system = type(vim.system) == "function",
    curl = vim.fn.executable("curl") == 1,
    -- Current nightly vim.net follows redirects and reads curlrc, with no switches
    -- to disable either. auto must use the safe adapter until that changes.
    native_safe_options = false,
  }
end

local url_bytes_max = 8192
local tls_path_bytes_max = 4096
local tls_fields = { ca_file = true, cert_file = true, key_file = true }
local transports = { auto = true, curl = true, native = true }

-- Paths only: no inline PEM, PKCS#11 URI or curl certificate:password syntax.
-- Do not probe files here: validation/setup/health must never read credentials.
function M.validate_tls(tls)
  if tls == nil then
    return nil
  end
  if type(tls) ~= "table" then
    return "rose.tls must be a table of certificate file paths"
  end
  for field, path in pairs(tls) do
    if not tls_fields[field] then
      return "unknown rose.tls field; only ca_file, cert_file and key_file are supported"
    end
    if type(path) ~= "string" or #path == 0 or #path > tls_path_bytes_max or path:find("[%c]") then
      return "rose.tls."
        .. field
        .. " must be a nonempty path of at most 4096 bytes without controls"
    end
    if path:sub(1, 1) ~= "/" or path:find(":", 1, true) then
      return "rose.tls."
        .. field
        .. " must be an absolute POSIX file path without embedded passwords"
    end
  end
  if (tls.cert_file == nil) ~= (tls.key_file == nil) then
    return "Rose TLS requires paired cert_file and key_file"
  end
end

local function endpoint(url)
  if type(url) ~= "string" or #url > url_bytes_max or url:find("[%s%c\\?#]") then
    return "invalid HTTP URL"
  end
  local scheme, authority = url:match("^(https?)://([^/]+)")
  if not scheme or not authority or authority:find("@", 1, true) then
    return "HTTP URL must use http(s), without userinfo, query or fragment in its authority"
  end
  local host, port = authority:match("^%[([%x:%.]+)%]:(%d+)$")
  if not host then
    host = authority:match("^%[([%x:%.]+)%]$")
  end
  if not host then
    host, port = authority:match("^([%w%.%-]+):(%d+)$")
    host = host or authority:match("^([%w%.%-]+)$")
  end
  local port_number = port and tonumber(port)
  if not host or (port and (not port_number or port_number < 1 or port_number > 65535)) then
    return "invalid HTTP host"
  end
  host = host:lower()
  return nil, scheme, host
end

-- Pure policy validation, shared by setup/health and the actual request boundary.
function M.validate(opts)
  local invalid, scheme, host = endpoint(opts.url)
  if invalid then
    return invalid
  end
  local provider = opts.provider or "ollama"
  if provider ~= "rose" and provider ~= "ollama" then
    return "unknown local HTTP provider"
  end
  -- Rose plaintext is literal-loopback only: never trust DNS, even for localhost.
  local loopback = host == "127.0.0.1"
    or host == "::1"
    or (provider == "ollama" and host == "localhost")
  if opts.allow_remote ~= nil and type(opts.allow_remote) ~= "boolean" then
    return provider .. ".allow_remote must be a boolean"
  end
  if provider == "rose" and not loopback and scheme ~= "https" then
    return "remote Rose requires HTTPS; plaintext HTTP is never allowed"
  end
  if not loopback and opts.allow_remote ~= true then
    return "remote "
      .. provider
      .. " requires "
      .. provider
      .. ".allow_remote=true; no implicit cloud requests"
  end
  local tls_error = M.validate_tls(opts.tls)
  if tls_error then
    return tls_error
  end
  local has_tls = opts.tls ~= nil and next(opts.tls) ~= nil
  local secure_rose = provider == "rose" and scheme == "https"
  local transport = opts.transport or "auto"
  if not transports[transport] then
    return "unknown HTTP transport: " .. tostring(transport)
  end
  if transport == "native" and (has_tls or provider == "rose") then
    return "native transport cannot enforce Rose endpoint/TLS policy; use auto or curl"
  end
  if has_tls and (provider ~= "rose" or scheme ~= "https") then
    return "TLS options require a Rose HTTPS endpoint"
  end
  if secure_rose and not (opts.tls and opts.tls.cert_file and opts.tls.key_file) then
    return "Rose HTTPS requires paired client cert_file and key_file"
  end
end

local response_bytes_max_default = 8 * 1024 * 1024
local stderr_bytes_max = 64 * 1024
local response_chunks_max = 4096
local status_suffix_bytes = 4 -- newline plus curl's three-digit HTTP status
local timeout_ms_default = 120000

local function secure_rose(opts)
  return opts.provider == "rose" and opts.url:match("^https://") ~= nil
end

local function curl_argv(opts, timeout_ms)
  local argv = {
    "curl",
    "--disable",
    "--silent",
    "--show-error",
    "--fail",
    "--proto",
    secure_rose(opts) and "=https" or "=http,https",
    "--globoff",
    "--max-redirs",
    "0",
    "--noproxy",
    "*",
    "--proxy",
    "",
    "--max-time",
    tostring(timeout_ms / 1000),
    "--request",
    opts.method or "POST",
    "--header",
    "Content-Type: application/json",
  }
  if secure_rose(opts) then
    vim.list_extend(argv, { "--tlsv1.3", "--tls-max", "1.3", "--curves", "X25519MLKEM768" })
    local tls = opts.tls
    assert(tls and tls.cert_file and tls.key_file, "Rose HTTPS TLS must be validated before launch")
    vim.list_extend(argv, { "--cert-type", "PEM", "--key-type", "PEM" })
    vim.list_extend(argv, { "--cert", tls.cert_file, "--key", tls.key_file })
    if tls.ca_file then
      vim.list_extend(argv, { "--cacert", tls.ca_file })
    end
  end
  if opts.body then
    vim.list_extend(argv, { "--data-binary", "@-" })
  end
  -- --write-out allows refusal of redirects instead of silently treating a 3xx
  -- body as success. --disable first ignores ~/.curlrc.
  vim.list_extend(argv, { "--write-out", "\n%{http_code}", "--url", opts.url })
  return argv
end

-- Interpret a finished curl process: exit code first, then the trailing status line.
local function curl_finish(res, finish)
  if res.code ~= 0 then
    finish("HTTP failed (" .. res.code .. "): " .. (res.stderr or ""))
    return
  end
  local body, code = (res.stdout or ""):match("^(.*)\n(%d%d%d)$")
  if not code or tonumber(code) < 200 or tonumber(code) >= 300 then
    finish("HTTP status " .. tostring(code) .. " (redirects are not followed)")
    return
  end
  finish(nil, body)
end

-- Start the process for the selected transport; returns pcall-style ok, handle_or_error.
local function native_start(opts, finish)
  -- Explicit native mode is for endpoints whose redirects and local curl
  -- configuration the user trusts. It uses the real 0.13 method-first API.
  local net = net_api()
  if not net then
    return false, nil, "vim.net.request unavailable; use auto or curl"
  end
  return pcall(net.request, opts.method or "POST", opts.url, {
    body = opts.body,
    retry = 0,
    headers = { ["Content-Type"] = "application/json" },
  }, function(err, response)
    if err then
      finish(err)
    elseif type(response) ~= "table" or type(response.body) ~= "string" then
      finish("HTTP returned no valid response body")
    else
      finish(nil, response.body)
    end
  end)
end

-- vim.system's implicit stdout/stderr buffering is unbounded. Own both streams,
-- stop on overflow/read failure, and discard late chunks after terminal failure.
local function curl_start(opts, timeout_ms, finish, terminate, completed)
  local argv = curl_argv(opts, timeout_ms)
  local output, errors = {}, {}
  local output_bytes, error_bytes, failed = 0, 0, false
  local output_max = (opts.max_response or response_bytes_max_default) + status_suffix_bytes
  local function collect(is_error, err, chunk)
    if failed or completed() then
      return
    end
    local chunks = is_error and errors or output
    local bytes = (is_error and error_bytes or output_bytes) + (chunk and #chunk or 0)
    local maximum = is_error and stderr_bytes_max or output_max
    if err or bytes > maximum or (chunk and #chunks >= response_chunks_max) then
      failed = true
      finish(
        err and ("HTTP stream read failed: " .. tostring(err)) or "HTTP output exceeds size limit"
      )
      terminate()
      return
    end
    if chunk then
      chunks[#chunks + 1] = chunk
    end
    if is_error then
      error_bytes = bytes
    else
      output_bytes = bytes
    end
  end
  -- Rose HTTPS uses only the system trust store or configured CA. Do not inherit
  -- proxy/CA overrides, SSLKEYLOGFILE or crypto-provider configuration from the editor.
  local system_opts = {
    stdin = opts.body,
    text = true,
    stdout = function(err, chunk)
      collect(false, err, chunk)
    end,
    stderr = function(err, chunk)
      collect(true, err, chunk)
    end,
  }
  if secure_rose(opts) then
    system_opts.clear_env = true
    system_opts.env = { PATH = vim.env.PATH or "/usr/bin:/bin", SystemRoot = vim.env.SystemRoot }
  end
  return pcall(vim.system, argv, system_opts, function(res)
    if failed or completed() then
      return
    end
    res.stdout, res.stderr = table.concat(output), table.concat(errors)
    curl_finish(res, finish)
  end)
end

function M.request(opts, callback)
  assert(type(opts) == "table", "http.request: opts must be a table")
  assert(type(callback) == "function", "http.request: callback must be a function")
  local handle, timer, done
  local token = {}
  local response_bytes_max = opts.max_response or response_bytes_max_default
  local function finish(err, body)
    if done then
      return
    end
    if body and #body > response_bytes_max then
      err, body = "HTTP response exceeds size limit", nil
    end
    done = true
    M.active[token] = nil
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    vim.schedule(function()
      callback(err, body)
    end)
  end
  local function terminate()
    local current = handle
    handle = nil
    if current and current.close then
      pcall(current.close, current)
    elseif current and current.kill then
      pcall(current.kill, current, 9)
    end
  end
  function token.cancel()
    if done then
      return
    end
    finish("cancelled")
    terminate()
  end
  M.active[token] = true
  local invalid = M.validate(opts)
  if invalid then
    finish(invalid)
    return token
  end
  if type(vim.system) ~= "function" or vim.fn.executable("curl") ~= 1 then
    finish("HTTP unavailable: vim.system (Neovim 0.10+) and curl are required")
    return token
  end
  local transport = opts.transport or "auto"
  local timeout_ms = opts.timeout or timeout_ms_default
  timer = uv.new_timer()
  if not timer then
    finish("could not create HTTP timeout timer")
    return token
  end
  timer:start(timeout_ms, 0, function()
    finish("HTTP timeout after " .. timeout_ms .. "ms")
    terminate()
  end)
  local ok, result, unavailable
  if transport == "native" then
    ok, result, unavailable = native_start(opts, finish)
  else
    ok, result = curl_start(opts, timeout_ms, finish, terminate, function()
      return done == true
    end)
  end
  if unavailable then
    finish(unavailable)
  elseif ok and result then
    handle = result
    if done then
      terminate()
    end
  else
    finish("HTTP start failed: " .. tostring(result))
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
