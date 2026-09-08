local M = {}
local discovery = require("rose.tooling.discovery")

function M.registry(snapshot)
  -- Diver's dap module calls setup() on import. Never require it for discovery.
  local dap = package.loaded.dap
  local registry
  if type(dap) == "table" and type(dap.registry) == "function" then
    local ok, value = pcall(dap.registry)
    if ok and type(value) == "table" then
      registry = value
    end
  end
  local adapters, configurations = {}, {}
  for name, _ in pairs(registry and registry.adapters or {}) do
    adapters[#adapters + 1] = name
  end
  for _, config in
    ipairs(
      registry and registry.configurations and registry.configurations[snapshot.filetype] or {}
    )
  do
    configurations[#configurations + 1] =
      { name = config.name, type = config.type, request = config.request }
  end
  table.sort(adapters)
  return {
    status = registry and "unverified" or "unavailable",
    loaded = registry ~= nil,
    adapters = adapters,
    configurations = configurations,
    candidate_modules = discovery.files("lua/dap"),
    native_vim_debug_present = type(rawget(vim, "debug")) == "table",
    verified = false,
    reason = "Registry definitions and filenames are discovery only. No vim.debug methods are "
      .. "assumed or called.",
  }
end

function M.call(args)
  local w = require("rose.tooling.workspace")
  local snapshot = w.capture(args, true)
  local available, bridge = pcall(require, "rose.debug")
  if available and type(bridge.call) == "function" then
    if args.action == "run" then
      w.require_trust()
      w.resolve(".")
    end
    local result = bridge.call(args)
    result.diver = M.registry(snapshot)
    return result
  end
  return {
    status = "unavailable",
    verified = false,
    diver = M.registry(snapshot),
    reason = "No native DAP bridge is configured. Debug launch must be performed manually.",
  }
end

return M
