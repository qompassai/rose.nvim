-- Private, same-user msgpack socket for the explicit Flow editor bridge.
local M = {}

function M.start()
  if M.socket then
    return M.socket
  end
  if not vim.fn.exists or vim.fn.exists("*serverstart") ~= 1 then
    return nil, "native Neovim RPC server unavailable"
  end
  local uv = vim.uv or vim.loop
  if uv.os_uname().sysname == "Windows_NT" then
    return nil,
      "private bridge currently requires Unix; flow.bridge=false explicitly opts out of "
        .. "editor protection"
  end
  local base = vim.fn.stdpath("run")
  local dir, err = uv.fs_mkdtemp(base .. "/rose-XXXXXX")
  if not dir then
    return nil, "cannot create private bridge directory: " .. tostring(err)
  end
  local chmod = uv.fs_chmod(dir, 448) -- 0700; socket alone is not an authorization boundary.
  if not chmod then
    uv.fs_rmdir(dir)
    return nil, "cannot make bridge directory private"
  end
  local path = dir .. "/nvim.sock"
  local ok, socket = pcall(vim.fn.serverstart, path)
  if not ok or socket == "" then
    uv.fs_rmdir(dir)
    return nil, "cannot start native editor bridge: " .. tostring(socket)
  end
  uv.fs_chmod(socket, 384) -- 0600
  M.directory, M.socket = dir, socket
  return socket
end

function M.stop()
  if M.socket then
    pcall(vim.fn.serverstop, M.socket)
  end
  local uv = vim.uv or vim.loop
  if M.socket then
    uv.fs_unlink(M.socket)
  end
  if M.directory then
    uv.fs_rmdir(M.directory)
  end
  M.socket, M.directory = nil, nil
end

return M
