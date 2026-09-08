-- OpenAI speech endpoints, verified against the official guides on 2026-09-08:
-- https://developers.openai.com/api/docs/guides/speech-to-text
-- https://developers.openai.com/api/docs/guides/text-to-speech
-- Requests are host-bound to api.openai.com; the key is read from OPENAI_API_KEY
-- only at request time by rose.speech.http.
local M = {
  name = "openai",
  host = "api.openai.com",
  endpoint = "https://api.openai.com/v1",
  key_env = "OPENAI_API_KEY",
  stt = { path = "/audio/transcriptions", model = "gpt-4o-mini-transcribe" },
  tts = {
    path = "/audio/speech",
    model = "gpt-4o-mini-tts",
    voice = "marin",
    -- The speech endpoint accepts at most 4096 input characters.
    text_chars_max = 4096,
    mime = { mp3 = "audio/mpeg", wav = "audio/wav" },
  },
}

-- Multipart fields for POST /v1/audio/transcriptions. `file` goes last so the
-- same ordering rule as xAI applies everywhere; OpenAI itself does not care.
function M.stt_form(upload, model, language)
  assert(type(upload) == "table", "upload must be a table")
  assert(type(upload.path) == "string", "upload.path must be a string")
  assert(type(upload.mime) == "string", "upload.mime must be a string")
  assert(type(upload.filename) == "string", "upload.filename must be a string")
  assert(type(model) == "string", "model must be a string")
  assert(language == nil or type(language) == "string", "language must be a string or nil")
  local entries = {
    { name = "model", value = model },
    { name = "response_format", value = "json" },
  }
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

-- `{ text }` is the documented json response shape; anything else is an error.
function M.stt_decode(response)
  assert(type(response) == "table", "response must be a decoded JSON table")
  if type(response.text) ~= "string" then
    return nil, "OpenAI transcription response has no text"
  end
  return { text = response.text, duration = nil }
end

-- JSON body for POST /v1/audio/speech. The response is raw audio.
function M.tts_body(text, model, voice, format)
  assert(type(text) == "string", "text must be a string")
  assert(#text >= 1, "text must not be empty")
  assert(#text <= M.tts.text_chars_max, "text exceeds the OpenAI speech limit")
  assert(type(model) == "string", "model must be a string")
  assert(type(voice) == "string", "voice must be a string")
  assert(M.tts.mime[format], "format must be mp3 or wav")
  return { model = model, voice = voice, input = text, response_format = format }
end

return M
