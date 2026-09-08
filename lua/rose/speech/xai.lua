-- xAI speech endpoints, verified against the official docs on 2026-09-08:
-- https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
-- https://docs.x.ai/developers/model-capabilities/audio/text-to-speech
-- Requests are host-bound to api.x.ai; the key is read from XAI_API_KEY only at
-- request time by rose.speech.http.
local M = {
  name = "xai",
  host = "api.x.ai",
  endpoint = "https://api.x.ai/v1",
  key_env = "XAI_API_KEY",
  -- xAI selects the transcription model server-side; there is no model field.
  stt = { path = "/stt", model = nil },
  tts = {
    path = "/tts",
    model = nil,
    voice = "eve",
    -- Documented request limit for the `text` field.
    text_chars_max = 15000,
    mime = { mp3 = "audio/mpeg", wav = "audio/wav" },
    sample_rate = 24000,
  },
}

-- Multipart fields for POST /v1/stt. xAI parses option fields before the
-- audio, so `file` MUST be the last field; the fixture asserts this order.
function M.stt_form(upload, model, language)
  assert(type(upload) == "table", "upload must be a table")
  assert(type(upload.path) == "string", "upload.path must be a string")
  assert(type(upload.mime) == "string", "upload.mime must be a string")
  assert(type(upload.filename) == "string", "upload.filename must be a string")
  assert(model == nil, "xAI speech-to-text has no model field")
  assert(language == nil or type(language) == "string", "language must be a string or nil")
  local entries = {}
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

-- Documented response: `{ text, language, duration, words }`.
function M.stt_decode(response)
  assert(type(response) == "table", "response must be a decoded JSON table")
  if type(response.text) ~= "string" then
    return nil, "xAI transcription response has no text"
  end
  local duration = nil
  if type(response.duration) == "number" then
    duration = response.duration
  end
  return { text = response.text, duration = duration }
end

-- JSON body for POST /v1/tts. `language` is required; "auto" is documented as
-- acceptable. The response is raw audio in the requested codec.
function M.tts_body(text, model, voice, format)
  assert(type(text) == "string", "text must be a string")
  assert(#text >= 1, "text must not be empty")
  assert(#text <= M.tts.text_chars_max, "text exceeds the xAI speech limit")
  assert(model == nil, "xAI text-to-speech has no model field")
  assert(type(voice) == "string", "voice must be a string")
  assert(M.tts.mime[format], "format must be mp3 or wav")
  return {
    text = text,
    voice_id = voice,
    language = "auto",
    output_format = { codec = format, sample_rate = M.tts.sample_rate },
  }
end

return M
