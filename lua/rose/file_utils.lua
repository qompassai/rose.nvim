--/qompassai/rose.nvim/lua/file_utils.lua
-- --------------------------------------------
-- Copyright (C) 2025 Qompass AI, All rights reserved
local logger = require("rose.logger")
local utils = require("rose.utils")
local M = {}
---@param file_path string
---@return table | nil
M.file_to_table = function(file_path)
  local status, file, err = pcall(io.open, file_path, "r")
  if not status or not file then
    logger.error("Failed to open file: " .. file_path .. "\nError: " .. (err or "Unknown error"))
    return nil
  end
  local content, content_err = file:read("*a")
  file:close()
  if not content or content == "" then
    logger.error(
      "Failed to read content from file: " .. file_path .. (content_err and ("\nError: " .. content_err) or "")
    )
    return nil
  end
  local decode_status, result = pcall(vim.json.decode, content)
  if not decode_status then
    logger.error("JSON decoding failed for file: " .. file_path .. "\nError: " .. result)
    return nil
  end
  return result
end

--- @param tbl table
--- @param file_path string
M.table_to_file = function(tbl, file_path)
  local file = io.open(file_path, "w")
  if not file then
    logger.error(string.format("Failed to open file for writing: %s", file_path))
    return
  end
  local ok, json_str = pcall(vim.json.encode, tbl)
  if not ok then
    logger.error("Failed to encode table to JSON.")
    file:close()
    return
  end
  local write_ok, write_err = pcall(function()
    file:write(json_str)
  end)
  if not write_ok then
    logger.error(string.format("Failed to write data to file: %s", write_err))
    file:close()
    return
  end
  file:close()
end

---@return string
M.find_git_root = function()
  local cwd = vim.fn.expand("%:p:h")
  while cwd ~= "" do
    if vim.fn.isdirectory(cwd .. "/.git") == 1 then
      return cwd
    end
    local parent = vim.fn.fnamemodify(cwd, ":h")
    if parent == cwd then
      break
    end
    cwd = parent
  end
  return ""
end
---@return string
M.find_repo_instructions = function()
  local git_root = M.find_git_root()
  if git_root == "" then
    return ""
  end
  local instruct_file = git_root .. "/.rose.md"
  if vim.fn.filereadable(instruct_file) == 1 then
    local lines = vim.fn.readfile(instruct_file)
    return table.concat(lines, "\n")
  end
  return ""
end
---@param file string | nil
---@param target_dir string
M.delete_file = function(file, target_dir)
  if not file then
    logger.error("No file specified for deletion.")
    return
  end
  if file:match(target_dir) == nil then
    logger.error("File '" .. file .. "' not in target directory.")
    return
  end
  utils.delete_buffer(file)
  if not os.remove(file) then
    logger.error("Error: Failed to delete file '" .. file .. "'.")
  end
end
--- @param path string
--- @return string
M.read_file = function(path)
  local file = io.open(path, "r")
  if not file then
    return ""
  end
  local content = file:read("*a")
  file:close()
  return content
end
--- @param path string
--- @param content string
--- @return boolean
M.write_file = function(path, content)
  local file = io.open(path, "w")
  if not file then
    return false
  end
  file:write(content)
  file:close()
  return true
end
return M
