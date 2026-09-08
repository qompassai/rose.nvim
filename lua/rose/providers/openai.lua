return {
  host = "api.openai.com",
  key_env = "OPENAI_API_KEY",
  apis = {
    responses = { path = "/responses", format = "responses", tools = true },
    chat = { path = "/chat/completions", format = "chat", tools = true },
  },
}
