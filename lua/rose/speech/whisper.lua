-- whisper.cpp server (`whisper-server`), local speech-to-text over loopback HTTP.
-- Wire format: POST /inference multipart with `file` and `response_format=json`
-- returning `{ text }`. The server is never started or installed by Rose; the
-- user runs it and points `speech.whisper.url` at it.
local M = {
  name = "whisper",
  -- The model is chosen when the server is started; requests cannot select it.
  stt = { path = "/inference", model = nil },
}

-- Field order mirrors the cloud descriptors: options first, `file` last.
function M.stt_form(upload, model, language)
  assert(type(upload) == "table", "upload must be a table")
  assert(type(upload.path) == "string", "upload.path must be a string")
  assert(type(upload.mime) == "string", "upload.mime must be a string")
  assert(type(upload.filename) == "string", "upload.filename must be a string")
  assert(model == nil, "whisper.cpp selects its model at server start")
  assert(language == nil or type(language) == "string", "language must be a string or nil")
  local entries = { { name = "response_format", value = "json" } }
  if language then
    entries[#entries + 1] = { name = "language", value = language }
  end
  entries[#entries + 1] = {
    name = "file",
    path = upload.path,
    mime = upload.mime,
    filename = upload.filename,
  }
  assert(entries[#entries].name == "file", "file must be the last multipart field")
  return entries
end

function M.stt_decode(response)
  assert(type(response) == "table", "response must be a decoded JSON table")
  if type(response.text) ~= "string" then
    return nil, "whisper.cpp response has no text"
  end
  return { text = response.text, duration = nil }
end

return M
