-- Native qompassai/rose adapter: shared chat protocol, Rose-specific transport security.
local M = {}

function M.chat(config, messages, tools, callback)
  return require("rose.native.local_chat").chat(config, "rose", messages, tools, callback)
end

return M
