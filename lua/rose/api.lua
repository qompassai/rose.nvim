local M = {}

function M.pkey(id)
  local handle = io.popen("pass show " .. id .. " 2>/dev/null")
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()
  return result and vim.trim(result) or nil
end

return M

