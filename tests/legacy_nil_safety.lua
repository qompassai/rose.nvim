-- Run: nvim --headless -u NONE -l tests/legacy_nil_safety.lua
-- All historical dependencies are fixtures: no plugins, secrets, processes or network.
local root = vim.env.ROSE_TEST_ROOT
  or vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local passed, failures = 0, {}
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failures[#failures + 1] = name .. ": " .. tostring(err)
    print("FAIL " .. failures[#failures])
  end
end
local function equal(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local function patched(target, key, replacement, fn)
  local previous = target[key]
  target[key] = replacement
  local ok, err = xpcall(fn, debug.traceback)
  target[key] = previous
  assert(ok, err)
end
local function no_process()
  error("unexpected external process")
end
io.popen = no_process
os.execute = no_process
vim.system = no_process
vim.fn.system = no_process
local errors = {}
package.loaded["rose.logger"] = {
  error = function(message)
    errors[#errors + 1] = message
  end,
  debug = function() end,
  info = function() end,
}
package.loaded["rose.utils"] = {
  filter_payload_parameters = function(_, payload)
    return payload
  end,
  parse_raw_response = function(response)
    return type(response) == "table" and table.concat(response, " ") or response
  end,
  uuid = function()
    return "legacy-fixture"
  end,
  undojoin = function() end,
  cursor_to_line = function() end,
  has_valid_key = function(tbl, keys)
    for _, key in ipairs(keys) do
      if tbl[key] ~= nil then
        return true
      end
    end
    return false
  end,
}
local job_result, jobs = nil, 0
package.loaded["plenary.job"] = {
  new = function(_, spec)
    jobs = jobs + 1
    local job = {}
    function job:result()
      return job_result
    end
    function job:start()
      if spec.on_exit then
        spec.on_exit(self)
      end
    end
    function job:wait() end
    function job:sync()
      return job_result
    end
    return job
  end,
}
local function provider(name, key)
  return require("rose.provider." .. name):new("fixture", key)
end
for _, name in ipairs({
  "anthropic",
  "gemini",
  "groq",
  "mistral",
  "nvidia",
  "openai",
  "perplexity",
}) do
  test(name .. " rejects missing keys and preserves string keys", function()
    equal(false, provider(name, nil):verify())
    equal(true, provider(name, "fixture-key"):verify())
  end)
  test(name .. " credential read and close failures close exactly once", function()
    for _, failure in ipairs({ "read", "close", "empty", "none" }) do
      local closed = 0
      patched(io, "popen", function()
        return {
          read = function()
            if failure == "read" then
              return nil, "fixture read error"
            end
            return failure == "empty" and " \n" or " fixture-key\n"
          end,
          close = function()
            closed = closed + 1
            if failure == "close" then
              return nil, "fixture close error"
            end
            return true
          end,
        }
      end, function()
        local instance = provider(name, { "fixture" })
        equal(failure == "none", instance:verify())
        equal(1, closed)
        if failure == "none" then
          equal("fixture-key", instance.api_key)
        else
          equal({ "fixture" }, instance.api_key)
        end
        if failure == "read" or failure == "close" then
          assert(errors[#errors]:find("fixture " .. failure .. " error", 1, true))
        end
      end)
    end
  end)
  test(name .. " credential process unavailable", function()
    patched(io, "popen", function()
      return nil, "fixture open error"
    end, function()
      equal(false, provider(name, { "fixture" }):verify())
      assert(errors[#errors]:find("fixture open error", 1, true))
    end)
  end)
  test(name .. " rejects malformed exit shapes", function()
    for _, text in ipairs({
      "null",
      "false",
      "1",
      '{"error":true}',
      '{"choices":[true]}',
      '{"data":{"detail":[true]}}',
    }) do
      equal(nil, provider(name, "fixture-key"):process_onexit(text))
    end
  end)
end
for _, name in ipairs({ "openai", "groq", "mistral", "nvidia", "perplexity" }) do
  test(name .. " stream accepts only nested text content", function()
    local instance = provider(name, "fixture-key")
    for _, choices in ipairs({
      "true",
      "[true]",
      '[{"delta":true}]',
      '[{"delta":{"content":null}}]',
      '[{"delta":{"content":3}}]',
    }) do
      equal(
        nil,
        instance:process_stdout('{"object":"chat.completion.chunk","choices":' .. choices .. "}")
      )
    end
    equal(
      "hello",
      instance:process_stdout(
        '{"object":"chat.completion.chunk","choices":[{"delta":{"content":"hello"}}]}'
      )
    )
  end)
end
for _, name in ipairs({ "openai", "gemini", "groq", "nvidia", "xai" }) do
  test(name .. " model responses may be absent, malformed or valid", function()
    local instance = provider(name, "fixture-key")
    job_result = nil
    equal({}, instance:get_available_models(true))
    local key = (name == "gemini" or name == "xai") and "models" or "data"
    for _, text in ipairs({
      "not JSON",
      "null",
      "false",
      '{"' .. key .. '":true}',
      '{"' .. key .. '":[true,{},{"id":null,"name":null}]}',
    }) do
      job_result = { text }
      equal({}, instance:get_available_models(true))
    end
    local model = name == "gemini" and '{"name":"models/fixture"}' or '{"id":"fixture"}'
    job_result = { '{"' .. key .. '":[' .. model .. "]}" }
    equal({ "fixture" }, instance:get_available_models(true))
    local before = jobs
    assert(#instance:get_available_models(false) > 0)
    equal(before, jobs)
  end)
end
test("Qompass missing and malformed model responses", function()
  local instance = provider("qompass", {})
  instance.rose_installed = false
  local before = jobs
  equal({}, instance:get_available_models())
  equal(before, jobs)
  instance.rose_installed = true
  job_result = nil
  equal({}, instance:get_available_models())
  for _, text in ipairs({ "", "null", "false", '{"models":true}', '{"models":[true,{}]}' }) do
    job_result = { text }
    equal({}, instance:get_available_models())
  end
  job_result = { '{"models":[{"name":"fixture"}]}' }
  equal({ "fixture" }, instance:get_available_models())
end)
test("Anthropic, Gemini and Qompass preserve string response content", function()
  local cases = {
    anthropic = {
      '{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}',
      '{"type":"content_block_delta","delta":{"type":"text_delta","text":null}}',
    },
    gemini = {
      '{"candidates":[{"content":{"parts":[{"text":"hello"}]}}]}',
      '{"text":null,"candidates":[{"content":{"parts":true}}]}',
    },
    qompass = { '{"message":{"content":"hello"}}', '{"message":{"content":null}}' },
  }
  for name, texts in pairs(cases) do
    equal("hello", provider(name, "fixture-key"):process_stdout(texts[1]))
    equal(nil, provider(name, "fixture-key"):process_stdout(texts[2]))
  end
end)
test("Perplexity invalid model, missing messages and missing query result", function()
  local instance = provider("perplexity", "fixture-key")
  local before = jobs
  local function unexpected()
    error("unexpected query callback")
  end
  instance:send_query({ model = "invalid", messages = { { content = "hello" } } }, unexpected)
  instance:send_query({ model = "llama-3.1-70b-instruct" }, unexpected)
  instance:send_query({ model = "llama-3.1-70b-instruct", messages = { true } }, unexpected)
  equal(before, jobs)
  job_result = nil
  instance:send_query({
    model = "llama-3.1-70b-instruct",
    messages = { { role = "user", content = "hello" } },
  }, unexpected)
  assert(errors[#errors]:find("No query response received", 1, true))
end)
test("optional WebSocket factory absence and incompatibility are reported", function()
  local instance = provider("perplexity", "fixture-key")
  local function attempt()
    local before = #errors
    instance:send_query_ws({ model = "llama-3.1-70b-instruct" }, function()
      error("unexpected WebSocket callback")
    end)
    equal(before + 1, #errors)
  end
  patched(package.loaded, "websocket.client", nil, function()
    patched(package.preload, "websocket.client", function()
      error("fixture unavailable")
    end, attempt)
  end)
  for _, factory in ipairs({
    {},
    function()
      error("fixture constructor failed")
    end,
    function()
      return {}
    end,
  }) do
    patched(package.loaded, "websocket.client", factory, attempt)
  end
end)
test("removed response anchor and deleted buffer do not receive late chunks", function()
  local ResponseHandler = require("rose.response_handler")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "original" })
  local handler = ResponseHandler:new({
    get = function()
      return {}
    end,
  }, buffer, nil, 0, false, "", false)
  vim.api.nvim_buf_del_extmark(buffer, handler.ns_id, handler.ex_id)
  handler:handle_chunk("fixture", "unexpected")
  equal({ "original" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  vim.api.nvim_buf_delete(buffer, { force = true })
  handler:handle_chunk("fixture", "ignored")
end)
test("response text, prefix and highlight ranges remain intact", function()
  local ResponseHandler = require("rose.response_handler")
  local buffer = vim.api.nvim_create_buf(false, true)
  local query = {}
  local handler = ResponseHandler:new({
    get = function()
      return query
    end,
  }, buffer, nil, 0, false, "> ", false)
  handler:handle_chunk("fixture", "hello")
  handler:handle_chunk("fixture", " world\nnext")
  equal({ "> hello world", "> next", "" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  equal(0, query.first_line)
  equal(1, query.last_line)
  local marked = false
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(buffer, handler.ns_id, 0, -1, { details = true }))
  do
    if mark[4].hl_group == handler.hl_handler_group and mark[2] <= query.last_line then
      marked = true
      equal(mark[2] + 1, mark[4].end_row)
      equal(0, mark[4].end_col)
    end
  end
  assert(marked)
  vim.api.nvim_buf_delete(buffer, { force = true })
end)

local setup_count, model_count, prompt_args = 0, 0, nil
local handler = {}
function handler:prepare_commands() end
function handler:buf_handler() end
function handler:prompt(...)
  prompt_args = { ... }
end
package.loaded["rose.api"] = {
  pkey = function()
    return "fixture-key"
  end,
}
package.loaded["rose.chat_handler"] = {
  new = function(_, options, configured, names, models, commands)
    setup_count = setup_count + 1
    equal("vsplit", options.toggle_target)
    equal("https://api.openai.com/v1/chat/completions", configured.openai.endpoint)
    equal({ "openai" }, names)
    equal({ "fixture-model" }, models.openai)
    equal("chat_new", commands.ChatNew)
    return handler
  end,
}
package.loaded["rose.provider"] = {
  init_provider = function()
    return {
      get_available_models = function(_, online)
        equal(false, online)
        model_count = model_count + 1
        return { "fixture-model" }
      end,
    }
  end,
}
test("legacy require defers setup and keeps valid defaults for repeated setup", function()
  local config = require("rose.legacy.config")
  equal(false, config.loaded)
  equal(0, setup_count)
  equal(0, model_count)
  local notices, dirs = {}, {}
  patched(vim, "notify", function(text)
    notices[#notices + 1] = text
  end, function()
    for _, opts in ipairs({
      "bad",
      {},
      { providers = {} },
      { providers = { unknown = {} } },
      { providers = { openai = false } },
      { providers = { openai = {} }, chat_dir = false },
    }) do
      config.setup(opts)
      equal(false, config.loaded)
    end
    config.setup(nil) -- An explicit provider selection is required by the legacy validation.
    equal(7, #notices)
  end)
  equal(0, setup_count)
  patched(vim.uv, "fs_lstat", function()
    return nil, "ENOENT"
  end, function()
    patched(vim.fn, "mkdir", function(path)
      dirs[#dirs + 1] = path
      return 1
    end, function()
      patched(vim.api, "nvim_create_user_command", function() end, function()
        local opts = {
          providers = { openai = { api_key = "fixture-key" } },
          hooks = {},
          chat_dir = "/fixture/chat/",
          state_dir = "/fixture/state/",
        }
        config.setup(opts)
        equal(true, config.loaded)
        equal(1, setup_count)
        equal("/fixture/chat", config.options.chat_dir)
        equal("/fixture/state", config.options.state_dir)
        equal("/fixture/chat/", opts.chat_dir)
        equal(nil, config.options.providers)
        equal(nil, config.options.hooks)
        config.Prompt({}, 0, {}, nil, "template")
        assert(prompt_args)
        equal(true, prompt_args[6])
        config.options.toggle_target = "popup"
        config.setup(opts)
        equal(2, setup_count)
        equal(2, model_count)
        equal(4, #dirs)
      end)
    end)
  end)
end)
test("legacy directory errors do not report successful initialization", function()
  package.loaded["rose.legacy.config"] = nil
  local config = require("rose.legacy.config")
  local notice
  patched(vim, "notify", function(text)
    notice = text
  end, function()
    patched(vim.uv, "fs_lstat", function()
      return nil, "ENOENT"
    end, function()
      patched(vim.fn, "mkdir", function()
        error("fixture directory failure")
      end, function()
        config.setup({
          providers = { openai = { api_key = "fixture-key" } },
          chat_dir = "/fixture/chat",
          state_dir = "/fixture/state",
        })
      end)
    end)
  end)
  equal(false, config.loaded)
  assert(type(notice) == "string" and notice:find("fixture directory failure", 1, true))
end)
test("menu stays unavailable in native mode and preserves legacy input conversion", function()
  local menu = require("rose.menu")
  local selections = 0
  patched(vim, "notify", function() end, function()
    patched(vim.ui, "select", function(_, _, callback)
      selections = selections + 1
      callback("enable_spinner")
    end, function()
      patched(package.loaded, "rose.legacy.config", nil, function()
        menu.open()
        equal(0, selections)
      end)
      local config = { loaded = true, options = { enable_spinner = true } }
      patched(package.loaded, "rose.legacy.config", config, function()
        for _, case in ipairs({
          { "false", false },
          { "true", true },
          { "42", 42 },
          { "3.5", 3.5 },
          { "text", "text" },
        }) do
          patched(vim.ui, "input", function(_, callback)
            callback(case[1])
          end, menu.open)
          equal(case[2], config.options.enable_spinner)
        end
        patched(vim.ui, "input", function(_, callback)
          callback(nil)
        end, menu.open)
        equal("text", config.options.enable_spinner)
      end)
    end)
  end)
end)
print(string.format("RESULT %d passed, %d failed", passed, #failures))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
