-- Run: nvim --headless -u NONE -l tests/core.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local uv = vim.uv or vim.loop
local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")
local fixture = root .. "/tests/core_fixture.py"
local passed, failures = 0, {}
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failures[#failures + 1] = name .. ": " .. err
    print("FAIL " .. name .. ": " .. err)
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
  local done, result = false, nil
  ---@type string?
  local err
  local token = start(function(e, r)
    err, result, done = e, r, true
  end)
  assert(
    vim.wait(timeout or 5000, function()
      return done
    end, 5),
    "callback deadline exceeded"
  )
  return err, result, token
end
local function config(extra)
  return require("rose.config").resolve(
    vim.tbl_deep_extend(
      "force",
      { workspace = workspace, trusted = true, agent = { max_repair_rounds = 0 } },
      extra or {}
    )
  )
end
local function fake_tools(handler)
  return {
    schemas = function()
      local result = {}
      for _, name in ipairs({
        "editor_context",
        "editor_check",
        "editor_diagnostics",
        "editor_lint",
        "file_read",
        "file_write",
      }) do
        result[#result + 1] =
          { type = "function", ["function"] = { name = name, parameters = { type = "object" } } }
      end
      return result
    end,
    call = function(name, args)
      if handler then
        local result = handler(name, args)
        if result then
          return result
        end
      end
      if name == "editor_diagnostics" then
        return { status = "unavailable", diagnostics = {} }
      end
      if name == "editor_context" then
        return {
          status = "ok",
          path = args.path,
          workspace_snapshot_version = 1,
          workspace_snapshot = {},
          dirty_buffers = {},
        }
      end
      if name == "editor_lint" then
        return { status = "ok", verified = true, linters = { { status = "ok", name = "fixture" } } }
      end
      return { status = "ok", path = args.path }
    end,
  }
end

test("default require/setup has no subprocess, legacy dependency or secret reads", function()
  local system, previous = vim.system, {}
  vim.system = function()
    error("unexpected subprocess during setup")
  end
  for _, name in ipairs({
    "plenary",
    "plenary.curl",
    "fzf-lua",
    "rose.api",
    "rose.legacy.config",
    "rose.binary",
    "rose.rose",
    "rose.tokenizers",
  }) do
    previous[name] = package.preload[name]
    package.preload[name] = function()
      error("unexpected legacy load " .. name)
    end
  end
  local ok, err = pcall(function()
    local rose = require("rose")
    local spec = assert(loadfile(root .. "/lazy.lua"))()
    equal(spec.dependencies, nil)
    equal(spec.build, nil)
    equal(spec.opts.trusted, false)
    assert(rose.setup({ workspace = workspace }))
    assert(rose.setup({ workspace = workspace }))
    equal(rose.options.trusted, false)
    equal(rose.options.providers, { enabled = false, allow_cloud = false, provider = "rose" })
    equal(rose.options.rose.base_url, "http://127.0.0.1:11434")
    equal(rose.options.rose.model, "qwen2.5-coder:7b")
    equal(rose.options.rose.tls, {})
    equal(rose.options.ollama.base_url, "http://127.0.0.1:11434")
    equal(rose.options.ollama.model, "qwen2.5-coder:7b")
    for _, name in ipairs({
      "RoseAsk",
      "RoseAgent",
      "RoseCheck",
      "RoseFlow",
      "RoseStop",
      "RoseHubDownload",
      "RoseHubUpload",
      "RoseHubPaper",
      "RoseHubStop",
      "RoseHubStatus",
    }) do
      assert(vim.api.nvim_get_commands({})[name], name)
    end
    equal(#vim.api.nvim_get_autocmds({ group = "RoseNative" }), 1)
    assert(
      not package.loaded["rose.api"]
        and not package.loaded["plenary"]
        and not package.loaded["fzf-lua"]
    )
    rose.shutdown()
  end)
  vim.system = system
  for name, value in pairs(previous) do
    package.preload[name] = value
  end
  for _, name in ipairs({
    "plenary",
    "plenary.curl",
    "fzf-lua",
    "rose.api",
    "rose.legacy.config",
    "rose.binary",
    "rose.rose",
    "rose.tokenizers",
  }) do
    package.preload[name] = previous[name]
  end
  assert(ok, err)
end)

test("cloud setup requires explicit consent without reading keys or making requests", function()
  local rose = require("rose")
  local system, environment, notify = vim.system, vim.env, vim.notify
  vim.system = function()
    error("setup must not spawn")
  end
  vim.env = setmetatable({}, {
    __index = function()
      error("setup must not read environment credentials")
    end,
  })
  vim.notify = function() end
  local ok, failure = pcall(function()
    local opts = {
      workspace = workspace,
      providers = {
        enabled = true,
        allow_cloud = false,
        provider = "openai",
        openai = {
          api = "responses",
          endpoint = "https://api.openai.com/v1",
          model = "fixture",
          capabilities = { tools = true },
        },
      },
    }
    local configured, why = rose.setup(opts)
    equal(configured, nil)
    assert(type(why) == "string" and why:find("allow_cloud", 1, true))
    opts.providers.allow_cloud = true
    assert(rose.setup(opts))
    local info = require("rose.native.model").describe(rose.options)
    equal(info.provider, "openai")
    equal(info.cloud, true)
    require("rose.health").check()
    rose.shutdown()
  end)
  vim.system, vim.env, vim.notify = system, environment, notify
  assert(ok, failure)
end)

test("Hub setup cannot override top-level trust and upload fails before subprocess", function()
  local rose = require("rose")
  assert(rose.setup({ workspace = workspace, trusted = false, hub = { trusted = true } }))
  local system = vim.system
  vim.system = function()
    error("untrusted upload must not spawn")
  end
  local ok, failure = pcall(function()
    local err = await(function(cb)
      return rose.hub_upload(
        { repo_id = "fixture/model", repo_type = "model", files = { "model.bin" } },
        cb
      )
    end)
    assert(err and err:find("trusted workspace", 1, true), err)
    equal(rose.writer, nil)
  end)
  vim.system = system
  rose.shutdown()
  assert(ok, failure)
end)

test("capability guards use real nightly APIs without assumed DAP", function()
  local caps = require("rose.native.http").capabilities()
  equal(caps.system, true)
  equal(caps.curl, true)
  equal(caps.native_request, type(require("vim.net").request) == "function")
  equal(rawget(vim, "debug"), nil)
end)

test("config validates bounded iterations and resolves workspace", function()
  assert(not pcall(config, { agent = { max_iterations = 0 } }))
  assert(not pcall(config, { ollama = { timeout = -1 } }))
  equal(config().workspace, uv.fs_realpath(workspace))
  local single_cycle =
    require("rose.config").resolve({ workspace = workspace, agent = { max_cycles = 1 } })
  equal(single_cycle.agent.max_repair_rounds, 0)
  equal(
    require("rose.config").resolve({
      workspace = workspace,
      agent = { max_cycles = 2, max_repair_rounds = 0 },
    }).agent.max_cycles,
    1
  )
end)

test("no tools never invokes model or passes", function()
  local err, report = await(function(cb)
    return require("rose.native.agent").run(config(), "task", cb, {
      tools = {},
      backend = function()
        error("model must not run")
      end,
    })
  end)
  assert(err and err:find("tools unavailable", 1, true))
  assert(type(report) == "table", "agent failure must include a report")
  equal(report.verification.verified, false)
end)

test("three isolated roles preserve tool ids and required validation", function()
  local calls, role_rounds, seen_ids = {}, {}, false
  local tools = fake_tools(function(name, args)
    calls[#calls + 1] = { name = name, path = args.path }
  end)
  local err, report = await(function(cb)
    return require("rose.native.agent").run(
      config({ checks = { unit = { cmd = { "true" } } } }),
      "write a file",
      cb,
      {
        tools = tools,
        backend = function(_, messages, schemas, done)
          local system = messages[1].content
          local role = system:find("only writing", 1, true) and "coder"
            or system:find("independent", 1, true) and "reviewer"
            or "planner"
          role_rounds[role] = (role_rounds[role] or 0) + 1
          for _, schema in ipairs(schemas) do
            if role ~= "coder" then
              assert(schema["function"].name ~= "file_write")
            end
          end
          if role == "coder" and role_rounds[role] == 1 then
            done(nil, {
              content = "",
              _provider = { raw_response = { hidden = "private-fixture-replay" } },
              tool_calls = {
                {
                  id = "original-id-42",
                  ["function"] = {
                    name = "file_write",
                    arguments = { path = "main.lua", content = "return true\n" },
                  },
                },
              },
            })
          else
            if role == "coder" then
              equal(messages[#messages - 1]._provider.raw_response.hidden, "private-fixture-replay")
              equal(messages[#messages].tool_call_id, "original-id-42")
              equal(messages[#messages - 1].tool_calls[1].id, "original-id-42")
              seen_ids = true
            end
            done(nil, {
              content = role == "reviewer"
                  and '{"approved":true,"issues":[],"summary":"reviewer finished"}'
                or role .. " finished",
            })
          end
          return { cancel = function() end }
        end,
      }
    )
  end)
  assert(not err, err)
  assert(type(report) == "table", "agent must return a report")
  equal(report.status, "ok")
  equal(report.verification.verified, true)
  equal(report.changed_files, { "main.lua" })
  assert(not vim.json.encode(report):find("private-fixture-replay", 1, true))
  equal(report.roles.planner.text, "planner finished")
  equal(report.review.summary, "reviewer finished")
  assert(seen_ids)
  local validated_write = false
  for _, call in ipairs(calls) do
    if call.name == "editor_check" and call.path == "main.lua" then
      validated_write = true
    end
  end
  assert(validated_write, "changed path must be checked, not chat scratch")
end)

test("planner cannot write even if model ignores schemas", function()
  local attempts, requests = 0, 0
  local tools = fake_tools(function(name)
    if name == "file_write" then
      attempts = attempts + 1
    end
  end)
  local err, report = await(function(cb)
    return require("rose.native.agent").run(config(), "task", cb, {
      tools = tools,
      backend = function(_, _, _, done)
        requests = requests + 1
        if requests == 1 then
          done(nil, {
            tool_calls = {
              { id = "forbidden", ["function"] = { name = "file_write", arguments = {} } },
            },
          })
        else
          done(nil, { content = "done" })
        end
        return { cancel = function() end }
      end,
    })
  end)
  assert(not err, err)
  equal(attempts, 0)
  assert(type(report) == "table", "agent must return a report")
  equal(report.tool_calls[1].result.status, "error")
  equal(report.verification.verified, false)
end)

test("absent, failed, stale and unavailable checks cannot pass", function()
  for _, status in ipairs({ "failed", "unavailable", "timeout", "stale", "error", "unverified" }) do
    local err, result = await(function(cb)
      return require("rose.native.validation").run(
        config({ checks = { unit = { cmd = { "true" } } } }),
        fake_tools(function(name)
          if name == "editor_check" then
            return { status = status }
          end
        end),
        nil,
        cb
      )
    end)
    assert(not err, err)
    assert(type(result) == "table", "validation must return a report")
    equal(result.verified, false)
  end
  local _, result = await(function(cb)
    return require("rose.native.validation").run(config(), fake_tools(), nil, cb)
  end)
  assert(type(result) == "table", "validation must return a report")
  equal(result.status, "unverified")
end)

test("each changed language requires applicable check coverage", function()
  local _, result = await(function(cb)
    return require("rose.native.validation").run(
      config({ checks = { lua = { cmd = { "true" }, filetypes = { "lua" } } } }),
      fake_tools(),
      nil,
      cb,
      nil,
      { "main.lua", "main.py" }
    )
  end)
  assert(type(result) == "table", "validation must return a report")
  equal(result.verified, false)
  equal(#result.checks, 1)
  equal(result.checks[1].path, "main.lua")
end)

test("diagnostic errors veto successful checks", function()
  local _, result = await(function(cb)
    return require("rose.native.validation").run(
      config({ checks = { unit = { cmd = { "true" } } } }),
      fake_tools(function(name)
        if name == "editor_diagnostics" then
          return { status = "failed", diagnostics = { { severity = 1 } } }
        end
      end),
      nil,
      cb
    )
  end)
  assert(type(result) == "table", "validation must return a report")
  equal(result.status, "failed")
  equal(result.verified, false)
end)

test("generic passing checks cannot replace missing lint or static tooling", function()
  local _, result = await(function(cb)
    return require("rose.native.validation").run(
      config({ checks = { smoke = { cmd = { "true" } } } }),
      fake_tools(function(name)
        if name == "editor_lint" then
          return { status = "unavailable", verified = false }
        end
      end),
      nil,
      cb
    )
  end)
  assert(type(result) == "table", "validation must return a report")
  equal(result.verified, false)
  equal(result.status, "unverified")
  equal(result.lint[1].result.status, "unavailable")
end)

test("explicit completed static check can replace unavailable native lint", function()
  local _, result = await(function(cb)
    return require("rose.native.validation").run(
      config({ checks = { syntax = { cmd = { "true" }, kind = "diagnostics", filetypes = {} } } }),
      fake_tools(function(name)
        if name == "editor_lint" then
          return { status = "unavailable", verified = false }
        end
      end),
      nil,
      cb
    )
  end)
  assert(type(result) == "table", "validation must return a report")
  equal(result.verified, true)
  equal(result.targets[1].static_verified, true)
  equal(result.checks[1].kind, "diagnostics")
end)

test("reviewer rejects passing checks and bounded repair rechecks", function()
  local reviews, checks = 0, 0
  local _, report = await(function(cb)
    return require("rose.native.agent").run(
      config({ agent = { max_repair_rounds = 1 }, checks = { unit = { cmd = { "true" } } } }),
      "task",
      cb,
      {
        tools = fake_tools(function(name)
          if name == "editor_check" then
            checks = checks + 1
          end
        end),
        backend = function(_, messages, _, done)
          if messages[1].content:find("independent", 1, true) then
            reviews = reviews + 1
            done(nil, {
              content = vim.json.encode({
                approved = reviews == 2,
                findings = reviews == 1 and { "fix bug" } or {},
                summary = "review",
              }),
            })
          else
            done(nil, { content = "done" })
          end
          return { cancel = function() end }
        end,
      }
    )
  end)
  equal(checks, 2)
  assert(type(report) == "table", "agent must return a report")
  equal(#report.attempts, 2)
  equal(report.attempts[1].verification.host_verified, true)
  equal(report.attempts[1].verification.review_approved, false)
  equal(report.attempts[1].verification.verified, false)
  equal(report.verification.verified, true)
  equal(report.review.approved, true)
end)

test("reviewer prose cannot approve or override verification", function()
  local _, report = await(function(cb)
    return require("rose.native.agent").run(
      config({ checks = { unit = { cmd = { "true" } } } }),
      "task",
      cb,
      {
        tools = fake_tools(),
        backend = function(_, _, _, done)
          done(nil, { content = "Looks perfect. All tests pass." })
          return { cancel = function() end }
        end,
      }
    )
  end)
  assert(type(report) == "table", "agent must return a report")
  equal(report.status, "unverified")
  equal(report.verification.host_verified, true)
  equal(report.verification.verified, false)
  equal(report.review.approved, false)
end)

test("edits during review make the validation evidence stale", function()
  vim.fn.writefile({ "value = 1" }, workspace .. "/review.py")
  vim.cmd("edit " .. vim.fn.fnameescape(workspace .. "/review.py"))
  local buffer = vim.api.nvim_get_current_buf()
  local _, report = await(function(cb)
    return require("rose.native.agent").run(
      config({ checks = { unit = { cmd = { "true" } } } }),
      "task",
      cb,
      {
        tools = fake_tools(),
        context_buf = buffer,
        backend = function(_, messages, _, done)
          if messages[1].content:find("independent", 1, true) then
            vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "value = 2" })
            done(nil, { content = '{"approved":true,"issues":[],"summary":"okay"}' })
          else
            done(nil, { content = "done" })
          end
          return { cancel = function() end }
        end,
      }
    )
  end)
  assert(type(report) == "table", "agent must return a report")
  equal(report.status, "stale")
  equal(report.verification.verified, false)
  vim.bo[buffer].modified = false
end)

test("reviewer transport errors cannot leave nested verification true", function()
  local err, report = await(function(cb)
    return require("rose.native.agent").run(
      config({ checks = { unit = { cmd = { "true" } } } }),
      "task",
      cb,
      {
        tools = fake_tools(),
        backend = function(_, messages, _, done)
          if messages[1].content:find("independent", 1, true) then
            done("fixture backend failed")
          else
            done(nil, { content = "done" })
          end
          return { cancel = function() end }
        end,
      }
    )
  end)
  assert(err and err:find("fixture backend failed", 1, true))
  assert(type(report) == "table", "agent failure must include a report")
  equal(report.status, "error")
  equal(report.verification.verified, false)
  equal(report.verified, false)
end)

test("agent loop bound is explicit and unverified", function()
  local _, report = await(function(cb)
    return require("rose.native.agent").run(
      config({ agent = { max_iterations = 1 }, checks = { unit = { cmd = { "true" } } } }),
      "task",
      cb,
      {
        tools = fake_tools(),
        backend = function(_, _, _, done)
          done(nil, {
            tool_calls = { { ["function"] = { name = "file_read", arguments = { path = "a" } } } },
          })
          return { cancel = function() end }
        end,
      }
    )
  end)
  assert(type(report) == "table", "agent must return a report")
  equal(report.status, "unverified")
  equal(report.verification.verified, false)
  equal(#report.tool_calls, 3)
end)

test("agent cancellation completes once and ignores late model output", function()
  local model_cb, count = nil, 0
  local token = require("rose.native.agent").run(config(), "task", function(err)
    equal(err, "cancelled")
    count = count + 1
  end, {
    tools = fake_tools(),
    backend = function(_, _, _, cb)
      model_cb = cb
      return { cancel = function() end }
    end,
  })
  token.cancel()
  assert(type(model_cb) == "function", "backend must capture the model callback")
  model_cb(nil, { content = "too late" })
  assert(vim.wait(1000, function()
    return count == 1
  end))
  vim.wait(50, function()
    return false
  end)
  equal(count, 1)
end)

local port, http_process
test("local fixture starts", function()
  local stdout = ""
  http_process = vim.system({ "python3", fixture, "http" }, {
    stdout = function(_, data)
      if data then
        stdout = stdout .. data
        port = tonumber(stdout:match("(%d+)\n"))
      end
    end,
  })
  assert(vim.wait(3000, function()
    return port ~= nil
  end))
end)

test("safe auto HTTP and actual vim.net request signatures work", function()
  for _, provider in ipairs({ "rose", "ollama" }) do
    local transports = provider == "rose" and { "auto", "curl" } or { "auto", "curl", "native" }
    for _, transport in ipairs(transports) do
      local cfg = config({
        providers = { provider = provider },
        [provider] = { base_url = "http://127.0.0.1:" .. port, transport = transport },
      })
      local err, message = await(function(cb)
        return require("rose.native.model").chat(
          cfg,
          { { role = "user", content = 'quotes " and newline\n' } },
          nil,
          cb
        )
      end)
      assert(not err, err)
      assert(type(message) == "table", "local backend must return a message")
      equal(message.content, "native HTTP okay")
    end
  end
end)

test("HTTP rejects remote defaults, redirects, invalid JSON and failures", function()
  for _, item in ipairs({
    { url = "https://example.com", expected = "allow_remote" },
    { url = "http://127.0.0.1:" .. port .. "/redirect", expected = "302" },
    { url = "http://127.0.0.1:" .. port .. "/bad", expected = "invalid Ollama JSON" },
    { url = "http://127.0.0.1:" .. port .. "/status", expected = "HTTP failed" },
  }) do
    local err = await(function(cb)
      return require("rose.native.ollama").chat(
        config({ ollama = { base_url = item.url } }).ollama,
        {},
        nil,
        cb
      )
    end)
    assert(err and err:find(item.expected, 1, true), tostring(err))
  end
end)

test("safe transport ignores local curl configuration", function()
  local curl_home = workspace .. "/curl"
  vim.fn.mkdir(curl_home)
  vim.fn.writefile({ 'output = "' .. workspace .. '/must-not-exist"' }, curl_home .. "/.curlrc")
  local previous = vim.env.CURL_HOME
  vim.env.CURL_HOME = curl_home
  local err, message = await(function(cb)
    return require("rose.native.ollama").chat(
      config({ ollama = { base_url = "http://127.0.0.1:" .. port } }).ollama,
      {},
      nil,
      cb
    )
  end)
  vim.env.CURL_HOME = previous
  assert(not err, err)
  assert(type(message) == "table", "Ollama must return a message")
  equal(message.content, "native HTTP okay")
  equal(vim.fn.filereadable(workspace .. "/must-not-exist"), 0)
end)

test("HTTP deadlines and cancellation are once-only", function()
  local http = require("rose.native.http")
  local err = await(function(cb)
    return http.request(
      { url = "http://127.0.0.1:" .. port .. "/slow", body = "{}", timeout = 40 },
      cb
    )
  end)
  assert(err and (err:find("timeout", 1, true) or err:find("28", 1, true)))
  local count = 0
  local token = http.request(
    { url = "http://127.0.0.1:" .. port .. "/slow", body = "{}" },
    function(e)
      equal(e, "cancelled")
      count = count + 1
    end
  )
  token.cancel()
  assert(vim.wait(1000, function()
    return count == 1
  end))
  vim.wait(100, function()
    return false
  end)
  equal(count, 1)
  equal(next(http.active), nil)
end)

local function connect(case, extra)
  return await(function(cb)
    return require("rose.native.mcp").start(
      vim.tbl_extend("force", {
        cmd = { "python3", fixture, "mcp", "--case", case or "normal" },
        initialize_timeout = 500,
      }, extra or {}),
      cb
    )
  end)
end

test("real MCP initialization, partial newline framing, list and call", function()
  local err, client = connect("partial")
  assert(not err, err)
  assert(type(client) == "table", "MCP initialization must return a client")
  equal(client.protocol_version, "2025-11-25")
  local list_err, listed = await(function(cb)
    return client:list_tools(cb)
  end)
  assert(not list_err, list_err)
  assert(type(listed) == "table", "MCP list_tools must return a result")
  equal(listed.tools[1].name, "echo")
  local call_err, result = await(function(cb)
    return client:call_tool("echo", {}, cb)
  end)
  assert(not call_err, call_err)
  assert(type(result) == "table", "MCP call_tool must return a result")
  equal(result.structuredContent.status, "ok")
  client:close()
  assert(vim.wait(2000, function()
    return client.exited
  end))
end)

test("MCP refuses incompatible version, malformed stdout and init timeout", function()
  for _, case in ipairs({ "version", "malformed", "initialize_hang" }) do
    local err, _, client = connect(case)
    assert(err, case)
    assert(type(client) == "table", "failed initialization must retain its client")
    assert(client.closed)
  end
end)

test("MCP unsupported server requests get method-not-found errors", function()
  local err, client = connect()
  assert(not err, err)
  assert(type(client) == "table", "MCP initialization must return a client")
  local call_err, result = await(function(cb)
    return client:call_tool("server_request", {}, cb)
  end)
  assert(not call_err, call_err)
  assert(type(result) == "table", "MCP call_tool must return a result")
  equal(result.structuredContent.rejected.code, -32601)
  client:close()
end)

test("MCP timeout cancellation and shutdown clear pending callbacks", function()
  local err, client = connect()
  assert(not err, err)
  assert(type(client) == "table", "MCP initialization must return a client")
  local timeout_err = await(function(cb)
    return client:call_tool("slow", {}, cb, 40)
  end)
  assert(timeout_err and timeout_err:find("timeout", 1, true))
  local cancelled_err = await(function(cb)
    local token = client:call_tool("slow", {}, cb)
    token.cancel()
    return token
  end)
  equal(cancelled_err, "cancelled")
  local close_err = await(function(cb)
    local token = client:call_tool("slow", {}, cb)
    client:close()
    return token
  end)
  equal(close_err, "MCP client closed")
  equal(next(client.pending), nil)
  assert(vim.wait(2000, function()
    return client.exited
  end))
end)

test("MCP process exit surfaces an error", function()
  local err, client = connect()
  assert(not err, err)
  assert(type(client) == "table", "MCP initialization must return a client")
  local call_err = await(function(cb)
    return client:call_tool("exit", {}, cb)
  end)
  assert(call_err and call_err:find("exited (3)", 1, true), call_err)
end)

test("third-party servers require separate explicit trust and allowlist", function()
  local servers = require("rose.native.servers")
  servers.setup(config({
    mcp = {
      servers = {
        denied = { cmd = { "must-not-execute" } },
        fixture = {
          cmd = { "python3", fixture, "mcp" },
          trusted = true,
          read_only = true,
          allow_tools = { "echo" },
        },
      },
    },
  }))
  local err = await(function(cb)
    return servers.call("denied", "echo", {}, cb)
  end)
  assert(err and err:find("explicit trusted", 1, true))
  local denied = await(function(cb)
    return servers.call("fixture", "other", {}, cb)
  end)
  assert(denied and denied:find("allow_tools", 1, true))
  local allowed, result = await(function(cb)
    return servers.call("fixture", "echo", {}, cb)
  end)
  assert(not allowed, allowed)
  assert(type(result) == "table", "allowed server call must return a result")
  equal(result.structuredContent.status, "ok")
  servers.stop()
end)

test("Flow passes private native bridge workspace and trust flags", function()
  local flow = require("rose.native.flow")
  flow.setup(config({ flow = { cmd = { "python3", fixture, "mcp" } } }))
  local err, report = await(function(cb)
    return flow.call("flow_status", {}, cb)
  end)
  assert(not err, err)
  assert(type(report) == "table", "Flow must return a status report")
  equal(report.workspace, uv.fs_realpath(workspace))
  equal(report.trusted, true)
  assert(report.nvim:match("/rose%-[^/]+/nvim.sock$"), report.nvim)
  local bridge = require("rose.native.bridge")
  equal(assert(uv.fs_stat(bridge.directory)).mode % 512, 448)
  local socket, directory = bridge.socket, bridge.directory
  flow.stop()
  equal(uv.fs_stat(socket), nil)
  equal(uv.fs_stat(directory), nil)
  assert(vim.wait(2000, function()
    return not flow.stopping
  end))
end)

test("Flow untrusted mode does not pass trusted or implicit socket when disabled", function()
  local flow = require("rose.native.flow")
  flow.setup(
    config({ trusted = false, flow = { cmd = { "python3", fixture, "mcp" }, bridge = false } })
  )
  local err, report = await(function(cb)
    return flow.call("flow_status", {}, cb)
  end)
  assert(not err, err)
  assert(type(report) == "table", "Flow must return a status report")
  equal(report.trusted, false)
  equal(report.nvim, vim.NIL)
  flow.stop()
  assert(vim.wait(2000, function()
    return not flow.stopping
  end))
end)

test("requested Flow bridge fails closed without spawning a subprocess", function()
  local flow, bridge, mcp =
    require("rose.native.flow"), require("rose.native.bridge"), require("rose.native.mcp")
  local actual_start, actual_mcp = bridge.start, mcp.start
  local spawned = false
  bridge.start = function()
    return nil, "fixture socket failure"
  end
  mcp.start = function()
    spawned = true
    error("must not spawn")
  end
  local ok, failure = pcall(function()
    flow.setup(config({ flow = { cmd = { "python3", fixture, "mcp" }, bridge = true } }))
    local err = await(function(cb)
      return flow.call("flow_run", { task = "task" }, cb)
    end)
    assert(err and err:find("bridge required", 1, true))
    equal(spawned, false)
    equal(flow.bridge_error, "fixture socket failure")
  end)
  bridge.start, mcp.start = actual_start, actual_mcp
  assert(ok, failure)
end)

test("Flow timeout confirms process exit before completing", function()
  local flow = require("rose.native.flow")
  flow.setup(
    config({ flow = { cmd = { "python3", fixture, "mcp", "--case", "stubborn" }, timeout = 40 } })
  )
  local client
  local err = await(function(cb)
    local token = flow.call("slow", {}, function(call_err, result)
      assert(client, "Flow must capture its client before completing")
      assert(client.exited, "timeout callback ran before the server process exited")
      equal(require("rose.native.bridge").socket, nil)
      cb(call_err, result)
    end)
    client = flow.client
    return token
  end)
  assert(err and err:find("timeout", 1, true), err)
  equal(flow.stopping, nil)
end)

test("Flow cancellation retains writer ownership until server exit", function()
  local rose, flow = require("rose"), require("rose.native.flow")
  assert(rose.setup({
    workspace = workspace,
    trusted = true,
    flow = { cmd = { "python3", fixture, "mcp", "--case", "stubborn" }, timeout = 3000 },
  }))
  local completed, final_err = false, nil
  local token = rose.flow("task", function(err)
    final_err, completed = err, true
  end)
  assert(token, "Flow must start the first writing workflow")
  assert(vim.wait(2000, function()
    return flow.client and flow.client.ready
  end))
  local client = assert(flow.client, "Flow must retain its ready client until cancellation")
  token.cancel()
  assert(rose.writer, "cancellation released writer before exit")
  assert(not completed, "cancellation completion was premature")
  local rejected
  rose.agent("second writer", function(err)
    rejected = err
  end)
  assert(type(rejected) == "string" and rejected:find("writing workflow", 1, true))
  assert(vim.wait(2500, function()
    return completed
  end))
  equal(final_err, "cancelled")
  assert(client.exited)
  equal(rose.writer, nil)
  rose.shutdown()
end)

test("model-facing debug tools cannot launch configured probes", function()
  local launched, round = false, 0
  local tools = fake_tools(function(name)
    if name == "editor_debug" then
      launched = true
    end
  end)
  local old_schemas = tools.schemas
  tools.schemas = function()
    local schemas = old_schemas()
    schemas[#schemas + 1] = {
      type = "function",
      ["function"] = {
        name = "editor_debug",
        parameters = {
          type = "object",
          properties = { action = { type = "string", enum = { "status", "run" } } },
        },
      },
    }
    return schemas
  end
  local _, report = await(function(cb)
    return require("rose.native.agent").run(config(), "task", cb, {
      tools = tools,
      backend = function(_, messages, schemas, done)
        local coder = messages[1].content:find("only writing", 1, true)
        if coder then
          for _, schema in ipairs(schemas) do
            if schema["function"].name == "editor_debug" then
              equal(schema["function"].parameters.properties.action.enum, { "status" })
            end
          end
          round = round + 1
        end
        if coder and round == 1 then
          done(nil, {
            tool_calls = {
              {
                id = "debug",
                ["function"] = {
                  name = "editor_debug",
                  arguments = { action = "run", name = "probe" },
                },
              },
            },
          })
        elseif messages[1].content:find("independent", 1, true) then
          done(nil, { content = '{"approved":false,"issues":[],"summary":"unverified"}' })
        else
          done(nil, { content = "done" })
        end
        return { cancel = function() end }
      end,
    })
  end)
  equal(launched, false)
  assert(type(report) == "table", "agent must return a report")
  equal(report.tool_calls[1].result.status, "error")
end)

test("scratch UI reuses buffer and restores native lifecycle", function()
  local ui = require("rose.native.ui")
  local source = vim.api.nvim_get_current_buf()
  local buffer = ui.open()
  ui.append("Test", "First\nSecond")
  equal(ui.open(), buffer)
  equal(vim.bo[buffer].buftype, "nofile")
  equal(vim.bo[buffer].modifiable, false)
  equal(vim.api.nvim_get_current_buf(), source)
  ui.close()
  assert(not vim.api.nvim_buf_is_valid(buffer))
end)

test("public commands preserve source context and chat history", function()
  local rose, adapter = require("rose"), require("rose.native.rose")
  local actual_tools, actual_chat = package.loaded["rose.tools"], adapter.chat
  local observed, source, request_messages = {}, nil, {}
  local tools = fake_tools(function(name, _args)
    if name:match("^editor_") then
      observed[#observed + 1] = vim.api.nvim_get_current_buf()
    end
  end)
  tools.setup = function() end
  package.loaded["rose.tools"] = tools
  adapter.chat = function(_, messages, _, cb)
    request_messages[#request_messages + 1] = vim.deepcopy(messages)
    local review = messages[1].content:find("independent", 1, true)
    vim.schedule(function()
      cb(nil, {
        content = review and '{"approved":true,"issues":[],"summary":"okay"}' or "fixture response",
      })
    end)
    return { cancel = function() end }
  end
  local ok, failure = pcall(function()
    vim.fn.writefile({ "value = 1" }, workspace .. "/source.py")
    vim.cmd("edit " .. vim.fn.fnameescape(workspace .. "/source.py"))
    vim.bo.filetype = "python"
    source = vim.api.nvim_get_current_buf()
    assert(rose.setup({
      workspace = workspace,
      trusted = true,
      agent = { max_cycles = 1 },
      checks = { python = { cmd = { "true" }, kind = "lint", filetypes = { "python" } } },
    }))
    vim.cmd("RoseAgent inspect the current file")
    assert(vim.wait(3000, function()
      return not rose.writer
    end))
    assert(#observed > 0)
    for _, buffer in ipairs(observed) do
      equal(buffer, source)
    end
    equal(vim.api.nvim_get_current_buf(), source)
    local err, text = await(function(cb)
      return rose.ask("first", cb)
    end)
    assert(not err, err)
    equal(text, "fixture response")
    local err2 = await(function(cb)
      return rose.ask("second", cb)
    end)
    assert(not err2, err2)
    local last = request_messages[#request_messages]
    equal(last[#last - 2].content, "first")
    equal(last[#last - 1].role, "assistant")
    equal(last[#last].content, "second")
    rose.shutdown()
  end)
  package.loaded["rose.tools"], adapter.chat = actual_tools, actual_chat
  assert(ok, failure)
end)

test("public writing workflows exclude concurrent writers and stop cancels", function()
  local rose, adapter = require("rose"), require("rose.native.rose")
  local actual_tools, actual_chat = package.loaded["rose.tools"], adapter.chat
  local tools = fake_tools()
  tools.setup = function() end
  package.loaded["rose.tools"] = tools
  local model_cancelled, callback_error
  adapter.chat = function()
    return {
      cancel = function()
        model_cancelled = true
      end,
    }
  end
  local ok, failure = pcall(function()
    assert(rose.setup({ workspace = workspace }))
    rose.agent("one", function(err)
      callback_error = err
    end)
    assert(rose.writer)
    local flow_error
    rose.flow("two", function(err)
      flow_error = err
    end)
    assert(flow_error:find("writing workflow", 1, true))
    rose.stop()
    assert(vim.wait(1000, function()
      return callback_error ~= nil
    end))
    equal(callback_error, "cancelled")
    equal(model_cancelled, true)
    equal(rose.writer, nil)
    rose.shutdown()
  end)
  package.loaded["rose.tools"], adapter.chat = actual_tools, actual_chat
  assert(ok, failure)
end)

require("rose").shutdown()
if http_process then
  http_process:kill(15)
  http_process:wait(1000)
end
require("rose.native.mcp").stop()
vim.wait(600, function()
  return false
end)
print(("%d core tests passed; %d failed"):format(passed, #failures))
if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
