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
      default_provider = "qompass",

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
          api_key = require("rose.api").pkey("api/mistral"),
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
            chat = { temperature = 1.5, top_p = 1 },
            command = { temperature = 1.5, top_p = 1 },
          },
        },
        groq = {
          api_key = require("rose.api").pkey("api/groq"),
          endpoint = "https://api.groq.com/openai/v1/chat/completions",
          topic_prompt = topic_prompt,
          topic = {
            model = "llama-3.1-8b-instant",
            params = {
              chat = { temperature = 1.0, top_p = 1 },
              command = { temperature = 1.0, top_p = 1 },
            },
          },
          params = {
            chat = { temperature = 1.5, top_p = 1 },
            command = { temperature = 1.5, top_p = 1 },
          },
        },
        github = {
          api_key = require("rose.api").pkey("api/gh"),
          endpoint = "https://models.inference.ai.azure.com/chat/completions",
          topic_prompt = topic_prompt,
          topic = {
            model = "gpt-4o-mini",
            params = {},
          },
          params = {
            chat = { temperature = 0.7, top_p = 1 },
            command = { temperature = 0.7, top_p = 1 },
          },
        },
        nvidia = {
          api_key = require("rose.api").pkey("api/nvidia"),
          endpoint = "https://integrate.api.nvidia.com/v1/chat/completions",
          topic_prompt = topic_prompt,
          topic = {
            model = "nvidia/llama-3.1-nemotron-51b-instruct",
            params = { max_tokens = 64 },
          },
          params = {
            chat = { temperature = 1.1, top_p = 1 },
            command = { temperature = 1.1, top_p = 1 },
          },
        },
        xai = {
          api_key = require("rose.api").pkey("api/xai"),
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
      system_prompt = {
        chat = system_chat_prompt,
        command = system_command_prompt,
      },
      state_dir = vim.fn.stdpath("data") .. "/rose/persisted",
      chat_dir = vim.fn.stdpath("data") .. "/rose/chats",
      chat_user_prefix = "🗨:",
      llm_prefix = "🌹:",
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

