-- Native entrypoint: requiring or setting up Rose never loads legacy providers.
local M = { did_setup = false, operations = {}, generation = 0 }
local command_names = {
  "RoseAsk",
  "RoseAgent",
  "RoseCheck",
  "RoseFlow",
  "RoseStop",
  "RoseHubDownload",
  "RoseHubUpload",
  "RoseHubPaper",
  "RoseHubStop",
  "RoseHubStatus",
  "RoseWebUI",
  "RoseWebUIStop",
  "RoseWebUIStatus",
}
local writing_kinds =
  { Agent = true, Flow = true, HubDownload = true, HubUpload = true, HubPaper = true }

local function notify_error(err)
  vim.notify("Rose: " .. tostring(err), vim.log.levels.ERROR)
end

local function ready()
  if not M.did_setup then
    local ok, err = M.setup()
    if not ok then
      return nil, err
    end
  end
  if M.legacy then
    return nil, "native commands are unavailable in legacy mode"
  end
  return true
end

local function source_buffer()
  local current = vim.api.nvim_get_current_buf()
  local ui = package.loaded["rose.native.ui"]
  if not ui or current ~= ui.buffer then
    M.context_buf = current
  end
  return M.context_buf
end

local function prompt(text, label, action)
  if text and not text:match("^%s*$") then
    action(text)
    return
  end
  source_buffer()
  vim.ui.input({ prompt = label .. ": " }, function(input)
    if input and not input:match("^%s*$") then
      action(input)
    end
  end)
end

local function operation(kind, callback, start)
  local ok, err = ready()
  if not ok then
    if callback then
      callback(err)
    else
      notify_error(err)
    end
    return
  end
  if writing_kinds[kind] and M.writer then
    err = "a writing workflow is already running; use :RoseStop before starting another"
    if callback then
      callback(err)
    else
      notify_error(err)
    end
    return
  end
  local context = source_buffer()
  local generation, slot = M.generation, {}
  M.operations[slot] = true
  if writing_kinds[kind] then
    M.writer = slot
  end
  local completed = false
  local function done(call_err, result)
    if completed then
      return
    end
    completed = true
    M.operations[slot] = nil
    if M.writer == slot then
      M.writer = nil
    end
    if generation ~= M.generation then
      if callback then
        callback(call_err or "cancelled", result)
      end
      return
    end
    if callback then
      callback(call_err, result)
    else
      local text = call_err and ("Error: " .. tostring(call_err))
        or (type(result) == "string" and result or vim.inspect(result))
      require("rose.native.ui").append(kind, text)
    end
  end
  local started, token = pcall(start, done, context)
  if not started then
    done(tostring(token))
    return
  end
  slot.token = token
  return token
end

function M.ask(text, callback)
  if not text then
    prompt(nil, "RoseAsk", function(value)
      M.ask(value, callback)
    end)
    return
  end
  return operation("Ask", callback, function(done)
    if type(text) ~= "string" or text:match("^%s*$") then
      done("question must not be empty")
      return
    end
    if M.ask_pending then
      done("a chat request is already running; use :RoseStop first")
      return
    end
    M.ask_pending = true
    local messages = vim.deepcopy(M.chat_history or {
      {
        role = "system",
        content = "You are Rose, a coding assistant. Answer honestly. This chat has no tools; do "
          .. "not claim you edited files or ran checks.",
      },
    })
    messages[#messages + 1] = { role = "user", content = text }
    while #vim.json.encode(messages) > M.options.agent.max_context and #messages > 2 do
      table.remove(messages, 2)
    end
    if #vim.json.encode(messages) > M.options.agent.max_context then
      M.ask_pending = false
      done("chat context size limit exceeded")
      return
    end
    if not callback then
      require("rose.native.ui").append("You", text)
    end
    local generation = M.generation
    return require("rose.native.model").chat(M.options, messages, nil, function(err, message)
      if generation == M.generation then
        M.ask_pending = false
      end
      if
        not err and (not message or type(message.content) ~= "string" or message.content == "")
      then
        err = "Model returned no chat text (RoseAsk does not execute tools)"
      end
      if not err and generation == M.generation then
        -- Opaque provider replay metadata stays private in memory; never print it.
        local assistant = vim.deepcopy(message)
        assistant.role = "assistant"
        messages[#messages + 1] = assistant
        M.chat_history = messages
      end
      done(err, message and message.content)
    end)
  end)
end

function M.agent(task, callback)
  if not task then
    prompt(nil, "RoseAgent", function(value)
      M.agent(value, callback)
    end)
    return
  end
  return operation("Agent", callback, function(done, context)
    if M.tool_error then
      done(M.tool_error)
      return
    end
    if not callback then
      require("rose.native.ui").append("Task", task)
    end
    return require("rose.native.agent").run(M.options, task, done, {
      context_buf = context,
      on_event = not callback and function(event)
        require("rose.native.ui").append("Agent", event)
      end or nil,
    })
  end)
end

function M.check(name, callback)
  return operation("Check", callback, function(done, context)
    if M.tool_error then
      done(M.tool_error)
      return
    end
    return require("rose.native.validation").run(
      M.options,
      require("rose.tools"),
      name,
      done,
      context
    )
  end)
end

function M.flow(task, callback)
  if not task then
    prompt(nil, "RoseFlow", function(value)
      M.flow(value, callback)
    end)
    return
  end
  return operation("Flow", callback, function(done, context)
    if M.tool_error and M.options.flow.bridge ~= false then
      done(M.tool_error)
      return
    end
    -- Keep a real project buffer active when Flow first attaches. Native Rose
    -- tools use explicit captured buffers; Flow captures editor_context itself.
    if context and vim.api.nvim_buf_is_valid(context) then
      local window = vim.fn.bufwinid(context)
      if window ~= -1 then
        vim.api.nvim_set_current_win(window)
      end
    end
    if not callback then
      require("rose.native.ui").append("Flow task", task)
    end
    return require("rose.native.flow").call("flow_run", { task = task }, done)
  end)
end

function M.mcp(server_name, tool_name, args, callback)
  assert(type(callback) == "function", "mcp requires callback(err, result)")
  return operation("MCP", callback, function(done)
    return require("rose.native.servers").call(server_name, tool_name, args, done)
  end)
end

function M.model_request(request, callback)
  assert(type(callback) == "function", "model_request requires callback(err, result)")
  return operation("Model API", callback, function(done)
    return require("rose.native.model").request(M.options, request, done)
  end)
end

local function configure_hub()
  local ok, hub = pcall(require, "rose.hub")
  if not ok then
    M.hub_error = "Hugging Face module unavailable"
    return nil
  end
  local configured, err = pcall(
    hub.setup,
    vim.tbl_extend("force", M.options.hub, {
      workspace = M.options.workspace,
      trusted = M.options.trusted,
    })
  )
  if configured then
    M.hub_error = nil
  else
    M.hub_error = tostring(err)
  end
  return configured and hub or nil
end

local function hub_transfer(kind, method, spec, callback)
  return operation(kind, callback, function(done)
    local hub = configure_hub()
    if not hub then
      done(M.hub_error)
      return
    end
    return hub[method](spec, done)
  end)
end

function M.hub_download(spec, callback)
  return hub_transfer("HubDownload", "download", spec, callback)
end
function M.hub_upload(spec, callback)
  return hub_transfer("HubUpload", "upload", spec, callback)
end
function M.hub_paper(spec, callback)
  return hub_transfer("HubPaper", "paper", spec, callback)
end

function M.stop()
  local slots = {}
  for slot in pairs(M.operations) do
    slots[#slots + 1] = slot
  end
  for _, slot in ipairs(slots) do
    if slot.token and slot.token.cancel then
      pcall(slot.token.cancel)
    end
  end
  -- Tokens complete only when their execution fence is satisfied. In particular,
  -- Flow keeps the writer slot until its process has actually exited.
  M.ask_pending = false
  for _, name in ipairs({
    "rose.native.http",
    "rose.native.servers",
    "rose.native.flow",
    "rose.native.mcp",
    "rose.native.model",
    "rose.webui",
    "rose.hub",
    "rose.debug",
  }) do
    local module = package.loaded[name]
    if module and module.stop then
      pcall(module.stop)
    end
  end
  -- Speech owns recorder/player/piper processes and in-flight uploads; stop them too.
  local speech_ok, speech = pcall(require, "rose.speech")
  if speech_ok then
    speech.stop()
  end
end

function M.shutdown()
  M.generation = M.generation + 1
  M.stop()
  local webui = package.loaded["rose.webui"]
  if webui then
    pcall(webui.shutdown)
  end
  local ui = package.loaded["rose.native.ui"]
  if ui then
    ui.close()
  end
  for _, name in ipairs(command_names) do
    pcall(vim.api.nvim_del_user_command, name)
  end
  pcall(vim.api.nvim_del_augroup_by_name, "RoseNative")
  M.did_setup, M.context_buf, M.chat_history = false, nil, nil
end

function M.register_commands()
  for _, item in ipairs({
    { "RoseAsk", M.ask, "Ask the configured model (local Rose by default)" },
    { "RoseAgent", M.agent, "Run planner, coder, validation and reviewer" },
    { "RoseFlow", M.flow, "Run the explicit Flow MCP workflow" },
  }) do
    vim.api.nvim_create_user_command(item[1], function(args)
      item[2](args.args ~= "" and args.args or nil)
    end, { nargs = "*", desc = item[3], force = true })
  end
  vim.api.nvim_create_user_command("RoseCheck", function(args)
    M.check(args.args ~= "" and args.args or nil)
  end, {
    nargs = "?",
    desc = "Run required named validation checks",
    force = true,
    complete = function()
      local names = vim.tbl_keys(M.options and M.options.checks or {})
      table.sort(names)
      return names
    end,
  })
  vim.api.nvim_create_user_command("RoseStop", function()
    M.stop()
  end, { desc = "Cancel Rose requests and close MCP/Flow bridges", force = true })
  for _, item in ipairs({
    { "RoseHubDownload", M.hub_download, "download" },
    { "RoseHubUpload", M.hub_upload, "upload" },
    { "RoseHubPaper", M.hub_paper, "paper metadata or assets" },
  }) do
    vim.api.nvim_create_user_command(item[1], function()
      local ok, err = ready()
      if not ok then
        notify_error(err)
        return
      end
      vim.ui.input({ prompt = "Rose Hub " .. item[3] .. " JSON specification: " }, function(input)
        if not input then
          return
        end
        local parsed, spec = pcall(vim.json.decode, input)
        if not parsed or type(spec) ~= "table" then
          notify_error("invalid Hub JSON specification")
          return
        end
        item[2](spec)
      end)
    end, { desc = "Explicit Hugging Face " .. item[3], force = true })
  end
  vim.api.nvim_create_user_command("RoseHubStop", function()
    local hub = package.loaded["rose.hub"]
    if hub then
      hub.stop()
    end
  end, { desc = "Cancel Hugging Face transfer", force = true })
  vim.api.nvim_create_user_command("RoseHubStatus", function()
    local hub = package.loaded["rose.hub"]
    vim.notify(vim.inspect(hub and hub.status() or { state = "idle" }))
  end, { desc = "Show Hugging Face transfer state", force = true })
end

-- Legacy mode is an isolated historical snapshot; native setup never continues past it.
local function setup_legacy(opts)
  M.shutdown()
  M.legacy = true
  vim.notify(
    "Rose legacy mode is an unsupported historical snapshot: it may read secrets, "
      .. "require plugins/builds, and has known configuration defects. See docs/legacy.md.",
    vim.log.levels.WARN
  )
  local ok, err = pcall(function()
    require("rose.legacy.init").setup(opts)
  end)
  M.did_setup = ok
  if not ok then
    notify_error("legacy setup failed: " .. tostring(err))
    return nil, err
  end
  return M
end

-- Optional modules record their failure instead of aborting setup so :checkhealth can report it.
local function setup_optional_modules(config)
  assert(type(config) == "table", "setup_optional_modules: config must be a table")
  M.tool_error = nil
  local tools_ok, tools = pcall(require, "rose.tools")
  if tools_ok and type(tools.setup) == "function" then
    local setup_ok, setup_err = pcall(tools.setup, config)
    if not setup_ok then
      M.tool_error = "native tools setup failed: " .. tostring(setup_err)
    end
  else
    M.tool_error = "native tools unavailable: " .. tostring(tools)
  end
  local debug_ok, debug = pcall(require, "rose.debug")
  if debug_ok and type(debug.setup) == "function" then
    debug.setup(config)
  end
  require("rose.native.flow").setup(config)
  require("rose.native.servers").setup(config)
  -- Speech registers its commands only; it spawns nothing and reads no keys here.
  require("rose.speech").setup(config)
  M.webui_error = nil
  local webui_ok, webui_error = pcall(function()
    require("rose.webui").setup(config)
  end)
  if not webui_ok then
    M.webui_error = tostring(webui_error)
  end
  configure_hub()
end

local function notify_setup_warnings(config, router)
  if router then
    local info = router.describe(config)
    if info.cloud then
      vim.notify(
        "Rose cloud mode: tasks, source context and tool output will leave this device "
          .. "for the explicitly configured "
          .. info.provider
          .. " endpoint.",
        vim.log.levels.WARN
      )
    end
  end
  if type(vim.system) ~= "function" then
    vim.notify(
      "Rose: vim.system unavailable; chat/MCP/checks require Neovim 0.10+. "
        .. "Native UI remains available.",
      vim.log.levels.WARN
    )
  end
end

---Configure native Rose. See :help rose-config and docs/configuration.md.
---@param opts? Rose.Config Partial native options; omitted fields retain defaults.
function M.setup(opts)
  opts = opts or {}
  assert(type(opts) == "table", "Rose setup options must be a table")
  if opts.legacy == true then
    return setup_legacy(opts)
  end
  local config_ok, config = pcall(require("rose.config").resolve, opts)
  if not config_ok then
    notify_error(config)
    return nil, config
  end
  local router_ok, router = pcall(require, "rose.native.model")
  if router_ok then
    local valid, why = router.validate(config)
    if not valid then
      notify_error(why)
      return nil, why
    end
  elseif config.providers.provider ~= "rose" and config.providers.provider ~= "ollama" then
    local why = "cloud provider router unavailable"
    notify_error(why)
    return nil, why
  end
  M.shutdown()
  M.legacy, M.options = false, config
  require("rose.config").options = config
  setup_optional_modules(config)
  M.register_commands()
  local group = vim.api.nvim_create_augroup("RoseNative", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.shutdown })
  M.did_setup = true
  notify_setup_warnings(config, router_ok and router or nil)
  assert(M.options == config, "setup must publish the resolved config")
  return M
end

-- Historical binary helpers do not load binary/build modules in native mode.
function M.rose_check()
  return false
end
function M.get_binary_path()
  return nil
end

return M
