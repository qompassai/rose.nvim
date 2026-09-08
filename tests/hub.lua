-- Run: ROSE_TEST_PYTHON=/path/to/python nvim --headless -u NONE -l tests/hub.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local uv = vim.uv or vim.loop
local base = vim.fn.tempname()
vim.fn.mkdir(base .. "/workspace", "p")
local python = vim.env.ROSE_TEST_PYTHON or "python3"
local fixture = root .. "/tests/fixtures/hub_python.py"
local workspace = assert(uv.fs_realpath(base .. "/workspace"))
local hub = require("rose.hub")
local passed, failures, case = 0, {}, 0
local saved_select, saved_input, saved_notify = vim.ui.select, vim.ui.input, vim.notify
vim.notify = function() end

local function equal(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local function test(name, fn)
  case = case + 1
  vim.ui.select = function(_, _, cb)
    cb("Cancel")
  end
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failures[#failures + 1] = name .. ": " .. err
    print("FAIL " .. name .. ": " .. err)
  end
  hub.stop()
  vim.wait(1000, function()
    return hub.status().state ~= "transferring"
  end, 10)
end

local function config(opts)
  return vim.tbl_extend("force", {
    workspace = workspace,
    cache_dir = base .. "/cache-" .. case,
    python = fixture,
    trusted = true,
  }, opts or {})
end

local function await(start)
  local calls, err, result = 0, nil, nil
  local token = start(function(e, r)
    calls, err, result = calls + 1, e, r
  end)
  assert(type(token) == "table" and type(token.cancel) == "function")
  assert(
    vim.wait(10000, function()
      return calls > 0
    end, 5),
    "callback deadline"
  )
  vim.wait(50, function()
    return false
  end, 5)
  equal(calls, 1)
  return err, result, token
end

local function records()
  local path = base .. "/cache-" .. case .. "/fixture-requests.jsonl"
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local rows = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    rows[#rows + 1] = vim.json.decode(line)
  end
  return rows
end

local spec = { repo_id = "example/repo", files = { "README.md" }, destination = "models/tiny" }
local upload = { repo_id = "example/repo", files = { "README.md" }, path_in_repo = "paper" }
local function accept(_, _, cb)
  cb("Download exactly this manifest")
end

test("require/setup is native and has no processes or commands by default", function()
  local system = vim.system
  vim.system = function()
    error("unexpected subprocess")
  end
  local ok, err = pcall(function()
    hub.setup(config())
    equal(hub.status().state, "idle")
    assert(not vim.api.nvim_get_commands({}).RoseHubDownload)
    assert(not package.loaded["plenary"] and not package.loaded["fzf-lua"])
  end)
  vim.system = system
  assert(ok, err)
end)

test("setup validates trust and worker bounds", function()
  assert(not pcall(hub.setup, config({ trusted = "yes" })))
  assert(not pcall(hub.setup, config({ max_workers = 17 })))
  assert(not pcall(hub.setup, config({ approve_upload = true })))
  assert(not pcall(hub.setup, config({ token = "never" })))
  hub.setup(config())
end)

test("download dry-run executes only a preview subprocess", function()
  hub.setup(config())
  vim.ui.select = function()
    error("dry-run cannot prompt")
  end
  local err, result = await(function(cb)
    return hub.download(vim.tbl_extend("force", spec, { dry_run = true }), cb)
  end)
  assert(not err, err)
  equal(result.total_bytes, 10)
  equal(result.commit, string.rep("a", 40))
  equal(#records(), 1)
  equal(records()[1].operation, "preview_download")
end)

test("download exact native preview and approval execute asynchronously", function()
  hub.setup(config())
  local saw_preview = false
  vim.ui.select = function(items, opts, cb)
    local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    for _, text in ipairs({
      "example/repo",
      "model",
      "public",
      "main",
      string.rep("a", 40),
      "README.md",
      "models/tiny",
      "new file",
    }) do
      assert(lines:find(text, 1, true), text)
    end
    equal(vim.bo.modeline, false)
    saw_preview = true
    cb(items[2])
    cb(items[2]) -- duplicate UI responses must not start duplicate transfers
  end
  local err, result = await(function(cb)
    return hub.download(spec, cb)
  end)
  assert(not err, err)
  assert(saw_preview)
  equal(result.direction, "download")
  equal(#records(), 2)
  equal(records()[2].preview.commit, string.rep("a", 40))
end)

test("native cancellation rejects transfers after preview", function()
  hub.setup(config())
  local err = await(function(cb)
    return hub.download(spec, cb)
  end)
  assert(err:find("not approved"))
  equal(#records(), 1)
end)

test("untrusted upload is rejected before subprocess", function()
  hub.setup(config({ trusted = false }))
  local err = await(function(cb)
    return hub.upload(upload, cb)
  end)
  assert(err:find("trusted"))
  equal(#records(), 0)
end)

test("spec booleans cannot approve upload or provide credentials", function()
  hub.setup(config())
  for _, key in ipairs({ "approved", "confirmed", "token", "trust_remote_code", "endpoint" }) do
    local err = await(function(cb)
      return hub.upload(vim.tbl_extend("force", upload, { [key] = true }), cb)
    end)
    assert(err:find("unknown Hub spec"))
  end
  equal(#records(), 0)
end)

test("upload setup capability must approve exact preview data not boolean", function()
  hub.setup(config({
    approve_upload = function(_, cb)
      cb(true)
    end,
  }))
  local err = await(function(cb)
    return hub.upload(upload, cb)
  end)
  assert(err:find("not approved"))
  equal(#records(), 1)
end)

test("upload setup capability rejects modified preview", function()
  hub.setup(config({
    approve_upload = function(p, cb)
      p.repo_id = "other/repo"
      cb(p)
    end,
  }))
  local err = await(function(cb)
    return hub.upload(upload, cb)
  end)
  assert(err:find("not approved"))
  equal(#records(), 1)
end)

test("upload setup capability approves frozen complete manifest once", function()
  hub.setup(config({
    approve_upload = function(p, cb)
      cb(vim.deepcopy(p))
      cb(p)
    end,
  }))
  local err, result = await(function(cb)
    return hub.upload(upload, cb)
  end)
  assert(not err, err)
  equal(result.direction, "upload")
  equal(#records(), 2)
  equal(records()[2].preview.files[1].remote_path, "paper/README.md")
end)

test("upload native UI shows all exact destinations hashes and visibility", function()
  hub.setup(config())
  vim.ui.select = function(items, _, cb)
    local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert(lines:find("README.md -> paper/README.md", 1, true))
    assert(lines:find(string.rep("b", 64), 1, true))
    assert(lines:find("Visibility: public", 1, true))
    cb(items[2])
  end
  local err = await(function(cb)
    return hub.upload(upload, cb)
  end)
  assert(not err, err)
  equal(#records(), 2)
end)

test("known Xet download transport failure has one pinned HTTP fallback", function()
  hub.setup(config())
  vim.ui.select = accept
  local err = await(function(cb)
    return hub.download(vim.tbl_extend("force", spec, { repo_id = "example/xet-fail" }), cb)
  end)
  assert(not err, err)
  local rows = records()
  equal(#rows, 3)
  equal(rows[3].config.xet, "disabled")
  equal(rows[3].preview, rows[2].preview)
end)

test("auth failures and upload transport failures are not automatically retried", function()
  hub.setup(config({
    approve_upload = function(p, cb)
      cb(p)
    end,
  }))
  vim.ui.select = accept
  local err = await(function(cb)
    return hub.download(vim.tbl_extend("force", spec, { repo_id = "example/auth-error" }), cb)
  end)
  assert(err)
  equal(#records(), 2)
  err = await(function(cb)
    return hub.upload(vim.tbl_extend("force", upload, { repo_id = "example/xet-fail" }), cb)
  end)
  assert(err)
  equal(#records(), 4)
end)

test("token remains out of subprocess argv JSON status and callbacks", function()
  hub.setup(config())
  local system = vim.system
  vim.env.HF_TOKEN = "hf_ROSE_TEST_NEVER_LOG_THIS"
  vim.system = function(argv, opts, cb)
    assert(not vim.inspect(argv):find(vim.env.HF_TOKEN, 1, true))
    assert(not opts.stdin:find(vim.env.HF_TOKEN, 1, true))
    assert(opts.env.HF_TOKEN == nil)
    equal(argv[2], "-I")
    equal(opts.cwd, "/")
    return system(argv, opts, cb)
  end
  local ok, why = pcall(function()
    local err = await(function(cb)
      return hub.download(vim.tbl_extend("force", spec, { dry_run = true }), cb)
    end)
    assert(not err, err)
    assert(not vim.inspect(hub.status()):find(vim.env.HF_TOKEN, 1, true))
  end)
  vim.system, vim.env.HF_TOKEN = system, nil
  assert(ok, why)
end)

test("native process stop cancels once and bounded active operation", function()
  local progressed = false
  hub.setup(config({
    on_progress = function()
      progressed = true
    end,
  }))
  local calls, cancelled = 0, nil
  local token = hub.download(
    vim.tbl_extend("force", spec, { repo_id = "example/slow" }),
    function(err)
      calls, cancelled = calls + 1, err
    end
  )
  assert(vim.wait(5000, function()
    return progressed
  end, 10))
  local busy = await(function(cb)
    return hub.download(spec, cb)
  end)
  assert(busy:find("another Hub"))
  assert(hub.stop())
  assert(vim.wait(5000, function()
    return calls == 1
  end, 10))
  assert(cancelled:find("cancelled"))
  equal(token.cancel(), false)
  equal(hub.status().state, "cancelled")
end)

test("cancelling pending UI invalidates late approval", function()
  hub.setup(config())
  local select_cb, calls = nil, 0
  vim.ui.select = function(_, _, cb)
    select_cb = cb
  end
  local token = hub.download(spec, function()
    calls = calls + 1
  end)
  assert(vim.wait(5000, function()
    return select_cb ~= nil
  end, 10))
  token.cancel()
  assert(vim.wait(5000, function()
    return calls == 1
  end, 10))
  select_cb("Download exactly this manifest")
  vim.wait(50, function()
    return false
  end, 5)
  equal(#records(), 1)
  equal(calls, 1)
end)

test("paper metadata and repository assets are separate", function()
  hub.setup(config())
  local err, p = await(function(cb)
    return hub.paper({ id = "2501.00001" }, cb)
  end)
  assert(not err, err)
  equal(p.title, "Offline paper")
  equal(records()[1].operation, "paper")
  vim.ui.select = accept
  err = await(function(cb)
    return hub.paper({
      action = "download",
      repo_id = "example/repo",
      files = { "paper.pdf", "cite.bib" },
      destination = "papers",
    }, cb)
  end)
  assert(not err, err)
  equal(#records(), 3)
  err = await(function(cb)
    return hub.paper({
      action = "download",
      repo_id = "example/repo",
      files = { "evil.py" },
      destination = "papers",
    }, cb)
  end)
  assert(err)
  equal(#records(), 3)
end)

test("actual isolated Python helper rejects traversal offline in native subprocess", function()
  hub.setup(config({ python = python }))
  local err = await(function(cb)
    return hub.download(
      { repo_id = "example/repo", files = { "../secret" }, destination = "models", dry_run = true },
      cb
    )
  end)
  assert(err:find("traversal", 1, true), err)
end)

test("optional commands are native explicit and idempotent", function()
  hub.commands()
  hub.commands()
  for _, suffix in ipairs({ "Download", "Upload", "Paper", "Stop", "Status" }) do
    assert(vim.api.nvim_get_commands({})["RoseHub" .. suffix])
  end
end)

vim.ui.select, vim.ui.input, vim.notify = saved_select, saved_input, saved_notify
print(string.format("Hub native: %d passed, %d failed", passed, #failures))
if #failures > 0 then
  for _, failure in ipairs(failures) do
    print(failure)
  end
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
