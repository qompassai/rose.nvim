return {
  "qompassai/rose.nvim",
  lazy = true,
  event = "VeryLazy",
  dependencies = {
    "MunifTanjim/nui.nvim",
    "nvim-lua/plenary.nvim",
  },
  opts = {
    default_provider = "qompass",
    providers = {
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
      -- TODO: Add other providers
    },

    cmd_prefix = "Rose",
    chat_user_prefix = "🗨:",
    llm_prefix = "🌹:",
  },
  config = function(_, opts)
    local ok, binary = pcall(require, "rose.rose")
    if ok then
      binary.init()
    end

    require("rose").setup(opts)
  end,
}
