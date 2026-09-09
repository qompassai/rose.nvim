-- Lazy, explicit cloud-provider registry. Requiring/validating never reads keys.
local C = require("rose.providers.common")
local T = require("rose.providers.transport")
local M = {}
local names = { openai = true, anthropic = true, xai = true, nvidia = true, perplexity = true }
local header_names = {
  ["anthropic-version"] = "anthropic",
  ["anthropic-beta"] = "anthropic",
  ["anthropic-workspace-id"] = "anthropic",
  ["openai-organization"] = "openai",
  ["openai-project"] = "openai",
  ["x-grok-conv-id"] = "xai",
}

local function integer(value, lo, hi, name)
  assert(
    type(value) == "number" and value % 1 == 0 and value >= lo and value <= hi,
    name .. " is outside the supported integer range"
  )
end

-- Anthropic ships no descriptor module of its own; its single Messages API is declared here.
local anthropic_descriptor = {
  host = "api.anthropic.com",
  key_env = "ANTHROPIC_API_KEY",
  apis = { messages = { path = "/messages", format = "anthropic", tools = true } },
}

local provider_fields = {
  api = true,
  endpoint = true,
  model = true,
  key_env = true,
  options = true,
  capabilities = true,
  credential_host = true,
  allow_insecure_local = true,
  auth = true,
  headers = true,
  timeout = true,
  max_request_bytes = true,
  max_response_bytes = true,
  max_event_bytes = true,
}

local header_value_bytes_max = 4096

-- Pin the credential host to the endpoint so a key can never be sent to another origin.
local function resolve_endpoint(config, descriptor, name)
  local endpoint, err = T.endpoint(config.endpoint)
  assert(endpoint, err)
  if config.credential_host ~= nil then
    assert(
      config.credential_host == endpoint.authority,
      "credential_host must exactly match endpoint host[:port]"
    )
  else
    assert(
      endpoint.authority == descriptor.host,
      "custom provider endpoints require explicit credential_host=host[:port]"
    )
    config.credential_host = descriptor.host
  end
  assert(
    config.allow_insecure_local == nil or type(config.allow_insecure_local) == "boolean",
    "allow_insecure_local must be a boolean"
  )
  assert(
    endpoint.scheme == "https" or (endpoint.loopback and config.allow_insecure_local == true),
    "provider endpoint requires HTTPS; HTTP is permitted only for explicitly allowed loopback "
      .. "NIM/fixtures"
  )
  assert(config.auth == nil or type(config.auth) == "boolean", "provider auth must be a boolean")
  assert(
    config.auth ~= false or (name == "nvidia" and endpoint.loopback),
    "auth=false is supported only for explicitly configured loopback NVIDIA NIM"
  )
  config.name, config.endpoint = name, endpoint.base
end

local function resolve_headers(config, name)
  assert(type(config.headers) == "table", "provider headers must be a table")
  for key, value in pairs(config.headers) do
    assert(
      type(key) == "string" and header_names[key:lower()] == name,
      "unsupported provider header; routing, authentication and cookies cannot be overridden"
    )
    assert(type(value) == "string", "invalid provider header value")
    assert(#value <= header_value_bytes_max, "invalid provider header value")
    assert(not value:find("[%c]"), "invalid provider header value")
  end
end

local function resolve_limits(config)
  config.timeout = config.timeout or 120000
  config.max_request_bytes = config.max_request_bytes or 4 * 1024 * 1024
  config.max_response_bytes = config.max_response_bytes or 8 * 1024 * 1024
  config.max_event_bytes = config.max_event_bytes
    or math.min(1024 * 1024, config.max_response_bytes)
  integer(config.timeout, 1, 3600000, "provider timeout")
  integer(config.max_request_bytes, 256, 64 * 1024 * 1024, "provider max_request_bytes")
  integer(config.max_response_bytes, 256, 64 * 1024 * 1024, "provider max_response_bytes")
  integer(config.max_event_bytes, 128, config.max_response_bytes, "provider max_event_bytes")
end

function M.resolve(fullconfig)
  assert(type(fullconfig) == "table", "providers.resolve: fullconfig must be a table")
  local providers = fullconfig.providers
  assert(type(providers) == "table", "providers configuration is required")
  assert(
    providers.provider ~= "rose" and providers.provider ~= "ollama",
    "local Rose/Ollama uses rose.native.model, not the cloud provider registry"
  )
  assert(
    providers.enabled == true and providers.allow_cloud == true,
    "cloud providers require providers.enabled=true AND providers.allow_cloud=true; task, "
      .. "source and tool output leave your device"
  )
  local name = providers.provider
  assert(names[name], "unknown cloud provider")
  local descriptor = anthropic_descriptor
  if name ~= "anthropic" then
    descriptor = require("rose.providers." .. name)
  end
  local config = C.copy(providers[name])
  C.fields(config, provider_fields, "provider configuration")
  assert(
    type(config.api) == "string" and descriptor.apis[config.api],
    "provider api must be explicitly selected from its documented supported APIs"
  )
  assert(
    type(config.model) == "string" and config.model:match("%S") and not config.model:find("[%c]"),
    "provider model must be explicitly configured"
  )
  resolve_endpoint(config, descriptor, name)
  config.key_env = config.key_env or descriptor.key_env
  assert(
    type(config.key_env) == "string" and config.key_env:match("^[A-Z_][A-Z0-9_]*$"),
    "key_env must name an environment variable; inline keys are not accepted"
  )
  config.options, config.headers, config.capabilities =
    config.options or {}, config.headers or {}, config.capabilities or {}
  assert(type(config.options) == "table", "provider options must be a table")
  C.fields(config.capabilities, { tools = true }, "model capability")
  assert(
    config.capabilities.tools == nil or type(config.capabilities.tools) == "boolean",
    "capabilities.tools must be a boolean"
  )
  assert(
    descriptor.apis[config.api].tools or not config.capabilities.tools,
    "Sonar does not provide Rose custom tools; choose Perplexity api=agent"
  )
  resolve_headers(config, name)
  resolve_limits(config)
  assert(config.credential_host ~= nil, "resolved provider must pin a credential host")
  return config, descriptor.apis[config.api]
end

local function rejected(callback, message)
  local cancelled = false
  vim.schedule(function()
    callback(cancelled and "cancelled" or message)
  end)
  return {
    cancel = function()
      cancelled = true
    end,
  }
end

-- This boundary withholds payload/response/exception details. Model-generated
-- content, tokens and source may occur in JSON parser errors or provider errors.
local function safe_error(err)
  local text = tostring(err):gsub("^.-:%d+:%s*", "")
  return text:match("^[^\r\n]+") or "provider request failed"
end

local api_key_bytes_max = 16384
local anthropic_version_default = "2023-06-01"

local function request_spec_valid(spec)
  return pcall(function()
    C.fields(
      spec,
      { path = true, method = true, body = true, stream = true, on_event = true },
      "JSON request"
    )
    assert(T.path(spec.path))
    assert(spec.stream == nil or type(spec.stream) == "boolean")
    assert(spec.on_event == nil or type(spec.on_event) == "function")
    assert(not spec.on_event or spec.stream == true)
    assert(spec.body == nil or type(spec.body) == "table")
    assert(
      not spec.stream or (type(spec.body) == "table" and spec.body.stream == true),
      "SSE requires stream=true in both request spec and JSON body"
    )
    assert(
      spec.stream == true or not (spec.body and spec.body.stream == true),
      "JSON body stream=true requires request spec stream=true"
    )
  end)
end

-- Returns the outgoing header table, or nil plus an operating error when the key is unusable.
local function request_headers(config)
  local headers = C.copy(config.headers)
  if config.name == "anthropic" then
    local version = false
    for key in pairs(headers) do
      if key:lower() == "anthropic-version" then
        version = true
      end
    end
    if not version then
      headers["anthropic-version"] = anthropic_version_default
    end
  end
  if config.auth ~= false then
    -- The only key read in the provider subsystem: explicit request time.
    local key = vim.env[config.key_env]
    if type(key) ~= "string" or key == "" then
      return nil, "provider API key environment variable is not set"
    end
    if #key > api_key_bytes_max or key:find("[%c]") then
      return nil, "invalid provider API key format"
    end
    if config.name == "anthropic" then
      headers["x-api-key"] = key
    else
      headers.Authorization = "Bearer " .. key
    end
  end
  return headers
end

local function response_decode(data, callback)
  if data == "" then
    callback(nil, {})
    return
  end
  local decoded, response = pcall(vim.json.decode, data)
  if not decoded or type(response) ~= "table" then
    callback("invalid provider JSON response")
    return
  end
  if C.present(response.error) or response.type == "error" then
    callback("provider returned an API error (response details withheld)")
    return
  end
  callback(nil, response)
end

function M.request(fullconfig, spec, callback)
  assert(type(callback) == "function", "providers.request: callback must be a function")
  local ok, config = pcall(M.resolve, fullconfig)
  if not ok then
    return rejected(callback, safe_error(config))
  end
  if not request_spec_valid(spec) then
    return rejected(
      callback,
      "invalid raw JSON request (check path, body, stream and callback options)"
    )
  end
  local headers, header_err = request_headers(config)
  if not headers then
    return rejected(callback, header_err)
  end
  local body
  if spec.body then
    local encoded, value = pcall(vim.json.encode, spec.body)
    if not encoded then
      return rejected(callback, "cannot encode provider JSON request")
    end
    body = value
  end
  local parser, cancelled = nil, false
  if spec.stream then
    parser = require("rose.providers.sse").new(function(event)
      if not cancelled and spec.on_event then
        spec.on_event(event)
      end
    end, config.max_event_bytes)
  end
  local child = T.request({
    endpoint = config.endpoint,
    credential_host = config.credential_host,
    path = spec.path,
    allow_insecure_local = config.allow_insecure_local,
    method = spec.method or "POST",
    headers = headers,
    body = body,
    timeout = config.timeout,
    max_request_bytes = config.max_request_bytes,
    max_response_bytes = config.max_response_bytes,
    on_chunk = parser and function(chunk)
      parser.feed(chunk)
      if parser.error() then
        error("invalid provider stream", 0)
      end
    end or nil,
  }, function(err, data)
    if err then
      cancelled = true
      callback(err)
    elseif parser then
      local result, parse_err = parser.finish()
      callback(parse_err, result)
    else
      response_decode(data, callback)
    end
  end)
  return {
    cancel = function()
      cancelled = true
      child.cancel()
    end,
  }
end

function M.chat(fullconfig, messages, tools, callback)
  local ok, config, api = pcall(M.resolve, fullconfig)
  if not ok then
    return rejected(callback, safe_error(config))
  end
  if tools and #tools > 0 and (not api.tools or config.capabilities.tools ~= true) then
    return rejected(
      callback,
      "this API/model has not enabled custom tools; explicitly set capabilities.tools=true on "
        .. "a supported model (Sonar is not supported)"
    )
  end
  local adapter = require("rose.providers." .. api.format)
  local encoded, payload = pcall(adapter.encode, config, messages, tools)
  if not encoded then
    return rejected(callback, safe_error(payload))
  end
  return M.request(fullconfig, { path = api.path, body = payload }, function(err, response)
    if err then
      callback(err)
      return
    end
    local decoded, message = pcall(adapter.decode, config, response)
    if not decoded then
      -- Decoder assertions are fixed messages; never expose native parser errors.
      callback(
        "invalid or unsupported "
          .. config.name
          .. " assistant response; use raw JSON request API for non-text/non-function features"
      )
      return
    end
    callback(nil, message)
  end)
end

M.stop = T.stop
return M
