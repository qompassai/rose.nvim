-- Language-agnostic, plugin-free, synchronous tool boundary for Rose and Flow.
local M = {}
local w = require("rose.tooling.workspace")
local lsp = require("rose.tooling.lsp")
local checks = require("rose.tooling.checks")
local lint = require("rose.tooling.lint")
local scip = require("rose.tooling.scip")
local files = require("rose.tooling.files")
local discovery = require("rose.tooling.discovery")
local debug = require("rose.tooling.debug")

function M.setup(opts)
  opts = opts or {}
  w.setup(opts)
  lint.reset()
  discovery.setup(opts)
  local ok, native_debug = pcall(require, "rose.debug")
  if ok and type(native_debug.setup) == "function" then
    native_debug.setup(
      vim.tbl_extend("force", opts, { workspace = w.state().root, trusted = w.state().trusted })
    )
  end
  return M
end

local function context(args)
  local snapshot = w.capture(args, true)
  local clients = lsp.describe(snapshot)
  return {
    status = "ok",
    workspace = w.state().root,
    trusted = w.state().trusted,
    path = snapshot.path,
    bufnr = snapshot.bufnr,
    filetype = snapshot.filetype,
    changedtick = snapshot.changedtick,
    modified = snapshot.modified,
    loaded = snapshot.loaded,
    dirty_buffers = w.dirty(),
    workspace_snapshot = w.snapshot(snapshot.path),
    workspace_snapshot_version = 1,
    lsp = { status = #clients > 0 and "unverified" or "unavailable", clients = clients },
    lint = lint.describe(snapshot),
    checks = checks.list(snapshot.filetype),
    scip = scip.describe(),
    debug = debug.registry(snapshot),
    diver = discovery.status(),
    verified = false,
    safety = "Workspace trust permits explicitly configured executable code; it is not an OS "
      .. "sandbox. No project configuration is automatically sourced.",
  }
end

local path = {
  type = "string",
  description = "Workspace-relative path. Omit to capture current editor buffer.",
}
local timeout = {
  type = "integer",
  minimum = 1,
  maximum = 120000,
  description = "Total completion deadline in milliseconds.",
}
local specs = {
  {
    "editor_context",
    "Discover captured buffer, live LSP capabilities, native linters and named relevant "
      .. "checks; absence is not verification.",
    context,
    { path = path },
  },
  {
    "editor_diagnostics",
    "Read native diagnostic snapshot; empty diagnostics never imply a completed verification.",
    lsp.diagnostics,
    { path = path },
  },
  {
    "editor_symbols",
    "Request document symbols from capable attached native LSP clients, with a bounded shared "
      .. "deadline.",
    lsp.symbols,
    { path = path, timeout = timeout },
  },
  {
    "editor_references",
    "Request references from capable attached native LSP clients with per-client encoding.",
    lsp.references,
    {
      path = path,
      timeout = timeout,
      line = { type = "integer", minimum = 1, description = "1-based line." },
      column = {
        type = "integer",
        minimum = 0,
        description = "0-based UTF-8 byte column, not character count.",
      },
      include_declaration = { type = "boolean" },
    },
  },
  {
    "editor_lint",
    "Run dynamically configured Diver native linters and wait for structured completion. "
      .. "Requires trust.",
    lint.run,
    { path = path, timeout = timeout },
  },
  {
    "editor_check",
    "Run an explicitly configured relevant named argv check, or aggregate all relevant checks "
      .. "if name is omitted. Requires trust and saved buffers.",
    checks.run,
    {
      path = path,
      name = {
        type = "string",
        description = "Configured check name from editor_context.checks; no argv accepted.",
      },
    },
  },
  {
    "editor_scip",
    "Query an existing decoded SCIP JSON index. No raw protobuf decoding, index generation or "
      .. "completeness guarantee.",
    scip.query,
    {
      path = path,
      action = { type = "string", enum = { "status", "symbols", "query" } },
      query = { type = "string", description = "Literal symbol/display-name substring." },
      symbol = {
        type = "string",
        description = "Exact symbol identifier. Supply path to disambiguate local symbols.",
      },
      limit = { type = "integer", minimum = 1, maximum = 1000 },
    },
  },
  {
    "editor_debug",
    "Discover debug capability and status. An optional native Rose bridge may run only "
      .. "explicitly configured named probes; never arbitrary adapter commands.",
    debug.call,
    {
      path = path,
      action = { type = "string", enum = { "status", "run" } },
      name = { type = "string" },
    },
  },
  {
    "file_read",
    "Read a workspace text file, preferring the live buffer including unsaved changes. "
      .. "Returns hash and changedtick.",
    files.read,
    { path = path },
    { "path" },
  },
  {
    "file_write",
    "Atomically write a workspace text file; refuses unsaved/read-only buffers. Requires "
      .. "trust; parents must already exist.",
    files.write,
    {
      path = path,
      content = { type = "string" },
      expected_sha256 = { type = "string" },
      expected_changedtick = { type = "integer", minimum = 0 },
    },
    { "path", "content" },
  },
  {
    "file_list",
    "List one workspace directory without following unsafe symlinks; no recursive traversal.",
    files.list,
    { path = path, limit = { type = "integer", minimum = 1, maximum = 1000 } },
  },
}
local by_name = {}
for _, spec in ipairs(specs) do
  by_name[spec[1]] = spec
end

function M.schemas()
  local result = {}
  for _, spec in ipairs(specs) do
    result[#result + 1] = {
      type = "function",
      ["function"] = {
        name = spec[1],
        description = spec[2],
        parameters = {
          type = "object",
          properties = vim.deepcopy(spec[4]),
          required = spec[5] or {},
          additionalProperties = false,
        },
      },
    }
  end
  return result
end

local function validate(args, spec)
  assert(type(args) == "table", "tool arguments must be an object")
  for key, value in pairs(args) do
    local schema = spec[4][key]
    assert(schema, "unknown argument: " .. tostring(key))
    assert(
      type(value) == (schema.type == "integer" and "number" or schema.type),
      "invalid type for " .. key
    )
    if schema.type == "integer" then
      assert(
        value == math.floor(value)
          and value >= (schema.minimum or -math.huge)
          and value <= (schema.maximum or math.huge),
        "invalid range for " .. key
      )
    end
    if schema.enum then
      assert(vim.tbl_contains(schema.enum, value), "invalid value for " .. key)
    end
  end
  for _, key in ipairs(spec[5] or {}) do
    assert(args[key] ~= nil, "missing required argument: " .. key)
  end
end

-- Exclude handles, callbacks, metatables and cyclic state from the RPC boundary.
local function serializable(value, seen, depth)
  if value == vim.NIL then
    return vim.NIL
  end
  local kind = type(value)
  if kind == "nil" or kind == "boolean" or kind == "string" then
    return value
  end
  if kind == "number" then
    return value == value and value ~= math.huge and value ~= -math.huge and value or nil
  end
  if kind ~= "table" or depth > 40 or seen[value] then
    return nil
  end
  seen[value] = true
  local result = vim.islist(value) and {} or vim.empty_dict()
  for key, item in pairs(value) do
    if type(key) == "string" or type(key) == "number" then
      result[key] = serializable(item, seen, depth + 1)
    end
  end
  seen[value] = nil
  return result
end

function M.call(name, args)
  local ok, result = pcall(function()
    local spec = by_name[name]
    assert(spec, "unknown tool: " .. tostring(name))
    args = args or {}
    validate(args, spec)
    return serializable(spec[3](args), {}, 0)
  end)
  if not ok then
    return { status = "error", error = tostring(result) }
  end
  return result
end

return M
