-- Run offline: nvim --headless -u NONE -l tests/providers.lua
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
---@generic Result, Token
---@param start fun(callback: fun(err: string?, result?: Result)): Token
---@param timeout? integer
---@return string? err
---@return Result? result
---@return Token token
local function await(start, timeout)
  local done, calls, result = false, 0, nil
  ---@type string?
  local err
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

local port, server_error
local fixture = vim.system(
  { vim.env.ROSE_TEST_PYTHON or "python3", root .. "/tests/providers_fixture.py" },
  {
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
  }
)
assert(
  vim.wait(5000, function()
    return port ~= nil or server_error ~= nil
  end, 5),
  "fixture did not start"
)
assert(port, server_error)
local authority = "127.0.0.1:" .. port
local fake = "rose-fixture-fake-key"
local envs =
  { "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "XAI_API_KEY", "NVIDIA_API_KEY", "PERPLEXITY_API_KEY" }
for _, key in ipairs(envs) do
  vim.env[key] = fake
end
local router = require("rose.native.model")
local tools = {
  {
    type = "function",
    ["function"] = {
      name = "lookup",
      description = "Read fixture",
      parameters = {
        type = "object",
        properties = { path = { type = "string" } },
        required = { "path" },
      },
    },
  },
}
local input = {
  { role = "system", content = "System instructions." },
  { role = "user", content = "Read fixture." },
}
local function config(name, api, extra)
  local selected = {
    api = api,
    endpoint = "http://" .. authority .. "/" .. name,
    model = "fixture-model",
    credential_host = authority,
    allow_insecure_local = true,
    capabilities = { tools = api ~= "sonar" },
    timeout = 4000,
    options = { parallel_tool_calls = false },
  }
  if name == "anthropic" then
    selected.options = { max_tokens = 512, thinking = { type = "enabled", budget_tokens = 128 } }
  elseif api == "sonar" then
    selected.options = { search_domain_filter = { "example.test" } }
  end
  selected = vim.tbl_deep_extend("force", selected, extra or {})
  return { providers = { enabled = true, allow_cloud = true, provider = name, [name] = selected } }
end
local function invoke(cfg, messages, schemas)
  return await(function(cb)
    return router.chat(cfg, messages or input, schemas or tools, cb)
  end)
end
local function request(cfg, spec)
  return await(function(cb)
    return router.request(cfg, spec, cb)
  end)
end
local cases = {
  { "openai", "responses" },
  { "openai", "chat" },
  { "anthropic", "messages" },
  { "xai", "chat" },
  { "xai", "responses" },
  { "nvidia", "chat" },
  { "perplexity", "agent" },
}

for _, case in ipairs(cases) do
  local name, api = unpack(case)
  test(name .. "/" .. api .. " real HTTP tool-call and opaque replay", function()
    local cfg = config(name, api)
    local err, first = invoke(cfg)
    assert(not err, err)
    assert(type(first) == "table", "provider must return a message")
    equal(first.content, "Public answer.")
    equal(first.tool_calls[1].id, "call_fixture_17")
    equal(first.tool_calls[1]["function"].name, "lookup")
    equal(first.finish_reason, "tool_calls")
    equal(first.usage.input_tokens, 11)
    equal(first.usage.output_tokens, 7)
    equal(first.usage.total_tokens, 18)
    assert(not first.content:find("PRIVATE", 1, true) and not first.content:find("opaque", 1, true))
    if name == "anthropic" then
      equal(first._provider.response.content[1].signature, "signature-must-replay-exactly")
      equal(first._provider.response.content[2].data, "opaque-encrypted-reasoning")
    elseif api == "responses" or api == "agent" then
      equal(first._provider.response.output[1].encrypted_content, "opaque-encrypted-reasoning")
      equal(first._provider.response.output[2].phase, "commentary")
      equal(first._provider.response.vendor_top_level, { keep = true })
    else
      equal(
        first._provider.response.choices[1].message.reasoning_content,
        "opaque-encrypted-reasoning"
      )
    end
    local next_messages = vim.deepcopy(input)
    next_messages[#next_messages + 1] = vim.deepcopy(first)
    next_messages[#next_messages + 1] = {
      role = "tool",
      tool_call_id = first.tool_calls[1].id,
      tool_name = "lookup",
      content = '{"ok":true}',
    }
    err, first = invoke(cfg, next_messages)
    assert(not err, err)
    assert(type(first) == "table", "provider replay must return a message")
    equal(first.content, "Replay verified.")
    equal(first.finish_reason, "stop")
  end)
end

test("Sonar is search/citations, never advertised as generic custom tools", function()
  local cfg = config("perplexity", "sonar")
  local err, response = invoke(cfg, input, {})
  assert(not err, err)
  assert(type(response) == "table", "Sonar must return a response")
  equal(response.citations[1].url, "https://example.test/doc")
  equal(response._provider.response.search_results[1].title, "Fixture")
  equal(router.capabilities(cfg).tools, false)
  err = invoke(cfg)
  assert(err and err:find("custom tools", 1, true))
  cfg.providers.perplexity.capabilities.tools = true
  assert(not router.validate(cfg))
end)

test("Ollama remains default and receives its original config", function()
  local module, got = require("rose.native.ollama"), nil
  local original = module.chat
  module.chat = function(cfg, _messages, _schemas, cb)
    got = cfg
    vim.schedule(function()
      cb(nil, { role = "assistant", content = "local" })
    end)
    return { cancel = function() end }
  end
  local local_cfg = { ollama = { model = "local-fixture" } }
  local err, message = invoke(local_cfg)
  module.chat = original
  assert(not err, err)
  equal(got, local_cfg.ollama)
  assert(type(message) == "table", "Ollama must return a message")
  equal(message.content, "local")
  equal(router.describe(local_cfg).cloud, false)
end)

test("validation and capabilities never read keys or start a request", function()
  for _, key in ipairs(envs) do
    vim.env[key] = nil
  end
  local original = vim.system
  vim.system = function()
    error("unexpected process during validation")
  end
  local original_env = vim.env
  vim.env = setmetatable({}, {
    __index = function()
      error("unexpected environment read during validation")
    end,
  })
  for _, case in ipairs(cases) do
    assert(router.validate(config(unpack(case))))
    equal(router.capabilities(config(unpack(case))).enabled, true)
  end
  vim.env = original_env
  vim.system = original
  local err = invoke(config("openai", "responses"))
  assert(err and err:find("not set", 1, true))
  for _, key in ipairs(envs) do
    vim.env[key] = fake
  end
end)

test("both cloud consent fields are required before dispatch", function()
  for _, flag in ipairs({ "enabled", "allow_cloud" }) do
    local cfg = config("openai", "responses")
    cfg.providers[flag] = false
    local err = invoke(cfg)
    assert(err and err:find("leave your device", 1, true))
  end
end)

test("model endpoint API and tools are explicit; unsupported config is rejected", function()
  for _, field in ipairs({ "model", "endpoint", "api" }) do
    local cfg = config("openai", "responses")
    cfg.providers.openai[field] = nil
    assert(not router.validate(cfg))
  end
  local cfg = config("openai", "responses")
  cfg.providers.openai.capabilities.tools = false
  local err = invoke(cfg)
  assert(err and err:find("custom tools", 1, true))
  cfg = config("openai", "responses")
  cfg.providers.openai.api_key = fake
  assert(not router.validate(cfg))
  cfg = config("nvidia", "responses")
  assert(not router.validate(cfg))
end)

test("HTTPS and exact credential authority are enforced", function()
  for _, endpoint in ipairs({
    "http://example.test/v1",
    "https://api.openai.com@evil.test/v1",
    "https://api.openai.com.evil.test/v1",
    "https://api.openai.com/v1?token=secret",
    "https://api.openai.com\\@evil.test/v1",
  }) do
    local cfg = config("openai", "responses")
    cfg.providers.openai.endpoint = endpoint
    assert(not router.validate(cfg))
  end
  local cfg = config("openai", "responses")
  cfg.providers.openai.allow_insecure_local = false
  assert(not router.validate(cfg))
  cfg = config("openai", "responses")
  cfg.providers.openai.credential_host = "localhost:" .. port
  assert(not router.validate(cfg))
end)

test("NVIDIA loopback can explicitly disable authentication", function()
  local cfg =
    config("nvidia", "chat", { endpoint = "http://" .. authority .. "/noauth", auth = false })
  local err, response = invoke(cfg)
  assert(not err, err)
  assert(type(response) == "table", "NVIDIA must return a message")
  equal(response.content, "Public answer.")
  cfg.providers.nvidia.endpoint = "https://example.test/v1"
  cfg.providers.nvidia.credential_host = "example.test"
  assert(not router.validate(cfg))
  cfg = config("openai", "responses", { auth = false })
  assert(not router.validate(cfg))
end)

test("opaque metadata cannot silently migrate to another model/provider", function()
  local cfg = config("openai", "responses")
  local err, response = invoke(cfg)
  assert(not err, err)
  local history = vim.deepcopy(input)
  history[#history + 1] = response
  history[#history + 1] = { role = "tool", tool_call_id = "call_fixture_17", content = "{}" }
  cfg.providers.openai.model = "different-model"
  err = invoke(cfg, history)
  assert(err and err:find("different endpoint", 1, true))
end)

test("unsupported fields, stream overrides and tool-result ID mismatches fail loudly", function()
  local cfg = config("openai", "responses", { options = { stream = true } })
  assert(invoke(cfg))
  cfg = config("openai", "responses", { options = { tools = {} } })
  assert(invoke(cfg))
  cfg = config("openai", "responses", { options = { n = 2 } })
  assert(invoke(cfg))
  local history = vim.deepcopy(input)
  history[2].media = "unsupported"
  assert(invoke(config("openai", "responses"), history))
  history = vim.deepcopy(input)
  history[#history + 1] = { role = "tool", tool_call_id = "wrong", content = "{}" }
  assert(invoke(config("anthropic", "messages"), history))
end)

test("raw JSON preserves native fields and explicit beta headers", function()
  local cfg = config("anthropic", "messages", { headers = { ["anthropic-beta"] = "fixture-beta" } })
  local body = {
    model = "fixture-model",
    custom_feature = { nested = true },
    tools = { { type = "native_fixture" } },
    input = { { type = "native_block", content = 'PRIVATE_SOURCE\nquote"\\\n@/etc/passwd' } },
  }
  local err, response = request(cfg, { path = "/inspect?mode=fixture", body = body })
  assert(not err, err)
  assert(type(response) == "table", "inspect fixture must return a response")
  equal(response.body, body)
  equal(response.beta, "fixture-beta")
  err, response = request(cfg, { path = "/inspect", method = "GET" })
  assert(not err, err)
  assert(type(response) == "table", "inspect fixture must return a response")
  equal(response.method, "GET")
  for _, path in ipairs({
    "https://evil.test",
    "//evil.test",
    "/../secret",
    "/%2e%2e/secret",
    "/a\\b",
  }) do
    assert(request(cfg, { path = path, body = {} }))
  end
end)

for _, provider in ipairs({ "openai", "anthropic", "xai", "nvidia", "perplexity" }) do
  test(provider .. " raw SSE events on local HTTP including split frames", function()
    local api = provider == "anthropic" and "messages"
      or provider == "perplexity" and "agent"
      or "chat"
    local events = {}
    local err, result = request(config(provider, api), {
      path = "/sse",
      stream = true,
      body = { stream = true },
      on_event = function(event)
        events[#events + 1] = event
      end,
    })
    assert(not err, err)
    assert(#events >= 2)
    assert(type(result) == "table", "SSE request must return an event count")
    equal(result.events, #events)
    if provider == "anthropic" then
      equal(events[2].data.delta.text, "Hello")
    end
  end)
end

test("SSE errors malformed/truncated/oversized events never expose fake keys", function()
  for _, path in ipairs({ "/sse_bad", "/sse_error", "/sse_truncated", "/sse_large" }) do
    local err = request(config("openai", "responses", { max_event_bytes = 128 }), {
      path = path,
      stream = true,
      body = { stream = true },
    })
    assert(err and not err:find(fake, 1, true), "expected redacted SSE error")
  end
end)

test("HTTP errors malformed JSON and redirects are redacted", function()
  for _, provider in ipairs({ "openai", "anthropic", "xai", "nvidia", "perplexity" }) do
    local api = provider == "anthropic" and "messages"
      or provider == "perplexity" and "agent"
      or "chat"
    for _, path in ipairs({ "/error", "/api_error", "/invalid", "/redirect" }) do
      local err = request(config(provider, api), { path = path, body = {} })
      assert(err and not err:find(fake, 1, true) and not err:find("PRIVATE_SOURCE", 1, true))
      if path == "/redirect" then
        assert(err:find("redirects are not followed", 1, true))
      end
    end
  end
end)

test("request/response/time bounds and cancellation are enforced exactly once", function()
  local cfg = config("openai", "responses", { max_response_bytes = 512, max_event_bytes = 128 })
  local err = request(cfg, { path = "/large", body = {} })
  assert(err and err:find("size limit", 1, true))
  cfg = config("openai", "responses", { max_request_bytes = 256 })
  err = request(cfg, { path = "/inspect", body = { huge = string.rep("x", 1024) } })
  assert(err and err:find("size limit", 1, true))
  cfg = config("openai", "responses", { timeout = 50 })
  err = request(cfg, { path = "/slow", body = {} })
  assert(err)
  local count, cancelled = 0, nil
  local token = router.request(
    config("openai", "responses"),
    { path = "/slow", body = {} },
    function(e)
      count = count + 1
      cancelled = e
    end
  )
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
  equal(cancelled, "cancelled")
  equal(next(require("rose.providers.transport").active), nil)
end)

test("curl receives neither key nor source in argv or inherited environment", function()
  local original, seen = vim.system, false
  vim.system = function(argv, opts, cb)
    if argv[1] == "curl" then
      seen = true
      equal(argv, { "curl", "--disable", "--config", "-" })
      assert(not table.concat(argv, " "):find(fake, 1, true))
      assert(not table.concat(argv, " "):find("PRIVATE_SOURCE", 1, true))
      assert(opts.clear_env and opts.env.OPENAI_API_KEY == nil and opts.env.HTTPS_PROXY == nil)
      assert(opts.stdin:find(fake, 1, true) and opts.stdin:find("PRIVATE_SOURCE", 1, true))
      assert(opts.stdin:find('proxy = ""', 1, true) and opts.stdin:find("max-redirs = 0", 1, true))
    end
    return original(argv, opts, cb)
  end
  local err, response = request(
    config("openai", "responses"),
    { path = "/inspect", body = { text = "PRIVATE_SOURCE" } }
  )
  vim.system = original
  assert(not err, err)
  assert(seen)
  assert(type(response) == "table", "inspect fixture must return a response")
  equal(response.body.text, "PRIVATE_SOURCE")
end)

router.stop()
fixture:kill(9)
for _, key in ipairs(envs) do
  vim.env[key] = nil
end
print(string.format("Provider tests: %d passed, %d failed", passed, #failures))
if #failures > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
