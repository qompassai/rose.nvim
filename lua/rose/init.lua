local M = {}

M.did_setup = false

local default_opts = {
  providers = { "ollama" },
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
}

---@param opts? table
function M.setup(opts)
  if M.did_setup then
    return
  end
  M.did_setup = true

  opts = vim.tbl_deep_extend("force", default_opts, opts or {})

  require("rose.config").setup(opts)
end

return M
