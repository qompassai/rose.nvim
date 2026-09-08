-- Offline boundary regressions: no real recorder, provider, Hub transfer or model.
local root = vim.env.ROSE_TEST_ROOT
  or vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local uv = vim.uv
local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")
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

local function patched(target, key, replacement, fn)
  local previous = target[key]
  target[key] = replacement
  local ok, err = xpcall(fn, debug.traceback)
  target[key] = previous
  assert(ok, err)
end

local function unavailable()
  return nil, "fixture unavailable"
end

local function no_spawn()
  error("must not start a process")
end

local function rejected(start, expected)
  local calls, failure = 0, nil
  local token = start(function(err)
    calls, failure = calls + 1, err
  end)
  assert(
    vim.wait(1000, function()
      return calls > 0
    end, 0),
    "callback was not delivered"
  )
  assert(type(failure) == "string" and failure:find(expected, 1, true), tostring(failure))
  if token and token.cancel then
    token.cancel()
  end
  vim.wait(10, function()
    return false
  end, 0)
  assert(calls == 1, "callback must complete exactly once")
end

test("config reports a vanished workspace instead of indexing nil", function()
  patched(uv, "fs_stat", unavailable, function()
    local ok, err = pcall(require("rose.config").resolve, { workspace = workspace })
    assert(not ok and tostring(err):find("workspace must be a directory", 1, true), tostring(err))
  end)
end)

test("tooling reports a vanished root instead of indexing nil", function()
  patched(uv, "fs_stat", unavailable, function()
    local ok, err = pcall(require("rose.tooling.workspace").setup, { workspace = workspace })
    assert(not ok and tostring(err):find("existing directory", 1, true), tostring(err))
  end)
end)

test("HTTP timer allocation fails before spawning and clears active requests", function()
  local http = require("rose.native.http")
  patched(uv, "new_timer", unavailable, function()
    patched(vim, "system", no_spawn, function()
      rejected(function(cb)
        return http.request({ url = "http://127.0.0.1:1" }, cb)
      end, "timer")
    end)
  end)
  assert(next(http.active) == nil)
end)

test("HTTP handles unavailable optional vim.net", function()
  local http = require("rose.native.http")
  patched(package.loaded, "vim.net", nil, function()
    patched(package.preload, "vim.net", function()
      error("fixture module missing")
    end, function()
      rejected(function(cb)
        return http.request({ url = "http://127.0.0.1:1", transport = "native" }, cb)
      end, "unavailable")
    end)
  end)
  assert(next(http.active) == nil)
end)

test("HTTP rejects native nil handle and error", function()
  patched(package.loaded, "vim.net", { request = unavailable }, function()
    rejected(function(cb)
      return require("rose.native.http").request({
        url = "http://127.0.0.1:1",
        transport = "native",
      }, cb)
    end, "fixture unavailable")
  end)
end)

test("HTTP rejects native success callback without a response", function()
  patched(package.loaded, "vim.net", {
    request = function(_, _, _, cb)
      cb(nil, nil)
      return { close = function() end }
    end,
  }, function()
    rejected(function(cb)
      return require("rose.native.http").request({
        url = "http://127.0.0.1:1",
        transport = "native",
      }, cb)
    end, "response")
  end)
end)

test("HTTP rejects a native transport returning neither a handle nor an error", function()
  patched(package.loaded, "vim.net", {
    request = function()
      return nil
    end,
  }, function()
    rejected(function(cb)
      return require("rose.native.http").request({
        url = "http://127.0.0.1:1",
        transport = "native",
      }, cb)
    end, "HTTP start failed")
  end)
end)

test("HTTP closes a handle returned after synchronous completion", function()
  local closed, completed = false, false
  patched(package.loaded, "vim.net", {
    request = function(_, _, _, cb)
      cb(nil, { body = "{}" })
      return {
        close = function()
          closed = true
        end,
      }
    end,
  }, function()
    require("rose.native.http").request({
      url = "http://127.0.0.1:1",
      transport = "native",
    }, function(err, body)
      assert(err == nil and body == "{}")
      completed = true
    end)
    assert(vim.wait(1000, function()
      return completed
    end))
    assert(closed)
  end)
end)

test("web server handles listener allocation failure", function()
  local server = require("rose.webui.server")
  patched(uv, "new_tcp", unavailable, function()
    local state, err = server.start({ webui = server.defaults })
    assert(not state and type(err) == "string" and err:find("TCP", 1, true), tostring(err))
  end)
  assert(server.state == nil)
end)

test("web server closes a listener with no local address", function()
  local server = require("rose.webui.server")
  local closed = false
  patched(uv, "new_tcp", function()
    return {
      bind = function()
        return 0
      end,
      listen = function()
        return 0
      end,
      getsockname = unavailable,
      close = function()
        closed = true
      end,
    }
  end, function()
    local state, err = server.start({ webui = server.defaults })
    assert(not state and err == "cannot get TCP listener address")
  end)
  assert(closed and server.state == nil)
end)

for _, operation in ipairs({ "record", "play", "piper" }) do
  test(operation .. " timer failure never starts an audio process", function()
    local path = workspace .. "/audio.wav"
    vim.fn.writefile({ string.rep("a", 64) }, path)
    patched(uv, "new_timer", unavailable, function()
      patched(vim, "system", no_spawn, function()
        rejected(function(cb)
          if operation == "record" then
            return require("rose.speech.audio").record({ "fixture-recorder" }, path, 1, cb)
          elseif operation == "play" then
            return require("rose.speech.audio").play({ "fixture-player" }, path, cb)
          end
          return require("rose.speech.piper").speak({ "fixture-piper" }, "text", path, cb)
        end, "timer")
      end)
    end)
  end)
end

test("recorder stop timer failure kills the process and completes once", function()
  local killed = {}
  patched(vim, "system", function()
    return {
      kill = function(_, signal)
        killed[#killed + 1] = signal
      end,
    }
  end, function()
    rejected(function(cb)
      local token = require("rose.speech.audio").record(
        { "fixture-recorder" },
        workspace .. "/stopped.wav",
        1,
        cb
      )
      patched(uv, "new_timer", unavailable, function()
        token.stop()
      end)
      return token
    end, "recorder stop timer")
  end)
  assert(vim.deep_equal(killed, { 2, 9 }))
end)

test("provider timer failure closes and removes the output sink", function()
  local transport = require("rose.providers.transport")
  local path = workspace .. "/response.wav"
  patched(uv, "new_timer", unavailable, function()
    patched(vim, "system", no_spawn, function()
      rejected(function(cb)
        return transport.request({
          endpoint = "http://127.0.0.1:1",
          path = "/test",
          body = "{}",
          credential_host = "127.0.0.1:1",
          allow_insecure_local = true,
          output_path = path,
        }, cb)
      end, "timer")
    end)
  end)
  assert(next(transport.active) == nil)
  assert(uv.fs_stat(path) == nil)
end)

test("provider output open failure returns an error without spawning", function()
  patched(uv, "fs_open", unavailable, function()
    patched(vim, "system", no_spawn, function()
      rejected(function(cb)
        return require("rose.providers.transport").request({
          endpoint = "http://127.0.0.1:1",
          path = "/test",
          body = "{}",
          credential_host = "127.0.0.1:1",
          allow_insecure_local = true,
          output_path = workspace .. "/missing/response.wav",
        }, cb)
      end, "response file")
    end)
  end)
end)

test("file helpers return their documented sentinel for missing files", function()
  local files = require("rose.file_utils")
  assert(files.read_file(workspace .. "/missing") == "")
  assert(files.write_file(workspace .. "/missing/file", "data") == false)
end)

test("file helpers report read and write failures and close handles", function()
  local files = require("rose.file_utils")
  local closed = 0
  patched(io, "open", function()
    return {
      read = unavailable,
      write = unavailable,
      close = function()
        closed = closed + 1
        return true
      end,
    }
  end, function()
    assert(files.read_file("fixture") == "")
    assert(files.write_file("fixture", "data") == false)
  end)
  assert(closed == 2)
end)

for _, failure in ipairs({ "missing", "open", "stat", "load", "module", "shape" }) do
  test("optional Diver lint registry handles " .. failure .. " failure", function()
    local w = require("rose.tooling.workspace")
    local discovery = require("rose.tooling.discovery")
    local lint = require("rose.tooling.lint")
    local dir = workspace .. "/diver-" .. failure
    vim.fn.mkdir(dir .. "/lua/linters", "p")
    if failure ~= "missing" then
      vim.fn.writefile({
        "local M = {}",
        "M.completion_api_version = 1",
        failure == "module" and 'require("rose_fixture_missing_module")'
          or failure == "shape" and "return nil"
          or "return M",
      }, dir .. "/lua/linters/init.lua")
    end
    w.setup({ workspace = workspace, trusted = true })
    discovery.setup({ diver = { path = dir }, trusted = false })
    lint.reset()
    local function check()
      local result = lint.describe({ filetype = "lua" })
      assert(result.status == "unavailable", vim.inspect(result))
    end
    if failure == "open" then
      patched(uv, "fs_open", unavailable, check)
    elseif failure == "stat" then
      local closed, fs_close = 0, uv.fs_close
      patched(uv, "fs_close", function(fd)
        closed = closed + 1
        return fs_close(fd)
      end, function()
        patched(uv, "fs_fstat", unavailable, check)
      end)
      assert(closed == 1, "failed fstat must still close the descriptor")
    elseif failure == "load" then
      patched(_G, "loadfile", unavailable, check)
    else
      check()
    end
  end)
end

test("MCP timer failure completes initialization once and kills without a kill timer", function()
  local mcp = require("rose.native.mcp")
  local writes, signals = {}, {}
  patched(vim, "system", function()
    return {
      write = function(_, data)
        writes[#writes + 1] = data or "EOF"
      end,
      kill = function(_, signal)
        signals[#signals + 1] = signal
      end,
    }
  end, function()
    patched(uv, "new_timer", unavailable, function()
      rejected(function(cb)
        return mcp.start({ cmd = { "fixture" } }, cb)
      end, "timer")
    end)
  end)
  assert(vim.deep_equal(signals, { 15, 9 }), vim.inspect(signals))
  assert(vim.deep_equal(writes, { "EOF" }), vim.inspect(writes))
  assert(next(mcp.clients) == nil)
end)

test("Flow timer failure keeps the writer fence until confirmed process exit", function()
  local flow = require("rose.native.flow")
  local client = { process = {}, exited = false, close = function() end }
  flow.client = client
  local completed = false
  patched(uv, "new_timer", unavailable, function()
    flow.stop(function()
      completed = true
    end)
  end)
  assert(not completed and flow.stopping, "writer fence released early")
  assert(type(client.on_exit) == "function", "exit observer was not installed")
  client.exited = true
  client.on_exit()
  assert(completed and not flow.stopping, "confirmed exit must release writer fence")
end)

test("Flow rejects malformed MCP content without throwing", function()
  local flow = require("rose.native.flow")
  local client = {
    ready = true,
    call_tool = function(_, _, _, cb)
      cb(nil, { content = { true, { type = "text" } } })
    end,
    close = function() end,
  }
  flow.config = { flow = { timeout = 100 } }
  flow.client = client
  rejected(function(cb)
    return flow.call("fixture", {}, cb)
  end, "JSON report")
end)

test("Hub timer allocation failure clears ownership without starting the helper", function()
  local hub = require("rose.hub")
  hub.setup({ workspace = workspace, timeout_ms = 1000 })
  patched(uv, "new_timer", unavailable, function()
    patched(vim, "system", no_spawn, function()
      rejected(function(cb)
        return hub.paper({ id = "fixture" }, cb)
      end, "timer")
    end)
  end)
  assert(not hub.status().active)
end)

-- A fake listener invokes the real connection handler without opening a socket.
local function fake_listener(run)
  local server = require("rose.webui.server")
  local connected
  local listener = {
    bind = function()
      return 0
    end,
    listen = function(_, _, cb)
      connected = cb
      return 0
    end,
    getsockname = function()
      return { ip = "127.0.0.1", port = 12345 }
    end,
    accept = function()
      return 0
    end,
    is_closing = function()
      return false
    end,
    close = function() end,
  }
  patched(uv, "new_tcp", function()
    return listener
  end, function()
    local state = assert(server.start({ webui = server.defaults }))
    local ok, err = xpcall(function()
      assert(connected, "listener callback must be installed")
      run(state, connected)
    end, debug.traceback)
    server.stop()
    assert(ok, err)
  end)
end

test("TCP accept allocation failure leaves no client state", function()
  fake_listener(function(state, connected)
    patched(uv, "new_tcp", unavailable, function()
      connected(nil)
    end)
    assert(state.client_count == 0)
  end)
end)

for _, failure in ipairs({ "timer", "peer", "read", "write" }) do
  test("TCP " .. failure .. " failure closes the accepted handle", function()
    fake_listener(function(state, connected)
      local closed, on_read = false, nil
      local handle = {
        getpeername = function()
          if failure ~= "peer" then
            return { ip = "127.0.0.1", port = 12345 }
          end
        end,
        is_closing = function()
          return closed
        end,
        close = function()
          closed = true
        end,
        read_start = function(_, cb)
          on_read = cb
          if failure ~= "read" then
            return 0
          end
        end,
        write = unavailable,
      }
      patched(uv, "new_tcp", function()
        return handle
      end, function()
        if failure == "timer" then
          patched(uv, "new_timer", unavailable, function()
            connected(nil)
          end)
        else
          connected(nil)
          if failure == "write" then
            assert(on_read, "accepted socket must start reading")
            on_read(nil, "INVALID\r\n\r\n")
          end
        end
      end)
      assert(closed and state.client_count == 0, "failed client must close immediately")
    end)
  end)
end

test("JSON file helpers reject scalar data and report nullable write failures", function()
  local files = require("rose.file_utils")
  local path = workspace .. "/scalar.json"
  vim.fn.writefile({ "false" }, path)
  local reports = {}
  patched(require("rose.logger"), "error", function(message)
    reports[#reports + 1] = message
  end, function()
    assert(files.file_to_table(path) == nil)
    local closed = false
    local file = {
      write = unavailable,
      close = function()
        closed = true
        return true
      end,
    }
    patched(io, "open", function()
      return file
    end, function()
      files.table_to_file({}, path)
    end)
    assert(closed and #reports == 2)
    assert(reports[2]:find("fixture unavailable", 1, true))
  end)
end)

test("repo instructions tolerate a file disappearing after readability check", function()
  local files = require("rose.file_utils")
  patched(files, "find_git_root", function()
    return workspace
  end, function()
    patched(vim.fn, "filereadable", function()
      return 1
    end, function()
      patched(vim.fn, "readfile", function()
        error("fixture missing file")
      end, function()
        assert(files.find_repo_instructions() == "")
      end)
    end)
  end)
end)

test("extension argument input works without the missing rose.utils.ui module", function()
  local utils = require("rose.extensions.utils")
  local result
  patched(vim.ui, "input", function(_, cb)
    cb("fixture value")
  end, function()
    utils.collect_arguments({ { name = "value", required = true } }, function(values)
      result = values.value
    end)
    assert(
      vim.wait(1000, function()
        return result ~= nil
      end),
      "input callback missing"
    )
  end)
  assert(result == "fixture value")
end)

test("extension optional input cancellation preserves an absent value", function()
  local completed = false
  patched(vim.ui, "input", function(_, cb)
    cb(nil)
  end, function()
    require("rose.extensions.utils").collect_arguments({ { name = "value" } }, function(values)
      assert(values.value == nil)
      completed = true
    end)
    assert(
      vim.wait(1000, function()
        return completed
      end),
      "cancel callback missing"
    )
  end)
end)

test("legacy extension delivers a nil resource response to its completion callback", function()
  local hub = {
    access_resource = function(_, _, _, options)
      options.callback(nil, "fixture failure")
    end,
  }
  patched(package.loaded, "rose", {
    get_hub_instance = function()
      return hub
    end,
    get = function()
      return {}
    end,
  }, function()
    patched(vim.g, "rose_auto_approve", true, function()
      local extension = require("rose.extensions.rose")
      extension.mcp_tool()
      local completed = false
      extension.access_mcp_resource.func(
        { server_name = "fixture", uri = "fixture" },
        nil,
        function(result, err)
          assert(result == nil and err == "fixture failure")
          completed = true
        end
      )
      assert(completed)
    end)
  end)
end)

vim.fn.delete(workspace, "rf")
print(string.format("%d passed, %d failed", passed, #failures))
if #failures > 0 then
  vim.cmd("cquit 1")
end
