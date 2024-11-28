local M = {}

M.did_setup = false

local default_opts = {
  providers = { "ollama" },
}

---@param opts? table
function M.setup(opts)
  if M.did_setup then
    return
  end
  M.did_setup = true

  opts = vim.tbl_deep_extend("force", default_opts, opts or {})

  require("rose.config").setup(opts)
end

return M
