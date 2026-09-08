local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
local debug = require("rose.debug")
local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")
vim.fn.writefile({ "value = 42", "print(value)" }, workspace .. "/probe.py")
local python = vim.env.ROSE_TEST_PYTHON or "python3"
local fake = root .. "/tests/fixtures/dap_adapter.py"
local function config(cmd, launch, timeout)
  return {
    workspace = workspace,
    trusted = true,
    debug = {
      adapters = { test = { cmd = cmd } },
      configurations = {
        probe = {
          adapter = "test",
          launch = launch or {},
          breakpoints = { ["probe.py"] = { 2 } },
          timeout = timeout or 10000,
        },
      },
    },
  }
end
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
debug.setup(config({ python, fake }))
local result = debug.call({ action = "run", name = "probe" })
check(result.status == "ok", vim.inspect(result))
check(result.verified == false and result.stopped.reason == "breakpoint", "No false test claim")
check(result.stack.stackFrames[1].name == "probe", "Stack trace captured")
check(result.scopes.scopes[1].name == "Locals", "Scopes captured")
check(debug.status().active == false, "Session cleaned up")
debug.setup(config({ python, fake, "--reject" }))
check(debug.call({ action = "run", name = "probe" }).status == "error", "Adapter errors surfaced")
debug.setup(config({ python, fake, "--hang" }, {}, 150))
check(debug.call({ action = "run", name = "probe" }).status == "timeout", "Timeout surfaced")
local settings = config({ python, fake })
settings.trusted = false
debug.setup(settings)
check(debug.call({ action = "run", name = "probe" }).status == "error", "Trust required")
debug.setup(config({ "rose-impossible-debug-adapter" }))
check(
  debug.call({ action = "run", name = "probe" }).status == "unavailable",
  "Missing adapter explicit"
)
debug.setup(config({ python, fake }))
check(
  debug.call({ action = "run", name = "probe", command = "sh" }).status == "error",
  "Model argv denied"
)
if vim.env.ROSE_TEST_DEBUGPY == "1" then
  debug.setup(config({ python, "-m", "debugpy.adapter" }, {
    program = "${workspaceFolder}/probe.py",
    python = python,
    console = "internalConsole",
    justMyCode = true,
  }, 20000))
  local live = debug.call({ action = "run", name = "probe" })
  check(live.status == "ok" and live.stopped ~= nil, "Real debugpy: " .. vim.inspect(live))
  check(#live.stack.stackFrames > 0, "Real debugpy stack")
end
vim.fn.delete(workspace, "rf")
print(("DAP tests: %d passed"):format(count))
vim.cmd("qa!")
