-- --/qompassai/rose.nvim/lua/menu.lua
-- --------------------------------------------
-- Copyright (C) 2025 Qompass AI, All rights reserved
local M = {}
---@param options table<string, string|number|boolean>
---@param key string
---@param value string|number|boolean
local function update_option(options, key, value)
  options[key] = value
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
  -- This menu edits historical options, not native configuration. Do not load legacy
  -- dependencies just to display it when legacy mode has not been initialized.
  local config = package.loaded["rose.legacy.config"]
  if type(config) ~= "table" or not config.loaded or type(config.options) ~= "table" then
    vim.notify("Rose legacy configuration is not loaded", vim.log.levels.WARN)
    return
  end
  local options = config.options
  vim.ui.select(editable_options, {
    prompt = "🌹 Choose config option to change:",
  }, function(option)
    if not option then
      return
    end
    local current_value = options[option]
    local prompt =
      string.format("Set new value for `%s` (current: %s):", option, vim.inspect(current_value))
    vim.ui.input({ prompt = prompt, default = tostring(current_value) }, function(input)
      if input ~= nil then
        ---@type string|number|boolean
        local casted = input
        local numeric = tonumber(input)
        if input == "true" then
          casted = true
        elseif input == "false" then
          casted = false
        elseif numeric then
          casted = numeric
        end
        update_option(options, option, casted)
      end
    end)
  end)
end
return M
