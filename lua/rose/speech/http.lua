-- Speech HTTP on top of rose.providers.transport. Cloud endpoints reuse the
-- per-provider `providers.<name>` endpoint/credential settings so a key can
-- only ever travel to the host it was configured for. whisper.cpp is loopback
-- HTTP without credentials. Keys are read here, at request time, and nowhere
-- else in the speech subsystem.
local transport = require("rose.providers.transport")
local deliver = require("rose.speech.deliver")
local M = {}

M.descriptors = {
  openai = require("rose.speech.openai"),
  xai = require("rose.speech.xai"),
}

-- Providers Rose supports for chat but which have no HTTP speech API.
M.unavailable = {
  anthropic = "provider has no speech API",
  perplexity = "provider has no speech API (voice API is roadmap only)",
  nvidia = "NVIDIA speech requires a self-hosted Speech NIM; not implemented",
}

M.consent_message = "cloud speech requires speech.enabled, providers.enabled and "
  .. "providers.allow_cloud all set to true; audio and text leave your device"

local function integer(value, lo, hi, name)
  assert(type(value) == "number", name .. " must be a number")
  assert(value % 1 == 0, name .. " must be an integer")
  assert(value >= lo, name .. " is below the supported range")
  assert(value <= hi, name .. " is above the supported range")
end

-- Cloud consent is three explicit flags. Local engines need only speech.enabled.
function M.consent(fullconfig)
  assert(type(fullconfig) == "table", "fullconfig must be a table")
  local speech, providers = fullconfig.speech, fullconfig.providers
  if type(speech) ~= "table" or speech.enabled ~= true then
    return nil, "speech is disabled; set speech.enabled = true"
  end
  if type(providers) ~= "table" then
    return nil, M.consent_message
  end
  if providers.enabled ~= true then
    return nil, M.consent_message
  end
  if providers.allow_cloud ~= true then
    return nil, M.consent_message
  end
  return true
end

-- Resolves endpoint and credential binding for a cloud speech provider.
-- Configuration mistakes are programmer errors and assert; callers pcall.
function M.resolve_cloud(fullconfig, name)
  assert(type(fullconfig) == "table", "fullconfig must be a table")
  local descriptor = M.descriptors[name]
  assert(descriptor, "unknown cloud speech provider")
  local providers = fullconfig.providers or {}
  assert(type(providers) == "table", "providers configuration must be a table")
  local section = providers[name] or {}
  assert(type(section) == "table", "provider configuration must be a table")
  local endpoint, endpoint_error = transport.endpoint(section.endpoint or descriptor.endpoint)
  assert(endpoint, endpoint_error)
  local credential_host = section.credential_host
  if credential_host == nil then
    assert(
      endpoint.authority == descriptor.host,
      "custom provider endpoints require explicit credential_host=host[:port]"
    )
    credential_host = descriptor.host
  end
  assert(credential_host == endpoint.authority, "credential_host must exactly match endpoint")
  local allow_insecure_local = section.allow_insecure_local
  assert(
    allow_insecure_local == nil or type(allow_insecure_local) == "boolean",
    "allow_insecure_local must be a boolean"
  )
  if endpoint.scheme ~= "https" then
    assert(endpoint.loopback, "speech provider endpoint requires HTTPS")
    assert(allow_insecure_local == true, "loopback HTTP requires allow_insecure_local=true")
  end
  local key_env = section.key_env or descriptor.key_env
  assert(type(key_env) == "string", "key_env must name an environment variable")
  assert(key_env:match("^[A-Z_][A-Z0-9_]*$"), "key_env must be an environment variable name")
  local timeout = section.timeout or 120000
  integer(timeout, 1, 3600000, "provider timeout")
  return {
    name = name,
    endpoint = endpoint.base,
    credential_host = credential_host,
    allow_insecure_local = allow_insecure_local,
    auth = true,
    key_env = key_env,
    timeout = timeout,
  }
end

-- whisper.cpp runs locally; only loopback HTTP is accepted so recordings never
-- leave the machine even if a URL is mistyped.
function M.resolve_whisper(speech)
  assert(type(speech) == "table", "speech configuration must be a table")
  assert(type(speech.whisper) == "table", "speech.whisper must be a table")
  local url = speech.whisper.url
  assert(type(url) == "string", "speech.whisper.url must be a string")
  local endpoint, endpoint_error = transport.endpoint(url)
  assert(endpoint, endpoint_error)
  assert(endpoint.loopback, "speech.whisper.url must be a loopback address")
  assert(endpoint.scheme == "http", "speech.whisper.url must use plain loopback http")
  local timeout = speech.whisper.timeout or 120000
  integer(timeout, 1, 3600000, "whisper timeout")
  return {
    name = "whisper",
    endpoint = endpoint.base,
    credential_host = endpoint.authority,
    allow_insecure_local = true,
    auth = false,
    key_env = nil,
    timeout = timeout,
  }
end

local function authorization(config)
  assert(type(config.key_env) == "string", "authenticated requests need key_env")
  -- The only key read in the speech subsystem: explicit request time.
  local key = vim.env[config.key_env]
  if type(key) ~= "string" or key == "" then
    return nil, "provider API key environment variable is not set"
  end
  if #key > 16384 or key:find("[%c]") then
    return nil, "invalid provider API key format"
  end
  return "Bearer " .. key
end

local function decode_json(data)
  assert(type(data) == "string", "response data must be a string")
  if data == "" then
    return nil, "speech provider returned an empty response"
  end
  local decoded, response = pcall(vim.json.decode, data)
  if not decoded or type(response) ~= "table" then
    return nil, "invalid speech provider JSON response"
  end
  if response.error ~= nil and response.error ~= vim.NIL then
    return nil, "speech provider returned an API error (response details withheld)"
  end
  return response
end

-- spec = { path, form|body, output_path, max_upload_bytes, max_output_bytes }.
-- JSON responses are decoded; file responses deliver `{ path, bytes }`.
function M.request(config, spec, callback)
  assert(type(config) == "table", "resolved speech config required")
  assert(type(spec) == "table", "request spec must be a table")
  assert(type(spec.path) == "string", "spec.path must be a string")
  assert(spec.form == nil or spec.body == nil, "spec cannot carry both form and body")
  assert(spec.form ~= nil or spec.body ~= nil, "spec needs a form or a body")
  assert(type(callback) == "function", "callback must be a function")
  local headers = {}
  if config.auth then
    local bearer, auth_error = authorization(config)
    if not bearer then
      return deliver.rejected(callback, auth_error)
    end
    headers.Authorization = bearer
  end
  local body = nil
  if spec.body then
    local encoded, value = pcall(vim.json.encode, spec.body)
    if not encoded then
      return deliver.rejected(callback, "cannot encode speech request")
    end
    body = value
  end
  return transport.request({
    endpoint = config.endpoint,
    credential_host = config.credential_host,
    allow_insecure_local = config.allow_insecure_local,
    path = spec.path,
    method = "POST",
    headers = headers,
    body = body,
    form = spec.form,
    output_path = spec.output_path,
    max_upload_bytes = spec.max_upload_bytes,
    max_output_bytes = spec.max_output_bytes,
    timeout = config.timeout,
    -- Transcripts are small; the general cap is a defence, not a budget.
    max_request_bytes = 1024 * 1024,
    max_response_bytes = spec.max_output_bytes and (spec.max_output_bytes + 65536) or 1024 * 1024,
  }, function(err, data, meta)
    if err then
      callback(err)
      return
    end
    if spec.output_path then
      assert(data == spec.output_path, "transport must report the requested output path")
      callback(nil, { path = spec.output_path, bytes = meta.bytes })
      return
    end
    local response, decode_error = decode_json(data)
    if not response then
      callback(decode_error)
      return
    end
    callback(nil, response)
  end)
end

return M
