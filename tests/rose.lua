-- Offline Rose integration/security contract; actual cross-repository TLS is a separate gate.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local config = require("rose.config")
local http = require("rose.native.http")
local router = require("rose.native.model")
local passed, failures = 0, {}
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failures[#failures + 1] = name .. ": " .. tostring(err)
    print("FAIL " .. failures[#failures])
  end
end
---@generic A, B
---@param actual A
---@param expected B
local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end
local function contains(value, text)
  assert(type(value) == "string" and value:find(text, 1, true), tostring(value))
end
local function with_system(system, fn)
  local original = vim.system
  vim.system = system
  local ok, err = pcall(fn)
  vim.system = original
  assert(ok, err)
end
local function forbidden()
  error("unexpected process or credential read")
end
---@return string[]
local function forbidden_readfile()
  error("unexpected file read")
end
---@generic Result, Token
---@param start fun(callback: fun(err: string?, result?: Result)): Token
---@return string? err
---@return Result? result
---@return Token token
local function await(start)
  local calls, result = 0, nil
  ---@type string?
  local err
  local token = start(function(e, value)
    calls, err, result = calls + 1, e, value
  end)
  assert(
    vim.wait(2000, function()
      return calls > 0
    end, 5),
    "callback deadline"
  )
  equal(calls, 1)
  return err, result, token
end
local function request(opts)
  return await(function(cb)
    return http.request(opts, cb)
  end)
end
local function secure(extra)
  return vim.tbl_deep_extend("force", {
    provider = "rose",
    url = "https://rose.example.test:11434/api/chat",
    allow_remote = true,
    tls = {
      ca_file = "/credentials/ca.pem",
      cert_file = "/credentials/client.pem",
      key_file = "/credentials/client-key.pem",
    },
  }, extra or {})
end
local function argument(argv, name)
  for index, value in ipairs(argv) do
    if value == name then
      return argv[index + 1]
    end
  end
end
local function respond(opts, done, code, body, stderr)
  opts.stdout(nil, body or "ok\n200")
  opts.stderr(nil, stderr)
  done({ code = code or 0, signal = 0 })
end

test("Rose defaults are separate from Ollama and need no cloud consent", function()
  local cfg = config.resolve()
  equal(cfg.providers, { provider = "rose", enabled = false, allow_cloud = false })
  equal(cfg.rose.base_url, "http://127.0.0.1:11434")
  equal(cfg.rose.model, "qwen2.5-coder:7b")
  equal(cfg.rose.timeout, 120000)
  equal(cfg.rose.tls, {})
  equal(cfg.rose.options, nil)
  equal(cfg.ollama.options, nil)
  assert(cfg.rose ~= cfg.ollama)
  equal(router.describe(cfg), { provider = "rose", model = cfg.rose.model, cloud = false })
  equal(router.capabilities(cfg).provider, "rose")
  equal(router.capabilities(cfg).tools, true)
  assert(router.validate(cfg))
end)

test("legacy Ollama-only overrides auto-select Ollama without copying or discarding", function()
  local opts = { ollama = { model = "old-model", timeout = 8765, options = { num_ctx = 3210 } } }
  local cfg = config.resolve(opts)
  equal(cfg.providers.provider, "ollama")
  equal(cfg.ollama.model, "old-model")
  equal(cfg.ollama.options, opts.ollama.options)
  equal(cfg.rose.model, "qwen2.5-coder:7b")
  equal(cfg.rose.options, nil)
  equal(opts.providers, nil)
  equal(config.resolve({ ollama = {} }).providers.provider, "ollama")
  equal(
    config.resolve({ ollama = {}, providers = { allow_cloud = false } }).providers.provider,
    "ollama"
  )
end)

test("explicit provider wins; both sections default to Rose and retain overrides", function()
  local opts = { rose = { model = "new-model" }, ollama = { model = "old-model" } }
  local cfg = config.resolve(opts)
  equal(cfg.providers.provider, "rose")
  equal(cfg.rose.model, "new-model")
  equal(cfg.ollama.model, "old-model")
  cfg = config.resolve({ ollama = opts.ollama, providers = { provider = "rose" } })
  equal(cfg.providers.provider, "rose")
  equal(cfg.rose.model, "qwen2.5-coder:7b")
  equal(cfg.ollama.model, "old-model")
  cfg = config.resolve(vim.tbl_extend("force", opts, { providers = { provider = "ollama" } }))
  equal(router.describe(cfg), { provider = "ollama", model = "old-model", cloud = false })
end)

test("local providers never enter the cloud registry, including generic JSON requests", function()
  local previous = package.loaded["rose.providers"]
  package.loaded["rose.providers"] = { resolve = forbidden, chat = forbidden, request = forbidden }
  local ok, why = pcall(function()
    for _, name in ipairs({ "rose", "ollama" }) do
      local cfg =
        config.resolve({ providers = { provider = name, enabled = true, allow_cloud = true } })
      assert(router.validate(cfg))
      equal(router.describe(cfg).cloud, false)
      equal(router.capabilities(cfg).cloud, false)
      local err = await(function(cb)
        return router.request(cfg, { path = "/models" }, cb)
      end)
      contains(err, "explicitly selected cloud provider")
    end
  end)
  package.loaded["rose.providers"] = previous
  assert(ok, why)
  for _, name in ipairs({ "rose", "ollama" }) do
    local resolved, err = pcall(
      require("rose.providers").resolve,
      config.resolve({
        providers = { provider = name, enabled = true, allow_cloud = true },
      })
    )
    equal(resolved, false)
    contains(err, "not the cloud provider registry")
  end
end)

test("native adapters share /api/chat JSON, tools/options, and provider-specific errors", function()
  local messages = { { role = "user", content = 'hello "model"\n' } }
  local tools = { { type = "function", ["function"] = { name = "read" } } }
  for _, name in ipairs({ "rose", "ollama" }) do
    local cfg = config.resolve({
      providers = { provider = name },
      [name] = { model = name .. "-fixture", options = { temperature = 0, num_ctx = 1024 } },
    })
    with_system(function(argv, opts, done)
      equal(argument(argv, "--url"), "http://127.0.0.1:11434/api/chat")
      equal(argument(argv, "--data-binary"), "@-")
      equal(vim.json.decode(opts.stdin), {
        model = name .. "-fixture",
        messages = messages,
        tools = tools,
        stream = false,
        options = { temperature = 0, num_ctx = 1024 },
      })
      respond(opts, done, 0, '{"message":{"content":"shared protocol","tool_calls":[]}}\n200')
      return { kill = function() end }
    end, function()
      local err, message = await(function(cb)
        return router.chat(cfg, messages, tools, cb)
      end)
      equal(err, nil)
      assert(type(message) == "table")
      equal(message.role, "assistant")
      equal(message.content, "shared protocol")
    end)
    with_system(function(_, opts, done)
      respond(opts, done, 0, "not JSON\n200")
      return { kill = function() end }
    end, function()
      local err = await(function(cb)
        return router.chat(cfg, {}, nil, cb)
      end)
      contains(err, name == "rose" and "invalid Rose JSON" or "invalid Ollama JSON")
    end)
  end
end)

for _, transport in ipairs({ "auto", "curl" }) do
  test("Rose HTTPS " .. transport .. " pins TLS/group/mTLS and strips ambient config", function()
    local spawned = 0
    with_system(function(argv, opts, done)
      spawned = spawned + 1
      equal(argv[1], "curl")
      equal(argv[2], "--disable")
      equal(argument(argv, "--proto"), "=https")
      equal(argument(argv, "--max-redirs"), "0")
      equal(argument(argv, "--noproxy"), "*")
      equal(argument(argv, "--proxy"), "")
      assert(vim.tbl_contains(argv, "--globoff") and vim.tbl_contains(argv, "--tlsv1.3"))
      equal(argument(argv, "--tls-max"), "1.3")
      equal(argument(argv, "--curves"), "X25519MLKEM768")
      equal(argument(argv, "--cert"), "/credentials/client.pem")
      equal(argument(argv, "--key"), "/credentials/client-key.pem")
      equal(argument(argv, "--cacert"), "/credentials/ca.pem")
      equal(argument(argv, "--cert-type"), "PEM")
      for _, forbidden_flag in ipairs({ "--insecure", "-k", "--location", "-L", "--config", "-K" }) do
        assert(not vim.tbl_contains(argv, forbidden_flag), forbidden_flag)
      end
      equal(opts.clear_env, true)
      equal(opts.env.HTTPS_PROXY, nil)
      equal(opts.env.SSLKEYLOGFILE, nil)
      equal(opts.env.CURL_CA_BUNDLE, nil)
      respond(opts, done)
      return { kill = function() end }
    end, function()
      local err, body = request(secure({ transport = transport }))
      equal(err, nil)
      equal(body, "ok")
    end)
    equal(spawned, 1)
  end)
end

test("CA is optional, certificate/key paths with spaces remain single argv entries", function()
  local opts = secure()
  opts.tls.ca_file = nil
  opts.tls.cert_file = "/credentials/client certificate.pem"
  with_system(function(argv, process_opts, done)
    equal(argument(argv, "--cacert"), nil)
    equal(argument(argv, "--cert"), opts.tls.cert_file)
    respond(process_opts, done)
    return { kill = function() end }
  end, function()
    equal(request(opts), nil)
  end)
end)

for _, case in ipairs({
  {
    label = "remote plaintext despite allow_remote",
    opts = { url = "http://rose.example.test" },
    error = "plaintext HTTP",
  },
  {
    label = "localhost DNS plaintext",
    opts = { url = "http://localhost:11434" },
    error = "plaintext HTTP",
  },
  {
    label = "remote without allow_remote",
    opts = { allow_remote = false },
    error = "allow_remote=true",
  },
  { label = "native HTTPS", opts = { transport = "native" }, error = "native transport" },
  {
    label = "native loopback HTTP",
    opts = { url = "http://127.0.0.1:11434", transport = "native" },
    error = "native transport",
  },
  {
    label = "credentials on HTTP",
    opts = { url = "http://127.0.0.1:11434" },
    error = "TLS options require",
  },
  {
    label = "URL userinfo",
    opts = { url = "https://user@rose.example.test" },
    error = "without userinfo",
  },
  {
    label = "URL query",
    opts = { url = "https://rose.example.test/?token=value" },
    error = "invalid HTTP URL",
  },
  {
    label = "TLS downgrade option",
    opts = { tls = { min_version = "1.2" } },
    error = "unknown rose.tls field",
  },
  {
    label = "curve downgrade option",
    opts = { tls = { curves = "X25519" } },
    error = "unknown rose.tls field",
  },
  {
    label = "insecure TLS option",
    opts = { tls = { insecure = true } },
    error = "unknown rose.tls field",
  },
  {
    label = "inline certificate",
    opts = { tls = { cert_file = "-----BEGIN CERTIFICATE-----\nsecret" } },
    error = "without controls",
  },
  {
    label = "certificate password",
    opts = { tls = { cert_file = "/cert.pem:secret" } },
    error = "without embedded passwords",
  },
  {
    label = "Windows drive certificate",
    opts = { tls = { cert_file = "C:\\cert.pem" } },
    error = "absolute POSIX",
  },
  {
    label = "relative certificate",
    opts = { tls = { cert_file = "cert.pem" } },
    error = "absolute POSIX",
  },
  { label = "empty certificate", opts = { tls = { cert_file = "" } }, error = "nonempty path" },
  {
    label = "overlong certificate path",
    opts = { tls = { cert_file = "/" .. string.rep("x", 4096) } },
    error = "4096 bytes",
  },
}) do
  test("rejects " .. case.label .. " before subprocess creation", function()
    with_system(forbidden, function()
      contains(request(secure(case.opts)), case.error)
    end)
    equal(next(http.active), nil)
  end)
end

test("all HTTPS requires client cert/key; unmatched pairs and native TLS are rejected", function()
  with_system(forbidden, function()
    for _, host in ipairs({ "127.0.0.1", "[::1]", "rose.example.test" }) do
      local opts = secure({ url = "https://" .. host })
      opts.tls = {}
      contains(request(opts), "requires paired client")
      opts.tls = { cert_file = "/cert.pem" }
      contains(request(opts), "requires paired")
      opts.tls = { key_file = "/key.pem" }
      contains(request(opts), "requires paired")
    end
    contains(request(secure({ provider = "ollama", transport = "native" })), "native transport")
    contains(request(secure({ provider = "ollama" })), "TLS options require a Rose")
  end)
  equal(http.validate({ provider = "rose", url = "http://127.0.0.1:11434" }), nil)
  equal(http.validate({ provider = "rose", url = "http://[::1]:11434" }), nil)
  contains(
    http.validate({ provider = "rose", url = "http://127.0.0.1", transport = "native" }),
    "native"
  )
end)

for _, case in ipairs({
  { code = 58, error = "could not load PEM client certificate (file missing or invalid)" },
  { code = 60, error = "SSL peer certificate cannot be authenticated with given CA certificates" },
  { code = 35, error = "TLS handshake failed: unsupported group or protocol" },
  { code = 59, error = "failed setting curves list X25519MLKEM768" },
}) do
  test("curl TLS error " .. case.code .. " surfaces with no downgrade retry", function()
    local count = 0
    with_system(function(_, opts, done)
      count = count + 1
      respond(opts, done, case.code, "", case.error)
      return { kill = function() end }
    end, function()
      local err, body = request(secure())
      contains(err, "HTTP failed (" .. case.code .. ")")
      contains(err, case.error)
      equal(body, nil)
    end)
    equal(count, 1)
    equal(next(http.active), nil)
  end)
end

test("HTTP redirects cannot downgrade HTTPS or become a successful response", function()
  with_system(function(argv, opts, done)
    equal(argument(argv, "--max-redirs"), "0")
    respond(opts, done, 0, "redirect to http://example.test\n302")
    return { kill = function() end }
  end, function()
    contains(request(secure()), "HTTP status 302")
  end)
end)

test("streaming output caps kill once, reject late completion, and clean up", function()
  for _, stream in ipairs({ "stdout", "stderr", "chunks" }) do
    local kills, callbacks = 0, 0
    with_system(function(_, opts, done)
      vim.schedule(function()
        if stream == "chunks" then
          for _ = 1, 4097 do
            opts.stdout(nil, "x")
          end
        else
          opts[stream](nil, string.rep("x", stream == "stdout" and 8197 or 65537))
        end
        opts.stdout(nil, "late\n200")
        done({ code = 0, signal = 0 })
      end)
      return {
        kill = function()
          kills = kills + 1
        end,
      }
    end, function()
      local token = http.request(secure({ max_response = 8192 }), function(err, body)
        callbacks = callbacks + 1
        contains(err, "output exceeds size limit")
        equal(body, nil)
      end)
      assert(vim.wait(2000, function()
        return callbacks > 0
      end, 5))
      token.cancel()
    end)
    equal(kills, 1)
    equal(callbacks, 1)
    equal(next(http.active), nil)
  end
end)

test("receive and TLS path limits accept exact boundaries", function()
  local tls = secure().tls
  tls.cert_file = "/" .. string.rep("x", 4095)
  equal(http.validate_tls(tls), nil)
  local output = string.rep("x", 8192)
  with_system(function(_, opts, done)
    respond(opts, done, 0, output .. "\n200", string.rep("e", 65536))
    return { kill = function() end }
  end, function()
    local err, body = request(secure({ max_response = 8192 }))
    equal(err, nil)
    equal(body, output)
  end)
end)

test("streaming cancellation and read errors finish exactly once", function()
  for _, cancel in ipairs({ true, false }) do
    local kills, callbacks = 0, 0
    with_system(function(_, opts, done)
      vim.schedule(function()
        -- Deliberately deliver a late stream error after cancellation too.
        opts.stdout("EIO", "partial")
        done({ code = 0, signal = 0 })
      end)
      return {
        kill = function()
          kills = kills + 1
        end,
      }
    end, function()
      local token = http.request(secure(), function(err)
        callbacks = callbacks + 1
        contains(err, cancel and "cancelled" or "stream read failed")
      end)
      if cancel then
        token.cancel()
      end
      assert(vim.wait(2000, function()
        return callbacks > 0
      end, 5))
      token.cancel()
    end)
    equal(kills, 1)
    equal(callbacks, 1)
    equal(next(http.active), nil)
  end
end)

test("setup and health never read credentials or start services", function()
  local rose = require("rose")
  local environment, getenv, open, readfile, fs_open =
    vim.env, os.getenv, io.open, vim.fn.readfile, vim.uv.fs_open
  local spawn, tcp = vim.uv.spawn, vim.uv.new_tcp
  vim.env = setmetatable({}, { __index = forbidden })
  os.getenv, io.open, vim.fn.readfile, vim.uv.fs_open =
    forbidden, forbidden, forbidden_readfile, forbidden
  vim.uv.spawn, vim.uv.new_tcp = forbidden, forbidden
  local ok, err = pcall(function()
    with_system(forbidden, function()
      assert(rose.setup({
        rose = {
          base_url = "https://rose.example.test:11434",
          allow_remote = true,
          tls = secure().tls,
        },
      }))
      require("rose.health").check()
      equal(rose.options.providers.provider, "rose")
      equal(require("rose.webui").status().running, false)
      rose.shutdown()
    end)
  end)
  vim.env, os.getenv, io.open, vim.fn.readfile, vim.uv.fs_open =
    environment, getenv, open, readfile, fs_open
  vim.uv.spawn, vim.uv.new_tcp = spawn, tcp
  assert(ok, err)
end)

test("public setup rejects policy failures without publishing weaker config", function()
  local rose, notify = require("rose"), vim.notify
  vim.notify = function() end
  local ok, why = pcall(function()
    assert(rose.setup({}))
    local original = rose.options
    for _, opts in ipairs({
      { rose = { base_url = "http://remote.example.test", allow_remote = true } },
      { rose = { base_url = "https://127.0.0.1:11434" } },
      { rose = { transport = "native" } },
      { rose = { tls = false } },
      { rose = { timeout = -1 } },
    }) do
      local configured, err = rose.setup(opts)
      equal(configured, nil)
      assert(err ~= nil)
      equal(rose.options, original)
    end
    rose.shutdown()
  end)
  vim.notify = notify
  assert(ok, why)
end)

http.stop()
print(("%d Rose integration tests passed; %d failed"):format(passed, #failures))
if #failures > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
