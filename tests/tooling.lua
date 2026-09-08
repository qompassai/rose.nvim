-- nvim --headless -u NONE -l tests/tooling.lua [Diver root]
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(repo)
local tools = require("rose.tools")
local uv = vim.uv
local root = vim.fn.tempname()
local outside = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.mkdir(outside, "p")
local passed = 0
local function eq(actual, expected, message)
  assert(
    vim.deep_equal(actual, expected),
    (message or "assertion") .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected)
  )
  passed = passed + 1
end
local function put(path, text)
  local fd = assert(uv.fs_open(path, "w", 384))
  assert(uv.fs_write(fd, text, 0))
  uv.fs_close(fd)
end
local function read(path)
  local fd = assert(uv.fs_open(path, "r", 0))
  local content = uv.fs_read(fd, uv.fs_fstat(fd).size, 0)
  uv.fs_close(fd)
  return content
end
local function call(name, args)
  local value = tools.call(name, args)
  assert(type(value) == "table" and type(value.status) == "string", vim.inspect(value))
  assert(pcall(vim.json.encode, value), "result must be JSON serializable")
  assert(pcall(vim.mpack.encode, value), "result must be msgpack serializable")
  return value
end
local function buffer(path, content, ft)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(b, path)
  local text = content:sub(-1) == "\n" and content:sub(1, -2) or content
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[b].endofline = content:sub(-1) == "\n"
  vim.bo[b].filetype = ft or ""
  vim.bo[b].modified = false
  vim.api.nvim_set_current_buf(b)
  return b
end

put(root .. "/code.lua", "local value = 1\n")
put(outside .. "/secret", "outside\n")
vim.fn.mkdir(root .. "/sub", "p")
assert(uv.fs_symlink(outside, root .. "/escape"))
assert(uv.fs_symlink(root .. "/sub", root .. "/safe"))
assert(uv.fs_symlink(outside .. "/missing", root .. "/broken-escape"))
tools.setup({ workspace = root })
eq(#tools.schemas(), 11, "standard schemas")
eq(tools.schemas()[1]["function"].parameters.additionalProperties, false)
eq(call("unknown").status, "error")
eq(call("editor_check", { cmd = { "bad" } }).status, "error", "no argv from model")
eq(call("file_read", { path = "../secret" }).status, "error")
eq(call("file_read", { path = outside .. "/secret" }).status, "error")
eq(call("file_read", { path = "escape/secret" }).status, "error", "symlink escape")
eq(call("file_write", { path = "code.lua", content = "x\n" }).status, "error", "trust required")
eq(call("file_read", { path = "code.lua" }).content, "local value = 1\n")
tools.setup({ workspace = root, trusted = true })
eq(
  call("file_write", { path = "escape/new/child", content = "x" }).status,
  "error",
  "nonexistent descendants under escaped symlink"
)
eq(
  call("file_write", { path = "broken-escape/child", content = "x" }).status,
  "error",
  "dangling symlink"
)
eq(
  call("file_write", { path = "safe/../file", content = "x" }).status,
  "error",
  "symlink parent traversal"
)
eq(
  call("file_write", { path = "new/child", content = "x" }).status,
  "error",
  "no implicit parent creation"
)
eq(call("file_write", { path = "safe/new", content = "hello" }).status, "ok", "safe symlink target")
eq(read(root .. "/sub/new"), "hello")
local listing = call("file_list", {})
eq(listing.omitted_unsafe, 2)
eq(call("file_list", { path = "code.lua" }).status, "error")

local b = buffer(root .. "/code.lua", "local value = 1\n", "")
eq(call("editor_context", {}).filetype, "lua", "native dynamic filetype detection")
eq(call("editor_diagnostics", {}).status, "unavailable", "no diagnostics is not verification")
eq(call("editor_symbols", {}).status, "unavailable")
eq(call("editor_references", {}).status, "unavailable")
eq(call("editor_lint", {}).status, "unavailable")
eq(call("editor_check", {}).status, "unavailable")
eq(call("editor_debug", {}).verified, false)
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "unsaved" })
eq(call("file_read", { path = "code.lua" }).source, "buffer")
eq(call("file_read", { path = "code.lua" }).content, "unsaved\n")
eq(
  call("file_write", { path = "code.lua", content = "overwrite\n" }).status,
  "error",
  "unsaved overwrite protection"
)
eq(read(root .. "/code.lua"), "local value = 1\n")
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "local value = 1" })
vim.bo[b].modified = false
eq(
  call(
    "file_write",
    { path = "code.lua", content = "local value = 2\n", expected_sha256 = "wrong" }
  ).status,
  "error"
)
local snapshot = call("file_read", { path = "code.lua" })
eq(
  call("file_write", {
    path = "code.lua",
    content = "local value = 2\n",
    expected_sha256 = snapshot.sha256,
    expected_changedtick = snapshot.changedtick,
  }).status,
  "ok"
)
eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "local value = 2" })
eq(vim.bo[b].modified, false)
eq(read(root .. "/code.lua"), "local value = 2\n")
put(root .. "/code.lua", "external\n")
eq(
  call("file_write", { path = "code.lua", content = "overwrite\n" }).status,
  "error",
  "external disk change"
)
put(root .. "/code.lua", "local value = 2\n")
put(root .. "/binary", "one\0two")
eq(call("file_read", { path = "binary" }).status, "error")
eq(call("file_write", { path = "binary", content = "text" }).status, "error")
put(root .. "/invalid-utf8", string.char(255))
eq(call("file_read", { path = "invalid-utf8" }).status, "error")
eq(
  call("file_write", { path = "utf8", content = string.char(237, 160, 128) }).status,
  "error",
  "invalid UTF8 surrogate rejected"
)
eq(call("file_write", { path = "utf8", content = "a😀éz" }).status, "ok")
vim.bo[b].readonly = true
eq(call("file_write", { path = "code.lua", content = "text" }).status, "error")
vim.bo[b].readonly = false

-- LSP adapter unit coverage with two encoding-specific clients and captured buffer.
local get_clients = vim.lsp.get_clients
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "a😀éz" })
local received = {}
local function client(id, encoding)
  return {
    id = id,
    name = "fake" .. id,
    offset_encoding = encoding,
    supports_method = function(_, method)
      return method ~= "textDocument/diagnostic"
    end,
    request_sync = function(_, method, params, timeout, bufnr)
      eq(bufnr, b, "captured buffer for LSP")
      assert(timeout > 0 and timeout <= 5000)
      if method == "textDocument/references" then
        received[encoding] = params.position.character
        return {
          result = {
            {
              uri = vim.uri_from_fname(root .. "/code.lua"),
              range = { start = params.position, ["end"] = params.position },
            },
            { uri = vim.uri_from_fname(outside .. "/secret"), range = {} },
          },
        }
      end
      return {
        result = {
          { name = "symbol", kind = 12, range = { start = { line = 0, character = 0 } } },
        },
      }
    end,
  }
end
vim.lsp.get_clients = function()
  return { client(1, "utf-8"), client(2, "utf-16"), client(3, "utf-32") }
end
local refs = call("editor_references", { line = 1, column = 7 })
eq(refs.status, "ok")
eq(received, { ["utf-8"] = 7, ["utf-16"] = 4, ["utf-32"] = 3 }, "per-client encoding")
eq(refs.omitted_outside_workspace, 3)
eq(
  call("editor_references", { line = 1, column = 2 }).status,
  "error",
  "UTF8 continuation byte rejected"
)
eq(call("editor_symbols", {}).clients[1].symbols[1].name, "symbol")
eq(call("editor_diagnostics", {}).status, "unverified")
local ns = vim.api.nvim_create_namespace("tooling-test")
vim.diagnostic.set(
  ns,
  b,
  { { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "bad", code = "E1" } }
)
eq(call("editor_diagnostics", {}).status, "failed")
eq(call("editor_diagnostics", {}).diagnostics[1].code, "E1")
vim.diagnostic.reset(ns, b)
vim.lsp.get_clients = function()
  local c = client(1, "utf-16")
  c.request_sync = function()
    return nil, "timeout"
  end
  return { c }
end
eq(call("editor_symbols", {}).status, "timeout")
vim.lsp.get_clients = function()
  local c = client(1, "utf-16")
  c.request_sync = function()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "changed while waiting" })
    return { result = {} }
  end
  return { c }
end
eq(call("editor_symbols", {}).status, "stale", "changedtick guards LSP results")
vim.lsp.get_clients = get_clients
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "local value = 2" })
vim.bo[b].modified = false

-- Actual argv subprocess checks, filtered/aggregate/missing/timeout/failure.
local python = vim.fn.exepath("python3")
tools.setup({
  workspace = root,
  trusted = true,
  checks = {
    clean = { cmd = { python, "-c", 'print("clean")' }, filetypes = {} },
    lua = { cmd = { python, "-c", 'print("lua")' }, filetypes = { "lua" } },
    other = { cmd = { python, "-c", "raise SystemExit(7)" }, filetypes = { "rust" } },
  },
})
local aggregate = call("editor_check", { path = "code.lua" })
eq(aggregate.status, "ok")
eq(#aggregate.checks, 2)
eq(aggregate.verified, true)
local current = vim.api.nvim_get_current_buf()
vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
eq(
  #call("editor_check", { path = "code.lua" }).checks,
  2,
  "explicit check path survives UI focus changes"
)
vim.api.nvim_set_current_buf(current)
eq(call("editor_context", {}).checks[1].name, "clean")
eq(call("editor_check", { name = "other" }).status, "unavailable")
eq(call("editor_check", { name = "not-configured" }).status, "unavailable")
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "unsaved" })
eq(call("editor_check", { name = "clean" }).status, "stale")
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "local value = 2" })
vim.bo[b].modified = false
tools.setup({
  workspace = root,
  trusted = true,
  checks = {
    failure = { cmd = { python, "-c", "raise SystemExit(7)" } },
    timeout = { cmd = { python, "-c", "import time; time.sleep(5)" }, timeout = 25 },
    missing = { cmd = { "rose-nonexistent-tool-941592" } },
  },
})
eq(call("editor_check", { name = "failure" }).status, "failed")
eq(call("editor_check", { name = "failure" }).checks[1].exit_code, 7)
eq(call("editor_check", { name = "timeout" }).status, "timeout")
eq(call("editor_check", { name = "missing" }).status, "unavailable")

-- IA-3: workspace-wide dirty and saved-file freshness, not just current buffer.
put(root .. "/noncurrent.py", "before = 1\n")
local source_buf = vim.api.nvim_get_current_buf()
local other_buf = buffer(root .. "/noncurrent.py", "before = 1\n", "python")
vim.api.nvim_set_current_buf(source_buf)
local first_context = call("editor_context", {})
eq(first_context.workspace_snapshot_version, 1)
eq(first_context.workspace_snapshot["noncurrent.py"].buffers[1].bufnr, other_buf)
eq(first_context.workspace_snapshot["noncurrent.py"].disk.sha256, vim.fn.sha256("before = 1\n"))
eq(
  first_context.workspace_snapshot,
  call("editor_context", {}).workspace_snapshot,
  "snapshot stable across reads"
)
vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "unsaved = 2" })
local dirty_context = call("editor_context", {})
eq(dirty_context.modified, false, "current buffer remains clean")
eq(dirty_context.dirty_buffers[1].path, "noncurrent.py", "noncurrent dirty buffer exposed")
eq(vim.deep_equal(first_context.workspace_snapshot, dirty_context.workspace_snapshot), false)
vim.fn.writefile({ "unsaved = 2" }, root .. "/noncurrent.py")
vim.bo[other_buf].modified = false
eq(#call("editor_context", {}).dirty_buffers, 0)
eq(
  vim.deep_equal(first_context.workspace_snapshot, call("editor_context", {}).workspace_snapshot),
  false,
  "saved noncurrent edit remains detectable"
)
tools.setup({
  workspace = root,
  trusted = true,
  checks = {
    saved_edit = {
      cmd = {
        python,
        "-c",
        'from pathlib import Path; Path("noncurrent.py").write_text("disk_changed = 3\\n")',
      },
    },
    editor_edit = { cmd = { python, "-c", "import time; time.sleep(.15)" } },
  },
})
eq(
  call("editor_check", { name = "saved_edit" }).status,
  "stale",
  "saved noncurrent disk edit during successful process"
)
vim.defer_fn(function()
  vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "saved_during_check = 4" })
  vim.fn.writefile({ "saved_during_check = 4" }, root .. "/noncurrent.py")
  vim.bo[other_buf].modified = false
end, 10)
eq(
  call("editor_check", { name = "editor_edit" }).status,
  "stale",
  "saved noncurrent editor edit during check"
)
put(root .. "/observed.py", "observed = 1\n")
call("file_read", { path = "observed.py" })
local observed = call("editor_context", {}).workspace_snapshot
eq(observed["observed.py"].disk.sha256, vim.fn.sha256("observed = 1\n"))
put(root .. "/observed.py", "observed = 2\n")
eq(
  vim.deep_equal(observed, call("editor_context", {}).workspace_snapshot),
  false,
  "observed unopened file saved change"
)

-- Decoded SCIP, path containment, literal queries and truthful limitations.
put(
  root .. "/index.scip.json",
  vim.json.encode({
    metadata = { projectRoot = vim.uri_from_fname(root) },
    documents = {
      {
        relativePath = "code.lua",
        language = "Lua",
        positionEncoding = 1,
        symbols = { { symbol = "local 0", displayName = "value", kind = 13 } },
        occurrences = { { symbol = "local 0", range = { 0, 6, 11 }, symbolRoles = 1 } },
      },
      { relative_path = "escape/secret", symbols = { { symbol = "outside" } } },
    },
  })
)
tools.setup({ workspace = root, trusted = true, scip = { path = "index.scip.json" } })
local index = call("editor_scip", { query = "local 0" })
eq(index.status, "unverified")
eq(#index.matches, 2)
eq(index.matches[2].definition, true)
eq(index.matches[1].local_symbol, true)
eq(index.omitted_unsafe_documents, 1)
eq(call("editor_scip", { action = "symbols", query = "value" }).matches[1].display_name, "value")
eq(#call("editor_scip", { query = ".*" }).matches, 0, "literal query, not patterns")
eq(call("editor_scip", { path = "../outside" }).status, "error")
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "unsaved index content" })
eq(call("editor_scip", { action = "symbols" }).status, "stale")
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "local value = 2" })
vim.bo[b].modified = false
put(root .. "/index.scip", "\1\2\3")
tools.setup({ workspace = root, scip = { path = "index.scip" } })
eq(call("editor_scip", {}).status, "unavailable", "no protobuf pretending")

-- Real Diver runner, isolated registration + deterministic completion.
local diver = arg[1] or vim.env.DIVER_ROOT
if diver and diver ~= "" then
  vim.opt.runtimepath:append(diver)
  local original_update = package.loaded["linters.update"]
  local runner =
    assert(loadfile(diver .. "/lua/linters/init.lua"))({ lazy = true, no_updates = true })
  eq(package.loaded["linters.update"], original_update, "embedding must not initialize updater")
  eq(vim.tbl_count(runner.definitions), 0, "no eager linter definition load")
  eq(runner.completion_api_version, 1)
  package.loaded.linters = runner
  tools.setup({ workspace = root, trusted = true, diver = { path = diver } })
  local function register(name, script, extra)
    runner.register(
      name,
      vim.tbl_extend("force", {
        cmd = python,
        args = { "-c", script },
        stdin = true,
        parser = function(output)
          if output:find("bad", 1, true) then
            return { { lnum = 0, col = 0, message = "bad lint" } }
          end
          return {}
        end,
      }, extra or {})
    )
    runner.linters_by_ft.lua = { name }
  end
  register("clean", 'import sys; assert sys.stdin.read(); print("clean")')
  eq(call("editor_lint", { path = "code.lua" }).status, "ok")
  put(root .. "/unopened.lua", "return 1\n")
  local reads = 0
  vim.api.nvim_create_autocmd({ "BufReadPost", "FileType" }, {
    callback = function()
      reads = reads + 1
    end,
  })
  eq(call("editor_lint", { path = "unopened.lua" }).status, "ok", "explicit unopened file lint")
  eq(reads, 0, "lint loading does not run filetype/BufRead hooks")
  eq(vim.api.nvim_get_current_buf(), b, "lint loading preserves current buffer")
  register("failed", 'print("bad")')
  eq(call("editor_lint", {}).status, "failed")
  register("missing", "", { cmd = "rose-nonexistent-linter-3829" })
  eq(call("editor_lint", {}).status, "unavailable")
  register("exit_nonzero", "raise SystemExit(8)")
  eq(call("editor_lint", {}).status, "failed")
  register("accepted_nonzero", "raise SystemExit(1)")
  eq(call("editor_lint", {}).status, "unverified")
  register("no_parser", 'print("nothing")', { parser = false })
  -- false deliberately produces a parser error rather than claiming clean.
  eq(call("editor_lint", {}).status, "error")
  register("bad_shape", 'print("nothing")', {
    parser = function()
      return { error = "not diagnostics" }
    end,
  })
  eq(call("editor_lint", {}).status, "error", "parser dictionary must not verify as empty array")
  register("timeout", "import time; time.sleep(5)")
  eq(call("editor_lint", { timeout = 30 }).status, "timeout")
  register("changed", 'import time; time.sleep(.1); print("clean")')
  vim.defer_fn(function()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "modified during lint" })
  end, 10)
  eq(call("editor_lint", { timeout = 2000 }).status, "stale", "completion changedtick")
  register("disk", 'print("clean")', { stdin = false })
  eq(call("editor_lint", {}).status, "stale", "disk lint refuses unsaved buffers")
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "local value = 2" })
  vim.bo[b].modified = false
  register("wrongcwd", 'print("clean")', { cwd = outside })
  eq(call("editor_lint", {}).status, "error", "linter cwd containment")
  register("cancelled", "import time; time.sleep(5)")
  local completion, count = nil, 0
  local started, handle = runner.run_linter("cancelled", b, {
    on_complete = function(result)
      completion = result
      count = count + 1
    end,
  })
  eq(started, true)
  handle.cancel()
  eq(completion.status, "stale")
  handle.cancel()
  eq(count, 1, "completion exactly once")
  runner.options.enabled = false
  eq(call("editor_lint", {}).status, "unavailable", "preserves user disabled setup")
  package.loaded.linters = nil
end
print(("tooling: %d assertions passed"):format(passed))
vim.cmd("qa!")
