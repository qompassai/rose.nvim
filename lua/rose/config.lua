-- Native configuration. No provider, secret-store or project-local config reads.
local M = {}

---@type Rose.Config.Defaults
M.defaults = {
  legacy = false,
  trusted = false,
  rose = {
    base_url = "http://127.0.0.1:11434",
    model = "qwen2.5-coder:7b",
    timeout = 120000,
    allow_remote = false,
    transport = "auto",
    tls = {},
  },
  ollama = {
    base_url = "http://127.0.0.1:11434",
    model = "qwen2.5-coder:7b",
    timeout = 120000,
    allow_remote = false,
    -- auto prefers vim.net when it can enforce transport safety; see :help rose-http.
    transport = "auto",
  },
  providers = { enabled = false, allow_cloud = false, provider = "rose" },
  speech = {
    -- Master gate; cloud speech additionally requires providers.allow_cloud.
    enabled = false,
    stt = { provider = "auto", model = nil, language = "auto" },
    tts = { provider = "auto", model = nil, voice = nil, format = "mp3" },
    -- cmd is an argv table; nil detects pw-record/arecord/ffmpeg.
    record = { cmd = nil, max_seconds = 60 },
    play = { cmd = nil }, -- nil detects pw-play/paplay/aplay/mpv/ffplay
    whisper = { url = nil }, -- local whisper.cpp server, loopback http only
    piper = { cmd = nil, model = nil }, -- local piper TTS executable
    max_audio_bytes = 25 * 1024 * 1024,
    max_text_chars = 4096,
  },
  hub = { python = "python3", max_workers = 4, xet = "auto", high_performance = false },
  agent = {
    max_iterations = 6,
    max_repair_rounds = 1,
    max_tool_calls = 8,
    max_tool_result = 24000,
    max_context = 120000,
  },
  diver = { lsp = {} },
  debug = {},
  checks = {},
  scip = { path = "index.scip.json" },
  flow = { cmd = { "flow", "serve" }, timeout = 600000, bridge = true },
  mcp = { servers = {} },
  webui = {
    enabled = false,
    host = "127.0.0.1",
    port = 0,
    open = true,
    max_request_bytes = 16 * 1024 * 1024,
    max_clients = 8,
    idle_timeout_ms = 30000,
  },
}

-- The web UI must never be reachable from another machine, so only these hosts are accepted.
local loopback_hosts = { ["127.0.0.1"] = true, ["::1"] = true, ["localhost"] = true }

local function integer(value, lo, hi, name)
  assert(type(name) == "string", "integer(): name must be a string")
  assert(lo <= hi, "integer(): lo must not exceed hi")
  local range = name .. " must be an integer in " .. lo .. ".." .. hi
  assert(type(value) == "number", range)
  assert(value % 1 == 0, range)
  assert(value >= lo, range)
  assert(value <= hi, range)
end

-- Resolve the workspace root to a real, existing directory (absolute, no trailing slash).
local function resolve_workspace(configured)
  local uv = vim.uv or vim.loop
  local root = configured or uv.cwd()
  assert(type(root) == "string", "workspace must be a path")
  assert(root ~= "", "workspace must be a path")
  root = vim.fn.fnamemodify(root, ":p"):gsub("[/\\]+$", "")
  if root == "" then
    root = "/"
  end
  local real = assert(uv.fs_realpath(root), "workspace does not exist")
  local stat = uv.fs_stat(real)
  assert(stat and stat.type == "directory", "workspace must be a directory")
  return real
end

local function validate_webui(webui)
  assert(type(webui) == "table", "webui must be a table")
  assert(type(webui.enabled) == "boolean", "webui.enabled must be a boolean")
  assert(type(webui.open) == "boolean", "webui.open must be a boolean")
  assert(loopback_hosts[webui.host] == true, "webui.host must be a loopback address")
  integer(webui.port, 0, 65535, "webui.port")
  integer(webui.max_request_bytes, 4096, 268435456, "webui.max_request_bytes")
  integer(webui.max_clients, 1, 64, "webui.max_clients")
  integer(webui.idle_timeout_ms, 100, 600000, "webui.idle_timeout_ms")
end

-- Bound the number of named checks so a pathological config cannot stall startup.
local checks_max = 256

local function validate_checks(checks)
  assert(type(checks) == "table", "checks must be a table of named commands")
  local count = 0
  for name, check in pairs(checks) do
    count = count + 1
    assert(count <= checks_max, "checks must define at most " .. checks_max .. " entries")
    assert(type(name) == "string", "checks must be a table of named configurations")
    assert(type(check) == "table", "checks must be a table of named configurations")
    if check.filetypes ~= nil then
      assert(type(check.filetypes) == "table", "check.filetypes must be an array")
    end
  end
end

local function validate_local(section, name)
  assert(type(section) == "table", name .. " must be a configuration table")
  integer(section.timeout, 1, 3600000, name .. ".timeout")
  assert(type(section.model) == "string" and section.model ~= "", name .. ".model is required")
  assert(type(section.base_url) == "string", name .. ".base_url must be a string")
  assert(type(section.allow_remote) == "boolean", name .. ".allow_remote must be a boolean")
  assert(
    section.transport == "auto"
      or section.transport == "curl"
      or (name == "ollama" and section.transport == "native"),
    name .. ".transport must be auto or curl (native is Ollama-only)"
  )
  assert(
    section.options == nil or type(section.options) == "table",
    name .. ".options must be a table"
  )
end

---Merge native setup input and validate core bounds; invalid input raises an error.
---@param opts? Rose.Config
---@return Rose.Config.Resolved
function M.resolve(opts)
  opts = opts or {}
  assert(type(opts) == "table", "Rose setup options must be a table")
  local config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  assert(type(config.providers) == "table", "providers must be a configuration table")
  -- Preserve old Ollama-only overrides, including an explicitly empty section.
  -- Explicit provider always wins; with both sections present the default is Rose.
  if
    opts.ollama ~= nil
    and opts.rose == nil
    and (not opts.providers or opts.providers.provider == nil)
  then
    config.providers.provider = "ollama"
  end
  if opts.agent and opts.agent.max_cycles ~= nil then
    integer(opts.agent.max_cycles, 1, 4, "agent.max_cycles")
    if opts.agent.max_repair_rounds == nil then
      config.agent.max_repair_rounds = opts.agent.max_cycles - 1
    end
  end
  assert(type(config.trusted) == "boolean", "trusted must be a boolean")
  config.workspace = resolve_workspace(config.workspace)
  validate_local(config.rose, "rose")
  validate_local(config.ollama, "ollama")
  local tls_error = require("rose.native.http").validate_tls(config.rose.tls)
  assert(not tls_error, tls_error)
  integer(config.agent.max_iterations, 1, 30, "agent.max_iterations")
  integer(config.agent.max_repair_rounds, 0, 3, "agent.max_repair_rounds")
  config.agent.max_cycles = config.agent.max_repair_rounds + 1
  integer(config.agent.max_tool_calls, 1, 32, "agent.max_tool_calls")
  integer(config.agent.max_tool_result, 256, 1048576, "agent.max_tool_result")
  integer(config.agent.max_context, 1024, 4194304, "agent.max_context")
  integer(config.flow.timeout, 1, 3600000, "flow.timeout")
  validate_webui(config.webui)
  assert(type(config.providers.enabled) == "boolean", "providers.enabled must be a boolean")
  assert(type(config.providers.allow_cloud) == "boolean", "providers.allow_cloud must be a boolean")
  assert(type(config.hub) == "table", "hub must be a configuration table")
  assert(type(config.speech) == "table", "speech must be a configuration table")
  assert(type(config.speech.enabled) == "boolean", "speech.enabled must be a boolean")
  -- Full per-field validation (provider names, format, limits) lives with the module. The
  -- module may be absent from a partial install (the web UI tests hide it), so its absence is
  -- an operating condition, not a programmer error.
  local speech_ok, speech = pcall(require, "rose.speech")
  if speech_ok then
    speech.config(config)
  else
    -- Lua leaves a sentinel in package.loaded after a failed load, which would turn every later
    -- require into "loop or previous error"; clear it so the web UI can report the real reason.
    package.loaded["rose.speech"] = nil
  end
  validate_checks(config.checks)
  assert(type(config.workspace) == "string", "resolved workspace must be a string")
  -- The typed Defaults/input merge gains exactly two required fields here:
  -- validated real workspace and max_cycles derived from bounded max_repair_rounds.
  -- LuaLS does not refine a nominal parent class from those field assignments.
  ---@cast config Rose.Config.Resolved
  return config
end

---Resolve and publish native configuration; invalid input raises an error.
---@param opts? Rose.Config
---@return Rose.Config.Resolved
function M.setup(opts)
  M.options = M.resolve(opts)
  return M.options
end

return M
