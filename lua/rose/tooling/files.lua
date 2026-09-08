local M = {}
local w = require("rose.tooling.workspace")
local uv = vim.uv or vim.loop
local api = vim.api
-- Directory listings stop scanning here even when the caller asked for fewer entries.
local directory_entries_max = 10000

function M.read(args)
  local path = w.resolve(args.path)
  w.observe(path)
  local content, snapshot
  for _, b in ipairs(w.buffers(path)) do
    if api.nvim_buf_is_loaded(b) then
      snapshot = w.capture({ path = args.path })
      content = w.buffer_content(b)
      break
    end
  end
  content = content or w.read_disk(path)
  assert(#content <= w.state().max_bytes, "file exceeds size limit")
  w.text(content)
  return {
    status = "ok",
    path = w.relative(path),
    content = content,
    sha256 = vim.fn.sha256(content),
    source = snapshot and "buffer" or "disk",
    modified = snapshot and snapshot.modified or false,
    changedtick = snapshot and snapshot.changedtick or nil,
  }
end

local function buffer_lines(content)
  local dos = content:find("\r\n", 1, true) ~= nil
  local text = dos and content:gsub("\r\n", "\n") or content
  local eol = text:sub(-1) == "\n"
  if eol then
    text = text:sub(1, -2)
  end
  return vim.split(text, "\n", { plain = true }), eol, dos and "dos" or "unix"
end

-- Attempts to create a unique temporary file before giving up.
local temporary_attempts_max = 10
local file_mode_default = 384 -- 0600
local file_mode_mask = 511 -- 0777

-- Every loaded buffer for `path` must be a clean, writable, UTF-8 mirror of disk.
local function write_buffers(path, old, args)
  local buffers = {}
  for _, b in ipairs(w.buffers(path)) do
    if api.nvim_buf_is_loaded(b) then
      assert(not vim.bo[b].modified, "refusing to overwrite an unsaved buffer")
      assert(
        vim.bo[b].modifiable and not vim.bo[b].readonly,
        "buffer is read-only or not modifiable"
      )
      assert(
        vim.bo[b].fileencoding == "" or vim.bo[b].fileencoding == "utf-8",
        "non-UTF-8 buffers are unsupported"
      )
      assert(not vim.bo[b].bomb, "BOM buffers require manual saving")
      assert(
        old == nil or w.buffer_content(b) == old,
        "disk differs from loaded buffer; reload manually"
      )
      local tick = api.nvim_buf_get_changedtick(b)
      assert(
        not args.expected_changedtick or args.expected_changedtick == tick,
        "buffer changed since read"
      )
      buffers[#buffers + 1] = { bufnr = b, tick = tick }
    end
  end
  assert(
    not args.expected_changedtick or #buffers > 0,
    "expected_changedtick requires a loaded buffer"
  )
  return buffers
end

-- Atomic replacement avoids following a hard link or partially truncating a file.
local function write_temporary(parent, stat)
  local temporary, fd
  for i = 1, temporary_attempts_max do
    temporary = parent
      .. "/.rose-write-"
      .. tostring(uv.os_getpid())
      .. "-"
      .. tostring(uv.hrtime())
      .. "-"
      .. i
    local mode = stat and bit.band(stat.mode, file_mode_mask) or file_mode_default
    fd = uv.fs_open(temporary, "wx", mode)
    if fd then
      break
    end
  end
  assert(fd, "could not create atomic write file")
  return temporary, fd
end

-- Re-verify every precondition after the bytes are on disk, then rename into place.
local function write_commit(state, temporary, fd)
  assert(w.resolve(w.relative(temporary)) == temporary, "temporary destination escaped workspace")
  local written = assert(uv.fs_write(fd, state.content, 0))
  assert(written == #state.content, "short file write")
  assert(uv.fs_fsync(fd))
  assert(uv.fs_close(fd))
  state.fd_closed = true
  assert(w.resolve(state.request_path) == state.path, "destination changed during write")
  assert(
    (uv.fs_stat(state.path) ~= nil) == (state.stat ~= nil),
    "destination appeared or disappeared during write"
  )
  if state.stat then
    assert(w.read_disk(state.path) == state.old, "disk changed during write")
  end
  for _, item in ipairs(state.buffers) do
    assert(
      api.nvim_buf_is_valid(item.bufnr)
        and not vim.bo[item.bufnr].modified
        and api.nvim_buf_get_changedtick(item.bufnr) == item.tick,
      "buffer changed during write"
    )
  end
  assert(uv.fs_rename(temporary, state.path))
end

function M.write(args)
  assert(type(args) == "table", "files.write: args must be a table")
  w.require_trust()
  assert(type(args.content) == "string", "content must be a string")
  assert(#args.content <= w.state().max_bytes, "content is binary or too large")
  assert(not args.content:find("\0", 1, true), "content is binary or too large")
  w.text(args.content)
  local path = w.resolve(args.path)
  w.observe(path)
  local stat = uv.fs_stat(path)
  assert(not stat or stat.type == "file", "destination is not a regular file")
  local old = stat and w.read_disk(path) or nil
  if args.expected_sha256 then
    assert(old and vim.fn.sha256(old) == args.expected_sha256, "disk changed since read")
  end
  local buffers = write_buffers(path, old, args)
  assert(not stat or vim.fn.filewritable(path) == 1, "file is not writable")
  local parent = vim.fs.dirname(path)
  assert(
    uv.fs_stat(parent) and uv.fs_stat(parent).type == "directory",
    "parent directory does not exist"
  )
  local temporary, fd = write_temporary(parent, stat)
  local state = {
    content = args.content,
    request_path = args.path,
    path = path,
    stat = stat,
    old = old,
    buffers = buffers,
  }
  local ok, err = pcall(write_commit, state, temporary, fd)
  if not ok then
    -- Never close twice: the descriptor number may already belong to another file.
    if not state.fd_closed then
      uv.fs_close(fd)
    end
    uv.fs_unlink(temporary)
    error(err)
  end
  local lines, eol, format = buffer_lines(args.content)
  for _, item in ipairs(buffers) do
    api.nvim_buf_set_lines(item.bufnr, 0, -1, false, lines)
    vim.bo[item.bufnr].endofline = eol
    vim.bo[item.bufnr].fileformat = format
    vim.bo[item.bufnr].modified = false
  end
  return {
    status = "ok",
    path = w.relative(path),
    bytes = #args.content,
    sha256 = vim.fn.sha256(args.content),
    buffers_updated = #buffers,
  }
end

function M.list(args)
  local path = w.resolve(args.path or ".")
  assert(uv.fs_stat(path) and uv.fs_stat(path).type == "directory", "path is not a directory")
  local limit = math.min(math.max(tonumber(args.limit) or 200, 1), 1000)
  local scan = assert(uv.fs_scandir(path))
  local entries, omitted, truncated = {}, 0, false
  -- Bound the directory walk itself, not only the returned entries, so a huge directory
  -- cannot stall the editor; anything past the bound is reported as truncated.
  for scanned = 1, directory_entries_max + 1 do
    if scanned > directory_entries_max then
      truncated = true
      break
    end
    local name, kind = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    local relative = (w.relative(path) == "." and "" or w.relative(path) .. "/") .. name
    local ok, resolved = pcall(w.resolve, relative)
    if ok then
      if #entries >= limit then
        truncated = true
        break
      end
      entries[#entries + 1] = {
        name = name,
        path = relative,
        type = kind,
        target_type = kind == "link" and uv.fs_stat(resolved).type or nil,
      }
    else
      omitted = omitted + 1
    end
  end
  table.sort(entries, function(a, b)
    return a.name < b.name
  end)
  return {
    status = "ok",
    path = w.relative(path),
    entries = entries,
    omitted_unsafe = omitted,
    truncated = truncated,
    recursive = false,
  }
end

return M
