local M = {}
local w = require("rose.tooling.workspace")
local api = vim.api
local uv = vim.uv or vim.loop

function M.clients(snapshot)
  if not snapshot.bufnr or not snapshot.loaded or not vim.lsp or not vim.lsp.get_clients then
    return {}
  end
  return vim.lsp.get_clients({ bufnr = snapshot.bufnr })
end

local methods = {
  document_symbols = "textDocument/documentSymbol",
  references = "textDocument/references",
  pull_diagnostics = "textDocument/diagnostic",
}

function M.supports(client, method, bufnr)
  local ok, result = pcall(client.supports_method, client, method, bufnr)
  return ok and result == true
end

function M.describe(snapshot)
  local result = {}
  for _, client in ipairs(M.clients(snapshot)) do
    local item = {
      id = client.id,
      name = client.name,
      encoding = client.offset_encoding or "utf-16",
      capabilities = {},
    }
    for key, method in pairs(methods) do
      item.capabilities[key] = M.supports(client, method, snapshot.bufnr)
    end
    result[#result + 1] = item
  end
  return result
end

function M.diagnostic_items(bufnr, namespace)
  local result = {}
  if not bufnr then
    return result
  end
  for _, d in ipairs(vim.diagnostic.get(bufnr, namespace and { namespace = namespace } or {})) do
    result[#result + 1] = {
      line = d.lnum + 1,
      column = d.col,
      end_line = (d.end_lnum or d.lnum) + 1,
      end_column = d.end_col,
      severity = d.severity,
      message = tostring(d.message),
      source = d.source,
      code = (type(d.code) == "string" or type(d.code) == "number") and d.code or nil,
      namespace = d.namespace,
    }
  end
  return result
end

function M.diagnostics(args)
  local s = w.capture(args)
  local clients = M.describe(s)
  local diagnostics = M.diagnostic_items(s.bufnr)
  local status = (not s.loaded or #clients == 0 and #diagnostics == 0) and "unavailable"
    or "unverified"
  for _, d in ipairs(diagnostics) do
    if d.severity == vim.diagnostic.severity.ERROR then
      status = "failed"
    end
  end
  return {
    status = status,
    path = s.path,
    filetype = s.filetype,
    changedtick = s.changedtick,
    diagnostics = diagnostics,
    clients = clients,
    verified = false,
    coordinates = "line: 1-based; column: 0-based bytes",
    reason = "Cached native diagnostics are a snapshot, not a completed check; an empty list never "
      .. "verifies correctness.",
  }
end

local function request(snapshot, method, params_for, timeout)
  local started = uv.hrtime()
  local responses = {}
  for _, client in ipairs(M.clients(snapshot)) do
    local item = {
      client_id = client.id,
      client_name = client.name,
      encoding = client.offset_encoding or "utf-16",
    }
    if not M.supports(client, method, snapshot.bufnr) then
      item.status, item.reason = "unavailable", "attached client does not support " .. method
    else
      local remaining = math.floor(timeout - (uv.hrtime() - started) / 1e6)
      if remaining <= 0 then
        item.status, item.reason = "timeout", "shared request deadline exceeded"
      else
        local ok, response, err = pcall(function()
          return client:request_sync(method, params_for(client), remaining, snapshot.bufnr)
        end)
        if not ok then
          item.status, item.error = "error", tostring(response)
        elseif not response then
          item.status = tostring(err):lower():find("timeout", 1, true) and "timeout" or "error"
          item.error = tostring(err or "request failed")
        elseif response.err then
          item.status, item.error =
            "error", tostring(response.err.message or vim.inspect(response.err))
        else
          item.status, item.result =
            "ok", response.result == vim.NIL and {} or response.result or {}
        end
      end
    end
    responses[#responses + 1] = item
  end
  -- Unsupported clients do not invalidate a completed capable client's query.
  local supported = {}
  for _, item in ipairs(responses) do
    if item.status ~= "unavailable" then
      supported[#supported + 1] = item
    end
  end
  local status = w.aggregate(supported)
  if snapshot.bufnr and not w.unchanged(snapshot) then
    status = "stale"
  end
  return {
    status = status,
    path = snapshot.path,
    changedtick = snapshot.changedtick,
    clients = responses,
    verified = false,
    reason = #supported == 0 and "No attached LSP client supports this request." or nil,
  }
end

local function location(value)
  local uri = value.uri or value.targetUri
  if type(uri) ~= "string" or not uri:match("^file:") then
    return nil
  end
  local ok, path = pcall(function()
    return w.relative(vim.uri_to_fname(uri))
  end)
  if not ok then
    return nil
  end
  return { path = path, range = value.range or value.targetSelectionRange or value.targetRange }
end

function M.symbols(args)
  local s = w.capture(args)
  local result = request(s, methods.document_symbols, function()
    return { textDocument = { uri = vim.uri_from_fname(s.absolute) } }
  end, w.timeout(args.timeout, 5000))
  local omitted = 0
  local function clean(symbols, depth)
    local list = {}
    if depth > 32 then
      return list
    end
    for _, symbol in ipairs(symbols or {}) do
      local loc = symbol.location and location(symbol.location)
      if symbol.location and not loc then
        omitted = omitted + 1
      else
        list[#list + 1] = {
          name = symbol.name,
          detail = symbol.detail,
          kind = symbol.kind,
          range = symbol.range,
          selection_range = symbol.selectionRange,
          location = loc,
          children = symbol.children and clean(symbol.children, depth + 1) or nil,
        }
      end
    end
    return list
  end
  for _, item in ipairs(result.clients) do
    if item.result then
      item.symbols = clean(item.result, 1)
      item.result = nil
    end
  end
  result.omitted_outside_workspace = omitted
  result.coordinates = "LSP ranges are 0-based in each client encoding; use clients[].encoding."
  return result
end

function M.references(args)
  local s = w.capture(args)
  local row, col = tonumber(args.line), tonumber(args.column)
  if s.bufnr == api.nvim_get_current_buf() then
    local cursor = api.nvim_win_get_cursor(0)
    row, col = row or cursor[1], col or cursor[2]
  end
  row, col = row or 1, col or 0
  assert(
    row >= 1 and row == math.floor(row) and col >= 0 and col == math.floor(col),
    "invalid reference position"
  )
  ---@cast row integer
  ---@cast col integer
  if s.bufnr then
    assert(row <= api.nvim_buf_line_count(s.bufnr), "reference line is outside buffer")
  end
  local text = s.bufnr and api.nvim_buf_get_lines(s.bufnr, row - 1, row, false)[1] or ""
  if s.bufnr then
    assert(col <= #text, "reference byte column is outside line")
    local byte = text:byte(col + 1)
    assert(not byte or byte < 128 or byte >= 192, "reference column splits a UTF-8 codepoint")
  end
  local result = request(s, methods.references, function(client)
    return {
      textDocument = { uri = vim.uri_from_fname(s.absolute) },
      position = {
        line = row - 1,
        character = vim.str_utfindex(text, client.offset_encoding or "utf-16", col, false),
      },
      context = { includeDeclaration = args.include_declaration ~= false },
    }
  end, w.timeout(args.timeout, 5000))
  local omitted = 0
  for _, item in ipairs(result.clients) do
    if item.result then
      item.references = {}
      for _, ref in ipairs(item.result) do
        local loc = location(ref)
        if loc then
          item.references[#item.references + 1] = loc
        else
          omitted = omitted + 1
        end
      end
      item.result = nil
    end
  end
  result.omitted_outside_workspace = omitted
  result.coordinates = "Input line: 1-based; input column: 0-based UTF-8 bytes. "
    .. "Output ranges: 0-based per-client encoding."
  return result
end

return M
