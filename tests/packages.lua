-- Run via tests/package_fixture.py: fresh -u NONE processes and isolated XDG roots.
-- Never add Rose to runtimepath or require it before the real manager loads it.
local root = assert(vim.env.ROSE_PACKAGE_ROOT, "use the package fixture runner")
local lazy_root = vim.env.LAZY_ROOT
local mode = assert(arg[1], "package test mode is required")
local spec = assert(loadfile(root .. "/lazy.lua"))()
local commands = {
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
  "RoseDictate",
  "RoseSpeak",
  "RoseSpeechStop",
  "RoseSpeechStatus",
  "RoseWebUI",
  "RoseWebUIStop",
  "RoseWebUIStatus",
}
local violations = {}
local notifications = {}

local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end

local function unloaded()
  for name in pairs(package.loaded) do
    assert(not name:match("^rose[%.]?") and name ~= "rose_lib", "Rose loaded early: " .. name)
  end
  assert(not vim.g.loaded_rose_native, "Rose plugin sourced before manager load")
  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    assert(path ~= root, "test must not prepend the Rose repository")
  end
end

local function static_spec()
  assert(type(spec) == "table" and spec.main == "rose", "expected native root lazy.lua spec")
  equal(spec.dependencies, nil)
  equal(spec.build, nil)
  equal(spec.opts, { trusted = false })
  assert(type(spec.cmd) == "table", "root spec must declare command triggers")
  local seen = {}
  for _, name in ipairs(spec.cmd) do
    assert(type(name) == "string" and not seen[name], "invalid or duplicate command trigger")
    seen[name] = true
  end
  for _, name in ipairs(commands) do
    assert(seen[name], "root lazy.lua is missing command trigger " .. name)
  end
end

local function forbidden(label)
  return function()
    violations[#violations + 1] = label
    error("unexpected setup side effect: " .. label)
  end
end

local function safety_guards()
  vim.system = forbidden("vim.system")
  vim.uv.spawn = forbidden("uv.spawn")
  vim.uv.new_tcp = forbidden("TCP socket")
  vim.uv.new_udp = forbidden("UDP socket")
  vim.fn.system = forbidden("system")
  vim.fn.systemlist = forbidden("systemlist")
  vim.fn.jobstart = forbidden("jobstart")
  vim.fn.termopen = forbidden("termopen")
  os.execute = forbidden("os.execute")
  io.popen = forbidden("io.popen")
  -- Manager/runtime discovery may read these public paths, never credential names.
  local allowed =
    { VIMRUNTIME = true, NVIM_APPNAME = true, PATH = true, HOME = true, APPIMAGE = true }
  local environment = {}
  for key in pairs(allowed) do
    environment[key] = vim.env[key]
  end
  local function getenv(key)
    assert(type(key) == "string", "environment key must be a string")
    if not allowed[key] then
      forbidden("environment/credential read: " .. key)()
    end
    return environment[key]
  end
  vim.env = setmetatable({}, {
    __index = function(_, key)
      return getenv(key)
    end,
  })
  os.getenv, vim.fn.getenv, vim.uv.os_getenv = getenv, getenv, getenv
  for _, name in ipairs({
    "plenary",
    "plenary.curl",
    "plenary.job",
    "fzf-lua",
    "nui",
    "nvim-treesitter",
    "rose.api",
    "rose.legacy.init",
    "rose.legacy.config",
    "rose.binary",
    "rose.rose",
    "rose.tokenizers",
    "rose_lib",
  }) do
    package.preload[name] = forbidden("legacy/native build dependency " .. name)
  end
  vim.notify = function(message, level)
    notifications[#notifications + 1] = tostring(message)
    if level == vim.log.levels.ERROR then
      violations[#violations + 1] = "error notification: " .. tostring(message)
    end
  end
end

local function custom_opts()
  return {
    workspace = assert(vim.uv.cwd()),
    ollama = { model = "offline-package-fixture", timeout = 4321 },
    agent = { max_iterations = 2 },
    speech = { max_text_chars = 512 },
    webui = { open = false, max_clients = 2 },
  }
end

local function check_ready(custom)
  local rose = require("rose")
  assert(rose.did_setup and not rose.legacy and vim.g.loaded_rose_native)
  equal(rose.tool_error, nil)
  equal(rose.webui_error, nil)
  local options = rose.options
  equal(options.workspace, assert(vim.uv.cwd()))
  equal(options.trusted, false)
  equal(options.legacy, false)
  equal(options.providers, { enabled = false, allow_cloud = false, provider = "ollama" })
  equal(options.ollama.allow_remote, false)
  equal(options.ollama.base_url, "http://127.0.0.1:11434")
  equal(options.ollama.model, custom and "offline-package-fixture" or "qwen2.5-coder:7b")
  equal(options.speech.enabled, false)
  equal(options.webui.enabled, false)
  equal(options.webui.host, "127.0.0.1")
  equal(options.webui.port, 0)
  equal(options.mcp.servers, {})
  if custom then
    equal(options.ollama.timeout, 4321)
    equal(options.agent.max_iterations, 2)
    equal(options.speech.max_text_chars, 512)
    equal(options.webui.open, false)
    equal(options.webui.max_clients, 2)
  end
  local registered = vim.api.nvim_get_commands({})
  for _, name in ipairs(commands) do
    assert(registered[name], "missing exposed command " .. name)
  end
  for name in pairs(registered) do
    if name:match("^Rose") then
      assert(vim.tbl_contains(spec.cmd, name), "exposed command has no lazy trigger: " .. name)
    end
  end
  equal(#vim.api.nvim_get_autocmds({ group = "RoseNative" }), 1)
  equal(#vim.api.nvim_get_autocmds({ group = "RoseWebUI" }), 1)
  equal(rose.operations, {})
  equal(require("rose.speech").active, {})
  equal(require("rose.webui").status().running, false)
  equal(require("rose.hub").status().state, "idle")
end

local function lifecycle(custom)
  check_ready(custom)
  local rose = require("rose")
  assert(rose.setup(custom_opts()))
  assert(rose.setup(custom_opts()))
  check_ready(true)
  rose.shutdown()
  rose.shutdown()
  equal(rose.did_setup, false)
  equal(rose.operations, {})
  equal(vim.fn.exists("#RoseNative"), 0)
  equal(vim.fn.exists("#RoseWebUI"), 0)
  assert(rose.setup(custom_opts()))
  check_ready(true)
  rose.shutdown()
  -- Include scheduled manager callbacks in the safety window, not only sync setup.
  vim.wait(30, function()
    return false
  end, 5)
  equal(violations, {})
end

local function pack_install()
  assert(type(vim.pack) == "table", "test-packages requires Neovim with vim.pack.add")
  -- Real local Git installation only; Python overlays the current tree afterwards.
  vim.pack.add(
    { { src = "file://" .. root, name = "rose.nvim" } },
    { load = false, confirm = false }
  )
  unloaded()
  local installed = vim.pack.get({ "rose.nvim" })[1]
  assert(installed and installed.active and vim.fn.isdirectory(installed.path .. "/.git") == 1)
end

local function pack_load()
  safety_guards()
  -- Already installed and overlaid, but loading is exclusively vim.pack.add's job.
  vim.pack.add(
    { { src = "file://" .. root, name = "rose.nvim" } },
    { load = true, confirm = false }
  )
  assert(package.loaded.rose and vim.g.loaded_rose_native, "vim.pack did not source Rose")
  local actual = debug.getinfo(require("rose").setup, "S").source
  assert(actual:find("/site/pack/core/opt/rose.nvim/", 1, true), "loaded wrong Rose tree")
  assert(require("rose").setup(custom_opts()))
  lifecycle(true)
end

local function lazy_load()
  assert(lazy_root and vim.fn.isdirectory(lazy_root .. "/lua/lazy") == 1, "LAZY_ROOT is required")
  vim.opt.rtp:prepend(lazy_root)
  local lazy = require("lazy")
  local eager = mode == "lazy-eager"
  spec.dir = root
  if eager then
    -- Equivalent to the README's lazy=false/opts form, using the live root spec.
    spec.lazy = false
    spec.opts = vim.tbl_deep_extend("force", spec.opts, custom_opts())
  end
  safety_guards()
  lazy.setup({ spec }, {
    local_spec = false,
    pkg = { enabled = false },
    rocks = { enabled = false },
    install = { missing = false },
    checker = { enabled = false },
    change_detection = { enabled = false },
    readme = { enabled = false },
    performance = { cache = { enabled = false }, rtp = { reset = true } },
  })
  if not eager then
    unloaded()
    local trigger = mode == "lazy-speech" and "RoseSpeechStatus" or "RoseWebUIStatus"
    local registered = vim.api.nvim_get_commands({})
    assert(registered[trigger], "lazy.nvim did not install trigger " .. trigger)
    local before = #notifications
    vim.cmd(trigger)
    assert(#notifications > before, "lazy command was loaded but not replayed")
    local status = table.concat(notifications, "\n", before + 1)
    local expected = mode == "lazy-speech" and "recording: false" or "running = false"
    assert(status:find(expected, 1, true), "wrong status command output: " .. status)
  end
  assert(package.loaded.rose, "lazy.nvim did not load Rose")
  local plugins = require("lazy.core.config").plugins
  assert(plugins["rose.nvim"]._.loaded, "Rose was not loaded by lazy.nvim")
  for name in pairs(plugins) do
    assert(name == "rose.nvim" or name == "lazy.nvim", "unexpected dependency " .. name)
  end
  lifecycle(eager)
end

local ok, failure = xpcall(function()
  unloaded()
  vim.go.loadplugins = true -- -u NONE disables plugin sourcing; lazy requires it enabled.
  if mode == "static" then
    static_spec()
  elseif mode == "pack-install" then
    pack_install()
  elseif mode == "pack-load" then
    pack_load()
  else
    assert(mode == "lazy-speech" or mode == "lazy-webui" or mode == "lazy-eager", "unknown mode")
    lazy_load()
  end
end, debug.traceback)
if not ok then
  io.stderr:write(tostring(failure) .. "\n")
  vim.cmd("cquit 1")
end
print("PASS " .. mode)
vim.cmd("qa!")
