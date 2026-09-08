-- Read-only queries over already-decoded SCIP JSON, never raw protobuf.
local M = {}
local w = require("rose.tooling.workspace")
local uv = vim.uv or vim.loop

local limitations = {
  "Only decoded SCIP JSON is supported; binary index.scip is not JSON and is not decoded by Rose.",
  "The index is a static snapshot with indexer-dependent language and reference coverage, not "
    .. "live verification.",
  "No index generation, call graph inference, type checking, or complete cross-repository "
    .. "reference search is provided.",
  "Ranges are zero-based in each document position_encoding; missing encoding is unspecified, "
    .. "not assumed to be UTF-8.",
  "Local symbols are document-scoped. Source freshness cannot be proven without matching "
    .. "index/source content hashes.",
}

function M.describe()
  local configured = (w.state().options.scip or {}).path
  if not configured then
    return {
      status = "unavailable",
      verified = false,
      limitations = limitations,
      reason = "No decoded SCIP JSON index configured.",
    }
  end
  local path = w.resolve(configured)
  local stat = uv.fs_stat(path)
  return {
    status = stat and configured:match("%.json$") and "unverified" or "unavailable",
    path = configured,
    exists = stat ~= nil,
    format = "decoded SCIP JSON",
    verified = false,
    limitations = limitations,
  }
end

local matches_limit_default = 100
local matches_limit_max = 1000
local symbol_role_definition = 1

-- Decode the index file; returns the index table or nil plus an error result.
local function load_index(path)
  local text = w.read_disk(path)
  local ok, index = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if
    not ok
    or type(index) ~= "table"
    or type(index.documents) ~= "table"
    or not vim.islist(index.documents)
  then
    return nil
  end
  return index
end

-- True when the source is newer than the index, missing, or modified in a buffer.
local function document_newer(absolute, index_stat)
  local actual = uv.fs_stat(absolute)
  -- A missing source counts as newer: the index no longer describes anything on disk.
  local newer = true
  if actual then
    if actual.mtime.sec == index_stat.mtime.sec then
      newer = actual.mtime.nsec > index_stat.mtime.nsec
    else
      newer = actual.mtime.sec > index_stat.mtime.sec
    end
  end
  for _, b in ipairs(w.buffers(absolute)) do
    if vim.bo[b].modified then
      newer = true
    end
  end
  return newer
end

-- Returns the declared project root URI (if any) and whether it is this workspace.
local function declared_root_status(index)
  local metadata = index.metadata or {}
  local declared_root = metadata.project_root or metadata.projectRoot
  local root_matches
  if type(declared_root) == "string" and declared_root:match("^file:") then
    local declared = uv.fs_realpath(vim.uri_to_fname(declared_root))
    root_matches = declared == w.state().root
  end
  return declared_root, root_matches
end

local function symbol_accepted(exact_symbol, query, symbol, display)
  if exact_symbol then
    return symbol == exact_symbol
  end
  return query == ""
    or type(symbol) == "string" and symbol:find(query, 1, true) ~= nil
    or type(display) == "string" and display:find(query, 1, true) ~= nil
end

local function is_local_symbol(symbol)
  return type(symbol) == "string" and symbol:match("^local ") ~= nil
end

local function collect_document(doc, absolute, newer, args, accepts, add)
  local encoding = doc.position_encoding or doc.positionEncoding or "unspecified"
  local relative_path = w.relative(absolute)
  for _, symbol in ipairs(doc.symbols or {}) do
    local display = symbol.display_name or symbol.displayName
    if accepts(symbol.symbol, display) then
      add({
        type = "symbol",
        path = relative_path,
        symbol = symbol.symbol,
        display_name = display,
        kind = symbol.kind,
        documentation = symbol.documentation,
        language = doc.language,
        local_symbol = is_local_symbol(symbol.symbol),
        position_encoding = encoding,
        potentially_stale = newer == true,
      })
    end
  end
  if args.action == "symbols" then
    return
  end
  for _, occurrence in ipairs(doc.occurrences or {}) do
    if accepts(occurrence.symbol) then
      local roles = tonumber(occurrence.symbol_roles or occurrence.symbolRoles) or 0
      add({
        type = "occurrence",
        path = relative_path,
        symbol = occurrence.symbol,
        range = occurrence.range,
        symbol_roles = roles,
        definition = bit.band(roles, symbol_role_definition) ~= 0,
        local_symbol = is_local_symbol(occurrence.symbol),
        position_encoding = encoding,
        potentially_stale = newer == true,
      })
    end
  end
end

function M.query(args)
  assert(type(args) == "table", "scip.query: args must be a table")
  local info = M.describe()
  if args.action == "status" or info.status == "unavailable" then
    return info
  end
  local path = w.resolve(info.path)
  local index = load_index(path)
  if not index then
    return {
      status = "error",
      error = "Invalid decoded SCIP JSON: expected an object with a documents array.",
      verified = false,
      limitations = limitations,
    }
  end
  local wanted = args.path and w.relative(w.resolve(args.path))
  local query = args.query or ""
  assert(type(query) == "string", "SCIP query must be a string")
  local limit = tonumber(args.limit) or matches_limit_default
  limit = math.min(math.max(limit, 1), matches_limit_max)
  local stat = uv.fs_stat(path)
  local matches, omitted, truncated, stale = {}, 0, false, false
  local declared_root, root_matches = declared_root_status(index)
  if root_matches == false then
    stale = true
  end
  local function accepts(symbol, display)
    return symbol_accepted(args.symbol, query, symbol, display)
  end
  local function add(item)
    if #matches >= limit then
      truncated = true
    else
      matches[#matches + 1] = item
    end
  end
  for _, doc in ipairs(index.documents) do
    assert(type(doc) == "table", "SCIP document must be an object")
    local relative = doc.relative_path or doc.relativePath
    local safe, absolute = pcall(w.resolve, relative)
    if not safe then
      omitted = omitted + 1
    elseif not wanted or w.relative(absolute) == wanted then
      local newer = document_newer(absolute, stat)
      if newer then
        stale = true
      end
      collect_document(doc, absolute, newer, args, accepts, add)
    end
  end
  assert(#matches <= limit, "SCIP matches must respect the requested limit")
  return {
    status = stale and "stale" or "unverified",
    verified = false,
    index = info.path,
    matches = matches,
    truncated = truncated,
    omitted_unsafe_documents = omitted,
    indexed_documents = #index.documents,
    index_mtime = stat.mtime.sec,
    declared_project_root = declared_root,
    project_root_matches = root_matches,
    limitations = limitations,
    reason = stale
        and "Index root differs, source is newer/missing, or indexed buffers have unsaved changes."
      or "Query completed against static index; completeness and freshness are unverified.",
  }
end

return M
