local M = {}

M.did_setup = false

---@param opts? table
function M.setup(opts)
  if M.did_setup then
    return
  end
  M.did_setup = true

  require("rose.config").setup(opts)
end

return M

