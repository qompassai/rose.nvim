local M = {}

M.did_setup = false

---@param opts? table
function M.setup(opts)
  opts = opts or {}
  binary.init()
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

  local binary_path = binary.get_binary_path()
  if binary_path then

function M.rose_check()
  local rose = require("rose.rose")
  return rose.rose_exists()
end
end
return M

