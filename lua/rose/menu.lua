-- --/qompassai/rose.nvim/lua/menu.lua
-- --------------------------------------------
-- Copyright (C) 2025 Qompass AI, All rights reserved
local config = require("rose.config")
local M = {}
local function update_option(key, value)
  config.options[key] = value
  vim.notify("🌹 rose.nvim: Set " .. key .. " = " .. vim.inspect(value), vim.log.levels.INFO)
end
local editable_options = {
  "toggle_target",
  "chat_user_prefix",
  "llm_prefix",
  "user_input_ui",
  "style_popup_border",
  "enable_spinner",
}
function M.open()
  vim.ui.select(editable_options, {
    prompt = "🌹 Choose config option to change:",
  }, function(option)
    if not option then
      return
    end
    local current_value = config.options[option]
    local prompt = string.format("Set new value for `%s` (current: %s):", option, vim.inspect(current_value))
    vim.ui.input({ prompt = prompt, default = tostring(current_value) }, function(input)
      if input ~= nil then
        local casted = input
        if input == "true" then
          casted = true
        elseif input == "false" then
          casted = false
        elseif tonumber(input) then
          casted = tonumber(input)
        end
        update_option(option, casted)
      end
    end)
  end)
end
return M
