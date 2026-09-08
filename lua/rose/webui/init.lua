-- Local web UI entrypoint: configuration defaults, validation and user commands.
-- Everything network-facing lives in rose.webui.server; this module only wires
-- the commands and the browser hand-off.
local M = {}
local server = require("rose.webui.server")

M.defaults = server.defaults
M.validate = server.validate

local command_names = { "RoseWebUI", "RoseWebUIStop", "RoseWebUIStatus" }

local function notify(message, level)
  vim.notify("Rose web UI: " .. message, level or vim.log.levels.INFO)
end

--- Resolve the webui section defensively: until config.lua wiring lands the
--- section may be absent, in which case the documented defaults apply.
function M.section(fullconfig)
  assert(type(fullconfig) == "table", "section requires the full configuration")
  local section = fullconfig.webui
  if section == nil then
    section = vim.deepcopy(M.defaults)
  end
  return M.validate(vim.tbl_deep_extend("keep", section, M.defaults))
end

--- Start the server (idempotent) and optionally open the browser.
--- Returns the URL or nil, error. Operating failures are returned, not raised.
function M.start(opts)
  opts = opts or {}
  assert(type(opts) == "table", "start options must be a table")
  local fullconfig = M.config
  if fullconfig == nil then
    return nil, "not configured; call require('rose.webui').setup(config) first"
  end
  local section = M.section(fullconfig)
  if section.enabled ~= true then
    return nil, "disabled; set webui.enabled=true to serve the local page"
  end
  local already_running = server.state ~= nil
  local state, start_error = server.start(fullconfig)
  if not state then
    return nil, start_error
  end
  local url = server.url()
  assert(type(url) == "string")
  local should_open = opts.open
  if should_open == nil then
    should_open = section.open and not already_running
  end
  if should_open then
    local opened, open_error = pcall(vim.ui.open, url)
    if not opened then
      local why = "cannot open browser (" .. tostring(open_error) .. "); URL: " .. url
      notify(why, vim.log.levels.WARN)
    end
  end
  return url
end

function M.stop()
  server.stop()
end

function M.status()
  return server.status()
end

function M.register_commands()
  vim.api.nvim_create_user_command("RoseWebUI", function()
    local url, err = M.start()
    if not url then
      notify(err, vim.log.levels.ERROR)
      return
    end
    notify("serving " .. url)
  end, { desc = "Start the local Rose web UI and open it in the browser", force = true })
  vim.api.nvim_create_user_command("RoseWebUIStop", function()
    M.stop()
    notify("stopped")
  end, { desc = "Stop the local Rose web UI and close all client connections", force = true })
  vim.api.nvim_create_user_command("RoseWebUIStatus", function()
    vim.notify(vim.inspect(M.status()))
  end, { desc = "Show local Rose web UI status (includes the session URL)", force = true })
end

--- Configure the module with the full Rose configuration and register commands.
--- Safe to call again: a running server keeps serving the old configuration
--- until :RoseWebUIStop, because the bound token belongs to that session.
function M.setup(fullconfig)
  assert(type(fullconfig) == "table", "webui.setup requires the full Rose configuration")
  M.section(fullconfig) -- Validate eagerly so bad settings fail at setup time.
  M.config = fullconfig
  M.register_commands()
  local group = vim.api.nvim_create_augroup("RoseWebUI", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.stop })
  return M
end

function M.shutdown()
  M.stop()
  for _, name in ipairs(command_names) do
    pcall(vim.api.nvim_del_user_command, name)
  end
  pcall(vim.api.nvim_del_augroup_by_name, "RoseWebUI")
  M.config = nil
end

return M
