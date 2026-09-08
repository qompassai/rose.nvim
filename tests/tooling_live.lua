-- Optional real-tool verification. No installation or network access is performed.
-- ROSE_TEST_LSP=/path/basedpyright-langserver ROSE_TEST_RUFF=/path/ruff \
-- DIVER_ROOT=/path/diver nvim --headless -u NONE -l tests/tooling_live.lua
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(repo)
local tools = require("rose.tools")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local file = root .. "/sample.py"
vim.fn.writefile({
  "import os",
  "def double(value: int) -> int:",
  "    return value * 2",
  "",
  "result: int = double(3)",
  'incorrect: int = "not an integer"',
}, file)
vim.cmd.edit(vim.fn.fnameescape(file))
vim.bo.filetype = "python"
tools.setup({ workspace = root, trusted = true })
local count, skipped = 0, {}
local function check(condition, result)
  assert(condition, vim.inspect(result))
  count = count + 1
end
local server = vim.env.ROSE_TEST_LSP or vim.fn.exepath("basedpyright-langserver")
if server ~= "" and vim.fn.executable(server) == 1 then
  local id = assert(vim.lsp.start({
    name = "rose-tooling-live",
    cmd = { server, "--stdio" },
    root_dir = root,
    settings = {
      basedpyright = {
        analysis = { typeCheckingMode = "standard", diagnosticMode = "openFilesOnly" },
      },
    },
  }))
  check(
    vim.wait(20000, function()
      local client = vim.lsp.get_client_by_id(id)
      return client ~= nil and client.initialized == true and #vim.diagnostic.get(0) > 0
    end, 20),
    "expected actual LSP diagnostic completion"
  )
  local diagnostics = tools.call("editor_diagnostics", {})
  assert(type(diagnostics) == "table", "editor_diagnostics must return a result")
  assert(type(diagnostics.diagnostics) == "table", "diagnostics must include diagnostic items")
  check(
    diagnostics.status == "failed" and #diagnostics.diagnostics > 0 and not diagnostics.verified,
    diagnostics
  )
  local symbols = tools.call("editor_symbols", { timeout = 10000 })
  assert(type(symbols) == "table", "editor_symbols must return a result")
  check(symbols.status == "ok", symbols)
  local found = false
  for _, client in ipairs(symbols.clients) do
    for _, symbol in ipairs(client.symbols or {}) do
      if symbol.name == "double" then
        found = true
      end
    end
  end
  check(found, symbols)
  local refs = tools.call("editor_references", { line = 2, column = 5, timeout = 10000 })
  assert(type(refs) == "table", "editor_references must return a result")
  check(refs.status == "ok", refs)
  local references = 0
  for _, client in ipairs(refs.clients) do
    references = references + #(client.references or {})
  end
  check(references >= 2, refs)
  assert(vim.lsp.get_client_by_id(id), "live LSP client must still be registered"):stop(true)
  vim.wait(1000, function()
    return vim.lsp.get_client_by_id(id) == nil
  end, 10)
else
  skipped[#skipped + 1] = "basedpyright-langserver unavailable"
end

local ruff = vim.env.ROSE_TEST_RUFF or vim.fn.exepath("ruff")
local diver = vim.env.DIVER_ROOT
if ruff ~= "" and vim.fn.executable(ruff) == 1 and diver then
  vim.opt.runtimepath:append(diver)
  local runner =
    assert(loadfile(diver .. "/lua/linters/init.lua"))({ lazy = true, no_updates = true })
  runner.register("tooling_real_ruff", {
    cmd = ruff,
    stdin = true,
    stream = "stdout",
    exit_codes = { 0, 1 },
    args = function(context)
      return {
        "check",
        "--isolated",
        "--select",
        "F401",
        "--output-format",
        "json",
        "--stdin-filename",
        context.filename,
        "-",
      }
    end,
    parser = function(output)
      local diagnostics = {}
      for _, item in ipairs(vim.json.decode(output)) do
        diagnostics[#diagnostics + 1] = {
          lnum = item.location.row - 1,
          col = item.location.column - 1,
          end_lnum = item.end_location.row - 1,
          end_col = item.end_location.column - 1,
          message = item.message,
          code = item.code,
          severity = vim.diagnostic.severity.WARN,
        }
      end
      return diagnostics
    end,
  })
  runner.linters_by_ft.python = { "tooling_real_ruff" }
  package.loaded.linters = runner
  tools.setup({ workspace = root, trusted = true, diver = { path = diver } })
  local bad = tools.call("editor_lint", { timeout = 5000 })
  assert(type(bad) == "table", "editor_lint must return a result")
  check(bad.status == "failed" and not bad.verified, bad)
  check(#bad.linters[1].diagnostics > 0 and bad.linters[1].exit_code == 1, bad)
  check(bad.linters[1].diagnostics[1].code == "F401", bad)
  -- Stdin checks intentionally verify the modified buffer, without saving it.
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'print("clean")' })
  local clean = tools.call("editor_lint", { timeout = 5000 })
  assert(type(clean) == "table", "editor_lint must return a result")
  check(clean.status == "ok" and clean.verified, clean)
  check(clean.linters[1].exit_code == 0 and #clean.linters[1].diagnostics == 0, clean)
  check(vim.bo.modified, "lint must not save the edited buffer")
else
  skipped[#skipped + 1] = "ruff or Diver root unavailable"
end
print(("tooling_live: %d assertions passed; skips: %s"):format(count, table.concat(skipped, "; ")))
vim.cmd("qa!")
