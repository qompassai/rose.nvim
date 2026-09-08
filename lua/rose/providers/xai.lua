return {
  host = "api.x.ai",
  key_env = "XAI_API_KEY",
  apis = {
    responses = { path = "/responses", format = "responses", tools = true },
    chat = { path = "/chat/completions", format = "chat", tools = true },
  },
}
