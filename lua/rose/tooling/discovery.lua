local M = {}
local w = require("rose.tooling.workspace")
local uv = vim.uv or vim.loop
local root, lsp_setup = nil, {}

function M.setup(opts)
  root, lsp_setup = nil, {}
  if not opts.diver or not opts.diver.path then
    return
  end
  root = uv.fs_realpath(opts.diver.path)
  assert(root and uv.fs_stat(root).type == "directory", "diver.path must be an existing directory")
  if not opts.trusted then
    return
  end
  -- Appending runtimepath does not source Diver init.lua or its plugins.
  local paths = vim.opt.runtimepath:get()
  if not vim.tbl_contains(paths, root) then
    vim.opt.runtimepath:append(root)
  end
  for _, name in ipairs(opts.diver.lsp or {}) do
    local item = { name = name }
    if type(name) ~= "string" or not name:match("^[%w_-]+$") then
      item.status, item.error = "error", "invalid native LSP config name"
    elseif not vim.lsp.config or not vim.lsp.enable then
      item.status, item.reason = "unavailable", "native vim.lsp.config/enable require Neovim 0.11+"
    else
      local ok, err = pcall(function()
        -- Native merging uses existing user settings; Rose never calls config()
        -- with replacement values or resets an already configured client.
        if not vim.lsp.config[name] then
          error("named LSP configuration is absent")
        end
        vim.lsp.enable(name)
      end)
      item.status = ok and "unverified" or "unavailable"
      if not ok then
        item.error = tostring(err)
      end
    end
    lsp_setup[#lsp_setup + 1] = item
  end
end

function M.root()
  return root
end

-- Diver ships a handful of config files per directory; anything larger is not a Diver tree.
local directory_entries_max = 4096

function M.files(subdirectory)
  assert(type(subdirectory) == "string", "files: subdirectory must be a string")
  local list = {}
  if not root then
    return list
  end
  local path = root .. "/" .. subdirectory
  local actual = uv.fs_realpath(path)
  if not actual or not w.contains(root, actual) then
    return list
  end
  local scan = uv.fs_scandir(actual)
  if not scan then
    return list
  end
  -- A Diver config directory is small; refuse to enumerate more than this many entries.
  for _ = 1, directory_entries_max do
    local name, kind = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    if kind == "file" and name:match("%.lua$") and name ~= "init.lua" then
      list[#list + 1] = name:gsub("%.lua$", "")
    end
  end
  table.sort(list)
  return list
end

function M.status()
  return {
    status = root and "unverified" or "unavailable",
    path = root,
    native_lsp_configs = M.files("lsp"),
    requested_lsp = lsp_setup,
    reason = "Config filenames are discovery only, not proof of executable availability; only "
      .. "explicitly selected LSP configs are enabled.",
  }
end

return M
