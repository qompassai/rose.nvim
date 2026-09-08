-- Workspace boundary and buffer snapshots. Never execute project configuration.
local M = {}
local uv = vim.uv or vim.loop
local api = vim.api
local state = { trusted = false, options = {}, max_bytes = 1024 * 1024 }

function M.setup(opts)
  opts = opts or {}
  local path = opts.workspace or uv.cwd()
  assert(path, "workspace is unavailable")
  local root = uv.fs_realpath(path)
  local stat = root and uv.fs_stat(root)
  assert(root and stat and stat.type == "directory", "workspace must be an existing directory")
  state = {
    root = root:gsub("/+$", "") == "" and "/" or root:gsub("/+$", ""),
    trusted = opts.trusted == true,
    options = opts,
    max_bytes = math.min(tonumber(opts.max_file_bytes) or (1024 * 1024), 16 * 1024 * 1024),
    observed_paths = {},
  }
  return state
end

function M.state()
  if not state.root then
    M.setup({})
  end
  return state
end

function M.contains(root, path)
  return path == root
    or path:sub(1, #root + (root == "/" and 0 or 1)) == (root == "/" and "/" or root .. "/")
end

local function root_check()
  local s = M.state()
  assert(uv.fs_realpath(s.root) == s.root, "workspace root changed or is unavailable")
  return s
end

-- Resolve each existing component BEFORE looking at the next. Reject ".." even
-- after a symlink; lexical normalization alone is not a containment check.
function M.resolve(path)
  local s = root_check()
  assert(type(path) == "string" and path ~= "", "path must be a nonempty relative string")
  assert(not path:find("\0", 1, true) and not path:find("\\", 1, true), "invalid path")
  assert(path:sub(1, 1) ~= "/" and not path:match("^%a:"), "absolute paths are not allowed")
  local parts = {}
  for part in path:gmatch("[^/]+") do
    assert(part ~= "..", "parent traversal is not allowed")
    if part ~= "." then
      parts[#parts + 1] = part
    end
  end
  local current = s.root
  for i, part in ipairs(parts) do
    current = (current == "/" and "" or current) .. "/" .. part
    local stat, err = uv.fs_lstat(current)
    if stat then
      local resolved = uv.fs_realpath(current)
      assert(resolved, "unresolvable symlink or inaccessible path")
      assert(M.contains(s.root, resolved), "path escapes workspace through a symlink")
      current = resolved
      if i < #parts then
        local parent = uv.fs_stat(current)
        assert(parent and parent.type == "directory", "parent is not a directory")
      end
    elseif err and not err:match("ENOENT") then
      error("cannot inspect path: " .. tostring(err))
    end
  end
  assert(M.contains(s.root, current), "path is outside workspace")
  return current
end

function M.relative(absolute)
  local s = root_check()
  assert(type(absolute) == "string" and absolute:sub(1, 1) == "/", "expected absolute filename")
  -- Existing aliases of the root are allowed only when their real target is inside.
  local resolved = uv.fs_realpath(absolute)
  if not resolved then
    assert(M.contains(s.root, absolute), "buffer is outside workspace")
    resolved = M.resolve(absolute:sub(#s.root + (s.root == "/" and 1 or 2)))
  end
  assert(M.contains(s.root, resolved), "buffer is outside workspace")
  return resolved == s.root and "." or resolved:sub(#s.root + (s.root == "/" and 1 or 2))
end

function M.text(content)
  assert(
    type(content) == "string" and not content:find("\0", 1, true),
    "binary files are not supported"
  )
  local i = 1
  while i <= #content do
    local first = content:byte(i)
    if first < 128 then
      i = i + 1
    else
      local count = first >= 194 and first <= 223 and 1
        or first >= 224 and first <= 239 and 2
        or first >= 240 and first <= 244 and 3
      assert(count and i + count <= #content, "text must be valid UTF-8")
      for j = 1, count do
        local byte = content:byte(i + j)
        assert(byte >= 128 and byte <= 191, "text must be valid UTF-8")
        if j == 1 then
          assert(
            not (
                first == 224 and byte < 160
                or first == 237 and byte > 159
                or first == 240 and byte < 144
                or first == 244 and byte > 143
              ),
            "text must be valid UTF-8"
          )
        end
      end
      i = i + count + 1
    end
  end
  return content
end

function M.read_disk(path)
  local stat = uv.fs_stat(path)
  assert(stat and stat.type == "file", "file is unavailable or not a regular file")
  assert(stat.size <= M.state().max_bytes, "file exceeds size limit")
  local fd = assert(uv.fs_open(path, "r", 0))
  local actual = uv.fs_fstat(fd)
  local resolved = uv.fs_realpath(path)
  local current = uv.fs_stat(path)
  if
    not actual
    or actual.type ~= "file"
    or actual.size > M.state().max_bytes
    or resolved ~= path
    or not M.contains(M.state().root, resolved or "")
    or not current
    or current.ino ~= actual.ino
    or current.dev ~= actual.dev
  then
    uv.fs_close(fd)
    error("file changed or exceeds size limit")
  end
  local content, err = uv.fs_read(fd, actual.size, 0)
  uv.fs_close(fd)
  assert(content, err)
  return M.text(content)
end

function M.buffer_content(bufnr)
  local content = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if vim.bo[bufnr].fileformat == "dos" then
    content = content:gsub("\n", "\r\n")
  end
  if vim.bo[bufnr].endofline then
    content = content .. (vim.bo[bufnr].fileformat == "dos" and "\r\n" or "\n")
  end
  return content
end

function M.buffers(path)
  local result = {}
  for _, b in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(b)
    if name ~= "" then
      local ok, rel = pcall(M.relative, name)
      if ok and M.resolve(rel) == path then
        result[#result + 1] = b
      end
    end
  end
  return result
end

function M.filetype(bufnr, path)
  local ft = vim.bo[bufnr].filetype
  if ft ~= "" then
    return ft
  end
  local ok, detected = pcall(vim.filetype.match, { filename = path, buf = bufnr })
  return ok and detected or ""
end

function M.capture(args, allow_empty)
  args = args or {}
  local b, path
  if args.path then
    path = M.resolve(args.path)
    for _, candidate in ipairs(M.buffers(path)) do
      if api.nvim_buf_is_loaded(candidate) then
        b = candidate
        break
      end
    end
    if not b then
      -- Do not bufload/edit: those run BufRead autocmds and modelines. LSP queries
      -- require an attached live client, so loading arbitrary files is unnecessary.
      return {
        path = M.relative(path),
        absolute = path,
        filetype = (vim.filetype.match({ filename = path }) or ""),
        loaded = false,
        modified = false,
        status = "unavailable",
      }
    end
  else
    b = api.nvim_get_current_buf()
    local name = api.nvim_buf_get_name(b)
    if name == "" and allow_empty then
      return {
        bufnr = b,
        filetype = vim.bo[b].filetype,
        loaded = true,
        changedtick = api.nvim_buf_get_changedtick(b),
        modified = vim.bo[b].modified,
        unnamed = true,
      }
    end
    assert(name ~= "", "current buffer has no workspace filename; supply path")
    path = M.resolve(M.relative(name))
  end
  assert(vim.bo[b].buftype == "", "only normal file buffers are supported")
  return {
    bufnr = b,
    path = M.relative(path),
    absolute = path,
    loaded = true,
    changedtick = api.nvim_buf_get_changedtick(b),
    modified = vim.bo[b].modified,
    filetype = M.filetype(b, path),
  }
end

function M.unchanged(snapshot)
  local valid = snapshot.bufnr
    and api.nvim_buf_is_valid(snapshot.bufnr)
    and api.nvim_buf_get_changedtick(snapshot.bufnr) == snapshot.changedtick
  if not valid then
    return false
  end
  if snapshot.unnamed then
    return api.nvim_buf_get_name(snapshot.bufnr) == ""
  end
  local ok, path = pcall(function()
    return M.resolve(M.relative(api.nvim_buf_get_name(snapshot.bufnr)))
  end)
  return ok and path == snapshot.absolute
end

-- Used only for an explicit trusted lint request. No BufRead, FileType or
-- modeline execution, and no replacement of an already loaded buffer.
function M.load(snapshot)
  M.require_trust()
  local b = snapshot.bufnr
  if b and vim.bo[b].filetype ~= "" then
    return snapshot
  end
  local previous = vim.o.eventignore
  vim.o.eventignore = "all"
  local ok, err = pcall(function()
    if not b then
      local content = M.read_disk(snapshot.absolute)
      b = M.buffers(snapshot.absolute)[1] or api.nvim_create_buf(false, false)
      if api.nvim_buf_get_name(b) == "" then
        api.nvim_buf_set_name(b, snapshot.absolute)
      end
      local dos = content:find("\r\n", 1, true) ~= nil
      local text = dos and content:gsub("\r\n", "\n") or content
      local eol = text:sub(-1) == "\n"
      if eol then
        text = text:sub(1, -2)
      end
      api.nvim_buf_set_lines(b, 0, -1, false, vim.split(text, "\n", { plain = true }))
      vim.bo[b].endofline, vim.bo[b].fileformat = eol, dos and "dos" or "unix"
      vim.bo[b].modified = false
    end
    vim.bo[b].filetype = snapshot.filetype
  end)
  vim.o.eventignore = previous
  assert(ok, err)
  return M.capture({ path = snapshot.path })
end

function M.dirty()
  local result = {}
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      local ok, path = pcall(M.relative, api.nvim_buf_get_name(b))
      if ok then
        result[#result + 1] = { path = path, changedtick = api.nvim_buf_get_changedtick(b) }
      end
    end
  end
  table.sort(result, function(a, b)
    return a.path == b.path and a.changedtick < b.changedtick or a.path < b.path
  end)
  return result
end

function M.observe(path)
  M.state().observed_paths[M.relative(path)] = true
end

local function disk_snapshot(path)
  local stat = uv.fs_stat(path)
  if not stat then
    return { exists = false }
  end
  local result = {
    exists = true,
    type = stat.type,
    size = stat.size,
    ino = stat.ino,
    dev = stat.dev,
    mtime = { sec = stat.mtime.sec, nsec = stat.mtime.nsec },
    ctime = { sec = stat.ctime.sec, nsec = stat.ctime.nsec },
  }
  -- Content hashing catches saved edits even when mtimes are deliberately
  -- preserved. Oversized/unreadable files retain stat evidence, never a fake hash.
  if stat.type == "file" and stat.size <= M.state().max_bytes then
    local ok, content = pcall(M.read_disk, path)
    if ok then
      result.sha256 = vim.fn.sha256(content)
    else
      result.hash_status = "unavailable"
    end
  else
    result.hash_status = "unavailable"
  end
  return result
end

-- Stable map: canonical workspace-relative filename -> buffer identities and
-- saved-file identity/content evidence. No atime, current-window state or clock
-- timestamps are included, so deep equality is meaningful across tool calls.
-- Coverage is every normal named editor buffer plus explicitly observed paths,
-- not an implicit recursive scan of the repository.
function M.snapshot(path)
  local s = root_check()
  if path then
    M.observe(M.resolve(path))
  end
  local result = vim.empty_dict()
  for relative in pairs(s.observed_paths) do
    result[relative] = { path = relative, buffers = {} }
  end
  for _, b in ipairs(api.nvim_list_bufs()) do
    if vim.bo[b].buftype == "" then
      local ok, relative = pcall(M.relative, api.nvim_buf_get_name(b))
      if ok then
        result[relative] = result[relative] or { path = relative, buffers = {} }
        result[relative].buffers[#result[relative].buffers + 1] = {
          bufnr = b,
          changedtick = api.nvim_buf_get_changedtick(b),
          modified = vim.bo[b].modified,
          loaded = api.nvim_buf_is_loaded(b),
        }
      end
    end
  end
  for relative, item in pairs(result) do
    table.sort(item.buffers, function(a, b)
      return a.bufnr < b.bufnr
    end)
    local ok, disk = pcall(function()
      return disk_snapshot(M.resolve(relative))
    end)
    item.disk = ok and disk or { status = "error", reason = "path is no longer safely accessible" }
  end
  return result
end

function M.require_trust()
  assert(M.state().trusted, "workspace is not trusted; execution and writes are disabled")
end

function M.timeout(value, default)
  value = tonumber(value) or default or 5000
  assert(value >= 1 and value <= 120000, "timeout must be between 1 and 120000 milliseconds")
  return math.floor(value)
end

function M.aggregate(results)
  if #results == 0 then
    return "unavailable"
  end
  for _, status in ipairs({ "error", "timeout", "stale", "failed", "unavailable", "unverified" }) do
    for _, item in ipairs(results) do
      if item.status == status then
        return status
      end
    end
  end
  return "ok"
end

return M
