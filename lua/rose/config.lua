local utils = require("rose.utils")
local ChatHandler = require("rose.chat_handler")
local init_provider = require("rose.provider").init_provider

local M = {
  ui = require("rose.ui"),
  logger = require("rose.logger"),
}
local system_chat_prompt = [[
Act as versatile AI assistant with MD/PhD level expertise in any topic that the user asks for.
When engaging with users, please adhere to the following guidelines to ensure
the highest quality of interaction:

- Admit when unsure by saying 'I don't know.'
- Ask for clarification when needed.
- Use first principles thinking to analyze queries.
- Start with the big picture, then focus on details.
- Apply the Socratic method to enhance understanding.
- Include all necessary code in your responses.
- Stay calm and confident with each task.
]]

local system_command_prompt = [[
You are an AI specializing in teaching learners in medicine and technology.
- When asked a coding question focus your response on helping with technical expertise.
- When asked a medical question focus your response on providing deliberate clinical advising
at lhe level of a MD/PhD.
- When asked a coding question, limit your reply to being solely focused on the code snippet in question.
]]

local topic_prompt = [[
Summarize the topic of our conversation above
in three or four words. Respond only with those words.
]]

local defaults = {
  providers = {
    pplx = {
      api_key = "",
      endpoint = "https://api.perplexity.ai/chat/completions",
      topic_prompt = topic_prompt,
      topic = {
        model = "llama-3.1-70b-instruct",
        params = { max_tokens = 64 },
      },
      params = {
        chat = { temperature = 1.1, top_p = 1 },
        command = { temperature = 1.1, top_p = 1 },
      },
    },
    openai = {
      api_key = "",
      endpoint = "https://api.openai.com/v1/chat/completions",
      topic_prompt = topic_prompt,
      topic = {
        model = "gpt-4o-mini",
        params = { max_completion_tokens = 64 },
      },
      params = {
        chat = { temperature = 1, top_p = 1 },
        command = { temperature = 1, top_p = 1 },
      },
    },
    gemini = {
      api_key = "",
      endpoint = "https://generativelanguage.googleapis.com/v1beta/models/",
      topic_prompt = topic_prompt,
      topic = {
        model = "gemini-1.5-flash",
        params = { maxOutputTokens = 64 },
      },
      params = {
        chat = { temperature = 1.1, topP = 1, topK = 10, maxOutputTokens = 8192 },
        command = { temperature = 0.8, topP = 1, topK = 10, maxOutputTokens = 8192 },
      },
    },
    ollama = {
      endpoint = "http://localhost:11434/api/chat",
      topic_prompt = [[
      Summarize the chat above and only provide a short headline of 2 to 3
      words without any opening phrase like "Sure, here is the summary",
      "Sure! Here's a shortheadline summarizing the chat" or anything similar.
      ]],
      topic = {
        model = "smollm2:135m",
        params = { max_tokens = 32 },
      },
      params = {
        chat = { temperature = 1.5, top_p = 1, num_ctx = 8192, min_p = 0.05 },
        command = { temperature = 1.5, top_p = 1, num_ctx = 8192, min_p = 0.05 },
      },
    },
    anthropic = {
      api_key = "",
      endpoint = "https://api.anthropic.com/v1/messages",
      topic_prompt = "You only respond with 3 to 4 words to summarize the past conversation.",
      topic = {
        model = "claude-3-5-haiku-latest",
        params = { max_tokens = 32 },
      },
      params = {
        chat = { max_tokens = 4096 },
        command = { max_tokens = 4096 },
      },
    },
    mistral = {
      api_key = "",
      endpoint = "https://api.mistral.ai/v1/chat/completions",
      topic_prompt = [[
      Summarize the chat above and only provide a short headline of 3 to 4
      words without any opening phrase like "Sure, here is the summary",
      "Sure! Here's a shortheadline summarizing the chat" or anything similar.
      ]],
      topic = {
        model = "mistral-medium-latest",
        params = {},
      },
      params = {
        chat = { temperature = 0.85, top_p = 1 },
        command = { temperature = 0.85, top_p = 1 },
      },
    },
    groq = {
      api_key = "",
      endpoint = "https://api.groq.com/openai/v1/chat/completions",
      topic_prompt = topic_prompt,
      topic = {
        model = "llama-3.1-8b-instant",
        params = {
          chat = {
            max_tokens = 4096,
            temperature = 1,
          },
        },
      },
      params = {
        chat = { temperature = 1, top_p = 1 },
        command = { temperature = 1, top_p = 1 },
      },
    },
    github = {
      api_key = "",
      endpoint = "https://models.inference.ai.azure.com/chat/completions",
      topic_prompt = topic_prompt,
      topic = {
        model = "gpt-4o-mini",
        params = {},
      },
      params = {
        chat = { temperature = 0.8, top_p = 1 },
        command = { temperature = 0.8, top_p = 1 },
      },
    },
    nvidia = {
      api_key = "",
      endpoint = "https://integrate.api.nvidia.com/v1/chat/completions",
      topic_prompt = topic_prompt,
      topic = {
        model = "nvidia/llama-3.1-nemotron-51b-instruct",
        params = { max_tokens = 64 },
      },
      params = {
        chat = { temperature = 0.85, top_p = 1 },
        command = { temperature = 0.85, top_p = 1 },
      },
    },
    xai = {
      api_key = "",
      endpoint = "https://api.x.ai/v1/chat/completions",
      topic_prompt = topic_prompt,
      topic = {
        model = "grok-beta",
        params = { max_tokens = 64 },
      },
      params = {
        chat = { temperature = 1.1, top_p = 1 },
        command = { temperature = 1.1, top_p = 1 },
      },
    },
  },
  cmd_prefix = "Rose",
  curl_params = {},
  system_prompt = {
    chat = system_chat_prompt,
    command = system_command_prompt,
  },
  state_dir = vim.fn.stdpath("data") .. "/rose/persisted",
  chat_dir = vim.fn.stdpath("data") .. "/rose/chats",
  chat_user_prefix = "🗨:",
  llm_prefix = "🧭:",
  chat_confirm_delete = true,
  online_model_selection = true,
  chat_shortcut_respond = { modes = { "n", "i", "v", "x" }, shortcut = "<C-a><C-a>" },
  chat_shortcut_delete = { modes = { "n", "i", "v", "x" }, shortcut = "<C-a>d" },
  chat_shortcut_stop = { modes = { "n", "i", "v", "x" }, shortcut = "<C-a>s" },
  chat_shortcut_new = { modes = { "n", "i", "v", "x" }, shortcut = "<C-a>c" },
  chat_free_cursor = false,
  chat_prompt_buf_type = false,
  toggle_target = "vsplit",
  user_input_ui = "native",
  style_popup_border = "single",
  style_popup_margin_bottom = 8,
  style_popup_margin_left = 1,
  style_popup_margin_right = 2,
  style_popup_margin_top = 2,
  style_popup_max_width = 160,
  command_prompt_prefix_template = "🌹 {{llm}} ~ ",
  command_auto_select_response = false,
  fzf_lua_opts = {
    ["--ansi"] = true,
    ["--sort"] = "",
    ["--info"] = "inline",
    ["--layout"] = "reverse",
    ["--preview-window"] = "nohidden:right:75%",
  },
  enable_spinner = true,
  spinner_type = "dots",
  chat_template = [[
  # topic: ?
  {{optional}}
  ---

  {{user}}]],
  template_selection = [[
  I have the following content from {{filename}}:

  ```{{filetype}}
  {{selection}}
  ```

  {{command}}
  ]],
  template_rewrite = [[
  I have the following content from {{filename}}:

  ```{{filetype}}
  {{selection}}
  ```

  {{command}}
  Respond exclusively with the snippet that should replace the selection above.
  DO NOT RESPOND WITH ANY TYPE OF COMMENTS, JUST THE CODE!!!
  ]],
  template_append = [[
  I have the following content from {{filename}}:

  ```{{filetype}}
  {{selection}}
  ```

  {{command}}
  Respond exclusively with the snippet that should be appended after the selection above.
  DO NOT RESPOND WITH ANY TYPE OF COMMENTS, JUST THE CODE!!!
  DO NOT REPEAT ANY CODE FROM ABOVE!!!
  ]],
  template_prepend = [[
  I have the following content from {{filename}}:

  ```{{filetype}}
  {{selection}}
  ```

  {{command}}
  Respond exclusively with the snippet that should be prepended before the selection above.
  DO NOT RESPOND WITH ANY TYPE OF COMMENTS, JUST THE CODE!!!
  DO NOT REPEAT ANY CODE FROM ABOVE!!!
  ]],
  template_command = "{{command}}",

  hooks = {
    Info = function(plugin, params)
      local bufnr = vim.api.nvim_create_buf(false, true)
      local copy = vim.deepcopy(plugin)
      for provider, _ in pairs(copy.providers) do
        local s = copy.providers[provider].api_key
        if s and type(s) == "string" then
          copy.providers[provider].api_key = s:sub(1, 3) .. string.rep("*", #s - 6) .. s:sub(-3)
        end
      end
      local plugin_info = string.format("Plugin structure:\n%s", vim.inspect(copy))
      local params_info = string.format("Command params:\n%s", vim.inspect(params))
      local lines = vim.split(plugin_info .. "\n" .. params_info, "\n")
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_win_set_buf(0, bufnr)
    end,
    Log = function(rose, _)
      vim.cmd("edit " .. vim.fn.fnameescape(rose.logger._logfile))
    end,
    Status = function(rose, _)
      local status_info = rose.get_status_info()
      local provider = status_info.is_chat and status_info.prov.chat or status_info.prov.command
      local status = string.format("%s (%s)", provider.name, status_info.model)
      rose.logger.info(string.format("Current provider: %s", status))
    end,
    -- RoseRewrite regenerates the selected text based on comments in it
    Implement = function(rose, params)
      local template = [[
      Consider the following content from {{filename}}:

      ```{{filetype}}
      {{selection}}
      ```

      Please rewrite this according to the contained instructions.
      Respond exclusively with the snippet that should replace the selection above.
      ]]
      local model_obj = rose.get_model("command")
      rose.logger.info("Implementing selection with model: " .. model_obj.name)
      rose.Prompt(params, rose.ui.Target.rewrite, model_obj, nil, template)
    end,
    -- RoseAsk simply provides an answer to a question within a popup window
    Ask = function(rose, params)
      local template = [[
      In light of your existing knowledge base, please generate a response that
      is succinct and directly addresses the question posed. Prioritize accuracy
      and relevance in your answer, drawing upon the most recent information
      available to you. Aim to deliver your response in a concise manner,
      focusing on the essence of the inquiry.
      Question: {{command}}
      ]]
      local model_obj = rose.get_model("command")
      rose.logger.info("Asking model: " .. model_obj.name)
      rose.Prompt(params, rose.ui.Target.popup, model_obj, "🌹 Ask ~ ", template)
    end,
  },
}

M.merge_providers = function(default_providers, user_providers)
  local result = {}
  for provider, config in pairs(user_providers) do
    result[provider] = vim.tbl_deep_extend("force", default_providers[provider] or {}, config)
  end
  return result
end

M.loaded = false
M.options = nil
M.providers = nil
M.hooks = nil
local map = vim.keymap.set
function M.setup(opts)
  if vim.fn.has("nvim-0.10") == 0 then
    return vim.notify("rose.nvim requires Neovim >= 0.10", vim.log.levels.ERROR)
  end

  math.randomseed(os.time())

  local valid_provider_names = vim.tbl_keys(defaults.providers)

  if not opts or not opts.providers then
    vim.notify("Invalid provider configuration: opts.providers is missing", vim.log.levels.ERROR)
    return
  end

  if not utils.has_valid_key(opts.providers, valid_provider_names) then
    return vim.notify("Invalid provider configuration", vim.log.levels.ERROR)
  end

  M.options = vim.tbl_deep_extend("force", {}, defaults, opts or {})
  map("n", "<C-a>c", ":RoseChatNew<CR>", vim.tbl_extend("force", opts, { desc = "🧭 Rose Chat" }))

  -- Rose Toggle Popup Chat
  map("n", "<C-a>t", ":RoseChatToggle<CR>", vim.tbl_extend("force", opts, { desc = "🧭 Rose Toggle Popup Chat" }))

  -- Rose Chat Finder
  map("n", "<C-a>f", ":RoseChatFinder<CR>", vim.tbl_extend("force", opts, { desc = "🧭 Rose Chat Finder" }))

  -- Rose Trigger the API to generate a response
  map("n", "<C-a><C-a>", ":RoseChatRespond<CR>", opts)

  -- Rose Stop the current text generation
  map("n", "<C-a>s", ":RoseStop<CR>", opts)

  -- Rose Delete the current chat file
  map("n", "<C-a>d", ":RoseChatDelete<CR>", opts)

  -- Rose Select Provider
  map("n", "<C-a>p", "<cmd>RoseProvider<CR>", vim.tbl_extend("force", opts, { desc = "🧭Rose Select provider" }))

  -- Rose Switch Model
  map("n", "<C-a>m", ":RoseModel<CR>", vim.tbl_extend("force", opts, { desc = "🧭 Rose Switch model" }))

  -- Rose Print plugin config
  map("n", "<C-a>i", ":RoseInfo<CR>", vim.tbl_extend("force", opts, { desc = "🧭 Rose Print plugin config" }))

  -- Rose Edit local context file
  map("n", "<C-a>e", ":RoseContext<CR>", vim.tbl_extend("force", opts, { desc = "🧭 Rose Edit local context file" }))

  -- Rose Rewrites the visual selection
  map("v", "<C-a>r", ":RoseRewrite<CR>", vim.tbl_extend("force", opts, { desc = "🧭 Rose Rewrite selection" }))

  -- Rose Append text to selection
  map("v", "<C-a>a", ":RoseAppend<CR>", vim.tbl_extend("force", opts, { desc = "🧭 Rose Add to selection" }))

  -- Rose Prepend text to selection
  map("v", "<C-a>p", ":RosePrepend<CR>", vim.tbl_extend("force", opts, { desc = "🧭 Rose Prepend to selection" }))

  -- Rose Repeat last action
  map("n", "<C-a>r", ":RoseRetry<CR>", vim.tbl_extend("force", opts, { desc = "🧭 Rose Repeat last action" }))

  M.providers = M.merge_providers(defaults.providers, opts.providers)
  M.providers = M.merge_providers(defaults.providers, opts.providers)
  M.options.providers = nil
  M.hooks = M.options.hooks
  M.options.hooks = nil

  -- Helper function to resolve symlink using readlink or realpath
  local function resolve_symlink(path)
    -- Use readlink or realpath to get the actual file path
    local handle = io.popen("readlink -f " .. path .. " 2>/dev/null || realpath " .. path .. " 2>/dev/null")
    if handle then
      local result = handle:read("*a")
      handle:close()
      if result then
        return result:gsub("%s+$", "")
      end
    end
    return nil
  end

  local chat_dir = M.options.chat_dir
  local state_dir = M.options.state_dir

  local resolved_chat_dir = resolve_symlink(chat_dir)
  if resolved_chat_dir then
    M.options.chat_dir = resolved_chat_dir
  else
    vim.api.nvim_err_writeln("Error: Failed to resolve symlink for chat_dir: " .. chat_dir)
  end

  local resolved_state_dir = resolve_symlink(state_dir)
  if resolved_state_dir then
    M.options.state_dir = resolved_state_dir
  else
    vim.api.nvim_err_writeln("Error: Failed to resolve symlink for state_dir: " .. state_dir)
  end

  -- Create directories for all config entries ending with "_dir"
  for k, v in pairs(M.options) do
    if type(v) == "string" and k:match("_dir$") then
      local dir = v:gsub("/$", "")
      M.options[k] = dir
      vim.fn.mkdir(dir, "p")
    end
  end

  M.available_providers = vim.tbl_keys(M.providers)

  local available_models = {}
  for _, prov_name in ipairs(M.available_providers) do
    local _prov = init_provider(prov_name, M.providers[prov_name].endpoint, M.providers[prov_name].api_key)
    -- do not make an API call on startup
    available_models[prov_name] = _prov:get_available_models(false)
  end
  M.available_models = available_models

  table.sort(M.available_providers)
  M.register_hooks(M.hooks, M.options)

  M.cmd = {
    ChatFinder = "chat_finder",
    ChatStop = "stop",
    ChatNew = "chat_new",
    ChatToggle = "chat_toggle",
    ChatPaste = "chat_paste",
    ChatDelete = "chat_delete",
    ChatResponde = "chat_respond",
    Context = "context",
    Model = "model",
    Provider = "provider",
    Retry = "retry",
  }

  M.chat_handler = ChatHandler:new(M.options, M.providers, M.available_providers, M.available_models, M.cmd)
  M.chat_handler:prepare_commands()
  M.add_default_commands(M.cmd, M.hooks, M.options)
  M.chat_handler:buf_handler()

  M.loaded = true

  M.Prompt = function(params, target, provider, model_obj, prompt, template)
    M.chat_handler:prompt(params, target, provider, model_obj, prompt, template)
  end

  M.ChatNew = function(params, chat_prompt)
    M.chat_handler:chat_new(params, chat_prompt)
  end

  M.get_model = function(model_type)
    return M.chat_handler:get_model(model_type)
  end

  M.get_status_info = function()
    return M.chat_handler:get_status_info()
  end

  M.register_hooks = function(hooks, options)
    -- register user commands
    for hook, _ in pairs(hooks) do
      vim.api.nvim_create_user_command(options.cmd_prefix .. hook, function(params)
        M.call_hook(hook, params)
      end, { nargs = "?", range = true, desc = "Rose LLM plugin" })
    end
  end

  -- hook caller
  M.call_hook = function(name, params)
    if M.hooks[name] ~= nil then
      return M.hooks[name](M, params)
    end
    M.logger.error("The hook '" .. name .. "' does not exist.")
  end

  M.add_default_commands = function(commands, hooks, options)
    local completions = {
      ChatNew = { "popup", "split", "vsplit", "tabnew" },
      ChatPaste = { "popup", "split", "vsplit", "tabnew" },
      ChatToggle = { "popup", "split", "vsplit", "tabnew" },
      Context = { "popup", "split", "vsplit", "tabnew" },
    }
    -- register default commands
    for cmd, cmd_func in pairs(commands) do
      if hooks[cmd] == nil then
        vim.api.nvim_create_user_command(options.cmd_prefix .. cmd, function(params)
          M.chat_handler[cmd_func](M.chat_handler, params)
        end, {
          nargs = "?",
          range = true,
          desc = "Rose LLM plugin: " .. cmd,
          complete = function()
            if completions[cmd] then
              return completions[cmd]
            end
            if cmd == "Model" then
              return M.available_models[M.chat_handler.state:get_provider()]
            elseif cmd == "Provider" then
              return M.available_providers
            end
            return {}
          end,
        })
      end
    end
  end
end
return M
