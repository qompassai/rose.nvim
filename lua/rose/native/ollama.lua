-- Explicit compatibility adapter; preserves the original chat API and wire format.
local M = {}

function M.chat(config, messages, tools, callback)
  return require("rose.native.local_chat").chat(config, "ollama", messages, tools, callback)
end

return M
