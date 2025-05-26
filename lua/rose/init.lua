--/qompassai/rose.nvim/lua/init.lua
-- --------------------------------
-- Copyright (C) 2025 Qompass AI, All rights reserved
local M = {}
M.did_setup = false
local binary_ok, binary = pcall(require, "rose.binary")
if not binary_ok then
  binary = nil
end
---@param opts? table
function M.setup(opts)
  opts = opts or {}
  if binary then
    binary.init()
  end
  local ok, rose_binary = pcall(require, "rose.rose")
  if ok then
    rose_binary.init()
  else
    vim.notify("Failed to load rose module: " .. tostring(rose_binary), vim.log.levels.WARN)
  end
  M.did_setup = true
  require("rose.config").setup(opts)
  vim.api.nvim_create_user_command("RoseDownload", function()
    local rose = require("rose.rose")
    rose.rose_dl()
  end, { desc = "Download Rose" })
end
function M.rose_check()
  local ok, rose = pcall(require, "rose.rose")
  if ok then
    return rose.rose_exists()
  end
  return false
end
function M.get_binary_path()
  if binary then
    return binary.get_binary_path()
  end
  local ok, rose = pcall(require, "rose.rose")
  if ok and rose.rose_exists then
    local exists, path = rose.rose_exists()
    if exists then
      return path
    end
  end
  return nil
end
return M
