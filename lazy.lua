return {
  "qompassai/rose.nvim",
  lazy = true,
  event = "VeryLazy",
  dependencies = {
    "MunifTanjim/nui.nvim",
    "nvim-lua/plenary.nvim",
  },
  opts = function()
    local topic_prompt = [[
    Summarize the chat above and only provide a short headline of 2 to 3
    words without any opening phrase like "Sure, here is the summary",
    "Sure! Here's a shortheadline summarizing the chat" or anything similar.
    ]]

    local system_chat_prompt = "You are a helpful AI assistant."
    local system_command_prompt = "You are a helpful AI assistant."

    return {
      providers = {
        pplx = {
          api_key = require("rose.api").pkey("api/perplexity"),
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
          api_key = require("rose.api").pkey("api/groq"),
          endpoint = "https://api.openai.com/v1/chat/completions",
          topic_prompt = topic_prompt,
          topic = {
            model = "gpt-4o-mini",
            params = { max_completion_tokens = 64 },
          },
          params = {
            chat = { temperature = 1.1, top_p = 1 },
            command = { temperature = 1.1, top_p = 1 },
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
        qompass = {
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
      llm_prefix = "🌹:",
      chat_confirm_delete = true,
      online_model_selection = true,
      chat_shortcut_respond = { modes = { "n", "i", "v", "x" }, shortcut = "<leader>ar" },
      chat_shortcut_delete = { modes = { "n", "i", "v", "x" }, shortcut = "<leader>ad" },
      chat_shortcut_stop = { modes = { "n", "i", "v", "x" }, shortcut = "<leader>as" },
      chat_shortcut_new = { modes = { "n", "i", "v", "x" }, shortcut = "<leader>ac" },
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
      command_prompt_prefix_template = "🤖 {{llm}} ~ ",
      command_auto_select_response = true,
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

      ```
      {{selection}}
      ```

      {{command}}
      ]],
      template_rewrite = [[
      I have the following content from {{filename}}:

      ```
      {{selection}}
      ```

      {{command}}
      Respond exclusively with the snippet that should replace the selection above.
      DO NOT RESPOND WITH ANY TYPE OF COMMENTS, JUST THE CODE!!!
      ]],
      template_append = [[
      I have the following content from {{filename}}:

      ```
      {{selection}}
      ```

      {{command}}
      Respond exclusively with the snippet that should be appended after the selection above.
      DO NOT RESPOND WITH ANY TYPE OF COMMENTS, JUST THE CODE!!!
      DO NOT REPEAT ANY CODE FROM ABOVE!!!
      ]],
      template_prepend = [[
      I have the following content from {{filename}}:

      ```
      {{selection}}
      ```

      {{command}}
      Respond exclusively with the snippet that should be prepended before the selection above.
      DO NOT RESPOND WITH ANY TYPE OF COMMENTS, JUST THE CODE!!!
      DO NOT REPEAT ANY CODE FROM ABOVE!!!
      ]],
      template_command = "{{command}}",

      default_provider = "qompass",
    }
  end,
  config = function(_, opts)
    local ok, binary = pcall(require, "rose.rose")
    if ok then
      binary.init()
    end

    require("rose").setup(opts)

    vim.api.nvim_create_user_command("RoseDownload", function()
      local rose = require("rose.rose")
      rose.rose_dl()
    end, { desc = "Download Rose binary" })
  end,
}
