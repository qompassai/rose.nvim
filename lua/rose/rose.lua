--/qompassai/rose.nvim/lua/rose.lua
-- --------------------------------------------
-- Copyright (C) 2025 Qompass AI, All rights reserved
local M = {}
M.install_paths = {
  ["nvim-data"] = vim.fn.stdpath("data") .. "/rose",
  ["local-bin"] = vim.fn.expand("~/.local/bin"),
  ["qompass"] = "/opt/Qompass/rose",
}
M.default_install_path = "nvim-data"
function M.detect_platform()
  local system = vim.loop.os_uname()
  local os_name = system.sysname
  local arch = system.machine
  local arch_map = {
    ["x86_64"] = "amd64",
    ["aarch64"] = "arm64",
    ["arm64"] = "arm64",
  }
  local normalized_arch = arch_map[arch] or arch
  if os_name == "Darwin" then
    return "darwin", normalized_arch
  elseif os_name == "Linux" then
    return "linux", normalized_arch
  elseif os_name:match("Windows") or os_name == "Windows_NT" then
    return "windows", normalized_arch
  else
    return os_name:lower(), normalized_arch
  end
end
function M.rose_exists()
  for name, path in pairs(M.install_paths) do
    local binary_name = "rose"
    if M.detect_platform() == "windows" then
      binary_name = binary_name .. ".exe"
    end
    local binary_path = path .. "/" .. binary_name
    if vim.fn.filereadable(binary_path) == 1 and vim.fn.executable(binary_path) == 1 then
      return true, binary_path
    end
  end
  return false, nil
end
function M.extract_archive(archive_path, extract_dir)
  local ext = archive_path:match("%.([^%.]+)$")
  local cmd = ""
  if ext == "gz" or ext == "tar.gz" or archive_path:match("%.tar%.gz$") then
    cmd = string.format("tar -xzf %s -C %s", archive_path, extract_dir)
  elseif ext == "zip" then
    cmd = string.format("unzip -o %s -d %s", archive_path, extract_dir)
  else
    return false, "Unsupported archive format"
  end
  local result = os.execute(cmd)
  return result == 0, result ~= 0 and "Extraction failed" or nil
end
function M.get_download_url()
  local os_name, arch = M.detect_platform()
  local base_url = "https://github.com/qompassai/rose/releases/download/v1.0.0"
  local file_ext = ""
  if os_name == "windows" then
    file_ext = ".zip"
  else
    file_ext = ".tar.gz"
  end
  local filename = string.format("rose-v1.0.0-%s-%s%s", os_name, arch, file_ext)
  return base_url .. "/" .. filename, filename
end
function M.rose_dl()
  vim.ui.select({ "Neovim Data Dir", "~/.local/bin", "/opt/Qompass/rose" }, {
    prompt = "Where would you like to install Rose?",
    format_item = function(item)
      if item == "Neovim Data Dir" then
        return "Neovim Data Dir (" .. M.install_paths["nvim-data"] .. ")"
      elseif item == "~/.local/bin" then
        return "~/.local/bin (User binaries)"
      else
        return "/opt/Qompass/rose (System-wide)"
      end
    end,
  }, function(choice)
    if not choice then
      vim.notify("Installation cancelled", vim.log.levels.INFO)
      return
    end
    local install_key = ""
    if choice == "Neovim Data Dir" then
      install_key = "nvim-data"
    elseif choice == "~/.local/bin" then
      install_key = "local-bin"
    else
      install_key = "qompass"
    end
    local install_dir = M.install_paths[install_key]
    if install_key == "qompass" and vim.fn.executable("sudo") ~= 1 then
      vim.notify("Installing to /opt/Qompass/rose requires sudo privileges", vim.log.levels.ERROR)
      return
    end
    local mkdir_cmd = ""
    if install_key == "qompass" then
      mkdir_cmd = string.format("sudo mkdir -p %s", install_dir)
    else
      mkdir_cmd = string.format("mkdir -p %s", install_dir)
    end
    vim.fn.system(mkdir_cmd)
    local url, filename = M.get_download_url()
    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    local temp_file = temp_dir .. "/" .. filename
    local download_cmd = ""
    if vim.fn.executable("curl") == 1 then
      download_cmd = string.format("curl -L -o %s %s", temp_file, url)
    elseif vim.fn.executable("wget") == 1 then
      download_cmd = string.format("wget -O %s %s", temp_file, url)
    else
      vim.notify("curl or wget is required for download", vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("Downloading Rose for %s-%s...", M.detect_platform()), vim.log.levels.INFO)
    local download_success = os.execute(download_cmd) == 0
    if not download_success then
      vim.notify("Failed to download Rose binary", vim.log.levels.ERROR)
      return
    end
    vim.notify("Extracting archive...", vim.log.levels.INFO)
    local extract_success, extract_error = M.extract_archive(temp_file, temp_dir)
    if not extract_success then
      vim.notify("Failed to extract archive: " .. (extract_error or "Unknown error"), vim.log.levels.ERROR)
      return
    end
    local binary_name = "rose"
    if M.detect_platform() == "windows" then
      binary_name = binary_name .. ".exe"
    end
    local find_cmd = string.format("find %s -name %s -type f", temp_dir, binary_name)
    local find_result = vim.fn.system(find_cmd)
    local binary_path = vim.fn.trim(find_result)
    if binary_path == "" then
      vim.notify("Could not find Rose binary in the extracted files", vim.log.levels.ERROR)
      return
    end
    local install_path = install_dir .. "/" .. binary_name
    local copy_cmd = ""
    if install_key == "qompass" then
      copy_cmd = string.format("sudo cp %s %s && sudo chmod +x %s", binary_path, install_path, install_path)
    else
      copy_cmd = string.format("cp %s %s && chmod +x %s", binary_path, install_path, install_path)
    end
    local copy_success = os.execute(copy_cmd) == 0
    if copy_success then
      vim.notify(string.format("Rose successfully installed to %s", install_path), vim.log.levels.INFO)
      if install_key == "nvim-data" then
        vim.notify("Consider adding " .. install_dir .. " to your PATH", vim.log.levels.INFO)
      end
      vim.fn.system(string.format("rm -rf %s", temp_dir))
    else
      vim.notify("Failed to install Rose binary", vim.log.levels.ERROR)
    end
  end)
end
function M.init()
  local exists, path = M.rose_exists()
  if not exists then
    M.rose_dl()
  else
    vim.notify("Rose binary found at: " .. path, vim.log.levels.INFO)
  end
end
function M.get_binary_path()
  local exists, path = M.rose_exists()
  return exists and path or nil
end
return M
