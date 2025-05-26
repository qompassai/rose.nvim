--/qompassai/rose.nvim/lua/state.lua
-- --------------------------------------------
-- Copyright (C) 2025 Qompass AI, All rights reserved
local futils = require("rose.file_utils")
local utils = require("rose.utils")

local State = {}
State.__index = State
--- @param state_dir string
--- @return table
function State:new(state_dir)
  local state_file = state_dir .. "/state.json"
  local file_state = vim.fn.filereadable(state_file) ~= 0 and futils.file_to_table(state_file) or {}
  return setmetatable({ state_file = state_file, file_state = file_state, _state = {} }, self)
end
--- @param available_providers table
function State:init_file_state(available_providers)
  if next(self.file_state) == nil then
    for _, prov in ipairs(available_providers) do
      self.file_state[prov] = { chat_model = nil, command_model = nil }
    end
  end
  self.file_state.current_provider = self.file_state.current_provider or { chat = "", command = "" }
end
--- @param available_providers table
--- @param available_models table
function State:init_state(available_providers, available_models)
  self._state.current_provider = self._state.current_provider or { chat = "", command = "" }
  for _, provider in ipairs(available_providers) do
    self._state[provider] = self._state[provider] or { chat_model = nil, command_model = nil }
    self:load_models(provider, "chat_model", available_models)
    self:load_models(provider, "command_model", available_models)
  end
end
--- @param provider string
--- @param model_type string
--- @param available_models table
function State:load_models(provider, model_type, available_models)
  if available_models[provider] == nil then
    vim.api.nvim_err_writeln("Provider '" .. provider .. "' not found in available_models.")
    return
  end
  local state_model = self.file_state and self.file_state[provider] and self.file_state[provider][model_type]
  local is_valid_model = state_model and utils.contains(available_models[provider], state_model)
  if self._state[provider][model_type] == nil then
    if state_model and is_valid_model then
      self._state[provider][model_type] = state_model
    else
      self._state[provider][model_type] = available_models[provider][1]
    end
  end
end
--- @param available_providers table
--- @param available_models table
function State:refresh(available_providers, available_models)
  self:init_file_state(available_providers)
  self:init_state(available_providers, available_models)
  local function set_current_provider(key)
    self._state.current_provider[key] = self._state.current_provider[key]
      or self.file_state.current_provider[key]
      or available_providers[1]
    if not utils.contains(available_providers, self._state.current_provider[key]) then
      self._state.current_provider[key] = available_providers[1]
    end
  end
  set_current_provider("chat")
  set_current_provider("command")
  self._state.last_chat = self._state.last_chat or self.file_state.last_chat or nil

  self:save()
end
function State:save()
  futils.table_to_file(self._state, self.state_file)
end
--- @param provider string
function State:set_provider(provider, is_chat)
  if is_chat then
    self._state.current_provider.chat = provider
  else
    self._state.current_provider.command = provider
  end
end
--- @return string|nil
function State:get_provider(is_chat)
  if is_chat then
    return self.file_state.current_provider.chat or self._state.current_provider.chat
  else
    return self.file_state.current_provider.command or self._state.current_provider.command
  end
end
--- @param provider string
--- @param model string
--- @param atype string
function State:set_model(provider, model, atype)
  if atype == "chat" then
    self._state[provider].chat_model = model
  elseif atype == "command" then
    self._state[provider].command_model = model
  end
end
--- @param provider string
--- @param model_type string
--- @return table|nil
function State:get_model(provider, model_type)
  local key = model_type .. "_model"
  return self._state[provider][key] or self.file_state[provider][key]
end
--- @param chat_file_path string
function State:set_last_chat(chat_file_path)
  self._state.last_chat = chat_file_path
end
--- @return string|nil
function State:get_last_chat()
  return self._state.last_chat
end
return State
