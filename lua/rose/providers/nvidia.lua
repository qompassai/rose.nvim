return {
  host = "integrate.api.nvidia.com",
  key_env = "NVIDIA_API_KEY",
  apis = { chat = { path = "/chat/completions", format = "chat", tools = true } },
}
