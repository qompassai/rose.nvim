local M = {}

function M.open()
  if M.buffer and vim.api.nvim_buf_is_valid(M.buffer) then
    if not M.window or not vim.api.nvim_win_is_valid(M.window) then
      local source_window = vim.api.nvim_get_current_win()
      vim.cmd("botright 14split")
      M.window = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(M.window, M.buffer)
      vim.api.nvim_set_current_win(source_window)
    end
    return M.buffer
  end
  M.buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(M.buffer, "rose://chat")
  vim.bo[M.buffer].buftype = "nofile"
  vim.bo[M.buffer].bufhidden = "hide"
  vim.bo[M.buffer].swapfile = false
  vim.bo[M.buffer].filetype = "markdown"
  vim.bo[M.buffer].modifiable = false
  local source_window = vim.api.nvim_get_current_win()
  vim.cmd("botright 14split")
  M.window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.window, M.buffer)
  vim.wo[M.window].wrap = true
  vim.api.nvim_set_current_win(source_window)
  vim.keymap.set("n", "q", function()
    if M.window and vim.api.nvim_win_is_valid(M.window) and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(M.window, true)
    end
  end, { buffer = M.buffer, desc = "Hide Rose chat" })
  vim.keymap.set("n", "<C-c>", function()
    require("rose").stop()
  end, { buffer = M.buffer, desc = "Stop Rose" })
  vim.keymap.set("n", "i", function()
    require("rose").ask()
  end, { buffer = M.buffer, desc = "Ask Rose" })
  return M.buffer
end

function M.append(label, text)
  local buffer = M.open()
  text = tostring(text or ""):gsub("\r", "")
  local lines = vim.split("\n## " .. label .. "\n\n" .. text, "\n", { plain = true })
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, -1, -1, false, lines)
  -- Bound long-running chat output in memory.
  local count = vim.api.nvim_buf_line_count(buffer)
  if count > 10000 then
    vim.api.nvim_buf_set_lines(buffer, 0, count - 10000, false, {})
  end
  vim.bo[buffer].modifiable = false
  if M.window and vim.api.nvim_win_is_valid(M.window) then
    vim.api.nvim_win_set_cursor(M.window, { vim.api.nvim_buf_line_count(buffer), 0 })
  end
end

function M.close()
  if M.window and vim.api.nvim_win_is_valid(M.window) and #vim.api.nvim_list_wins() > 1 then
    pcall(vim.api.nvim_win_close, M.window, true)
  end
  if M.buffer and vim.api.nvim_buf_is_valid(M.buffer) then
    pcall(vim.api.nvim_buf_delete, M.buffer, { force = true })
  end
  M.buffer, M.window = nil, nil
end

return M
