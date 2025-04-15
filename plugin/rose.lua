-- rose.nvim/plugin/rose.lua

-- Runtime behavior, e.g., commands and diagnostics
vim.api.nvim_create_user_command("RoseConfig", function()
  require("rose.menu").open()
end, {})

for _, name in ipairs({ "curl", "grep", "rg", "ln" }) do
  if vim.fn.executable(name) == 0 then
    vim.notify(name .. " is not installed, run :checkhealth rose", vim.log.levels.ERROR)
  end
end

