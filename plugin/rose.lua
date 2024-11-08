for _, name in ipairs({ "curl", "grep", "rg", "ln" }) do
  if vim.fn.executable(name) == 0 then
    return vim.notify(name .. " is not installed, run :checkhealth rose", vim.log.levels.ERROR)
  end
end

local timer = vim.uv.new_timer()
timer:start(
  500,
  0,
  vim.schedule_wrap(function()
    local rose = require("rose")
    if not rose.did_setup then
      rose.setup()
    end
  end)
)
