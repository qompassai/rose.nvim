--/qompassai/rose.nvim/lua/tokenizers.lua
-- --------------------------------------------
-- Copyright (C) 2025 Qompass AI, All rights reserved
local Utils = require("rose.utils")

---@class RoseTokenizer
---@field from_pretrained fun(model: string): nil
---@field encode fun(string): integer[]
local tokenizers = nil
local M = {}
---@param model "gpt-4o" | string
---@param warning? boolean
M.setup = function(model, warning)
  warning = warning or true
  vim.defer_fn(function()
    local ok, core = pcall(require, "rose_tokenizers")
    if not ok then
      return
    end
    ---@cast core RoseTokenizer
    if tokenizers == nil then
      tokenizers = core
    end
    core.from_pretrained(model)
  end, 1000)
  if warning then
    local HF_TOKEN = os.getenv("HF_TOKEN")
    if HF_TOKEN == nil and model ~= "gpt-4o" then
      Utils.warn(
        "Please set HF_TOKEN environment variable to use HuggingFace tokenizer if " .. model .. " is gated",
        { once = true }
      )
    end
  end
end

M.available = function()
  return tokenizers ~= nil
end
---@param prompt string
M.encode = function(prompt)
  if not tokenizers then
    return nil
  end
  if not prompt or prompt == "" then
    return nil
  end
  if type(prompt) ~= "string" then
    error("Prompt is not type string", 2)
  end
  return tokenizers.encode(prompt)
end
---@param prompt string
M.count = function(prompt)
  if not tokenizers then
    return math.ceil(#prompt * 0.5)
  end
  local tokens = M.encode(prompt)
  if not tokens then
    return 0
  end
  return #tokens
end
return M
