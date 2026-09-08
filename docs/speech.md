# Speech: dictation and read-aloud

`require("rose.speech")` adds speech-to-text (STT) and text-to-speech (TTS) to
Rose without new runtime dependencies: recording and playback shell out to a
tool you already have, cloud requests reuse the hardened curl transport from
`lua/rose/providers/transport.lua`, and local engines (whisper.cpp, piper) are
used only when you configure them. Nothing is auto-installed or auto-downloaded.

Everything here is **off by default**. Cloud speech has the same consent rule as
cloud chat: `speech.enabled`, `providers.enabled` **and** `providers.allow_cloud`
must all be `true`; selecting a provider alone is not consent. Local engines need
only `speech.enabled`.

## Setup

```lua
require("rose").setup({
  providers = { enabled = true, allow_cloud = true, provider = "openai" },
  speech = {
    enabled = true,
    stt = { provider = "auto", model = nil, language = "auto" },
    tts = { provider = "auto", model = nil, voice = nil, format = "mp3" },
    record = { cmd = nil, max_seconds = 60 }, -- nil: detect pw-record, arecord, ffmpeg
    play = { cmd = nil },                     -- nil: detect pw-play, paplay, aplay, mpv, ffplay
    whisper = { url = nil },                  -- e.g. "http://127.0.0.1:8080" (loopback only)
    piper = { cmd = nil, model = nil },       -- e.g. cmd = { "piper" }, model = "/abs/en_US.onnx"
    max_audio_bytes = 25 * 1024 * 1024,
    max_text_chars = 4096,
  },
})
```

API keys are read from the environment **only when a request is sent**, never
by `setup`, `capabilities` or `:checkhealth`: `OPENAI_API_KEY` for OpenAI and
`XAI_API_KEY` for xAI (override with `providers.<name>.key_env`). Keys are passed
to curl on stdin as a config file, never on the command line, and the curl
process runs with a cleared environment.

`record.cmd` and `play.cmd` are argv tables; the output/input file path is
appended as the last argument. Detected defaults record 16 kHz mono WAV:

| Tool | Recorder argv (path appended) |
| --- | --- |
| PipeWire | `pw-record --rate 16000 --channels 1 --format s16` |
| ALSA | `arecord --quiet --format S16_LE --rate 16000 --channels 1` |
| ffmpeg | `ffmpeg -loglevel quiet -y -f pulse -i default -ac 1 -ar 16000` |

Players are tried in this order: `pw-play`, `paplay`, `aplay`, `mpv`, `ffplay`
for `.wav`; `mpv`, `ffplay` for `.mp3`.

## Commands

| Command | Behavior |
| --- | --- |
| `:RoseDictate` | Start recording. Run `:RoseSpeechStop` to finish; the transcript is inserted at the cursor position captured when recording began. Inside the Rose chat buffer the transcript is sent as a question instead. |
| `:[range]RoseSpeak [text]` | Speak the range, the argument text, or (with neither) the last `## ` section of the Rose chat buffer, then play it with the configured player. |
| `:RoseSpeechStop` | Finish an active recording; otherwise cancel every active speech request and playback. |
| `:RoseSpeechStatus` | Show the provider matrix (available or exact reason) and the number of active operations. Never contacts a provider or reads keys. |

Notifications use the title `Rose Speech`. `:RoseStop` does not know about
speech until wired (see `wiring_speech.md`); use `:RoseSpeechStop` meanwhile.

## Lua API

```lua
local speech = require("rose.speech")
speech.capabilities(config)   -- { stt = {...}, tts = {...} }; pure, no I/O
speech.transcribe(config, { path = "/abs/a.wav", mime = "audio/wav", provider = nil,
                            language = "en", keep = false }, function(err, result) end)
speech.speak(config, { text = "...", provider = nil, voice = nil, format = "mp3" },
             function(err, result) end)   -- result.path is a file in the cache
speech.record(config, { max_seconds = 30 }, function(err, capture) end) -- token.stop()
speech.play(config, "/abs/a.mp3", function(err) end)
speech.stop()                 -- cancels every active operation, returns the count
```

Callbacks are delivered exactly once via `vim.schedule`. Every token has
`cancel()`; the recording token also has `stop()`. Cancellation delivers
`"cancelled"`, kills the subprocess and removes the partial file. Operating
errors (network, consent, limits, missing tools) arrive as `err` strings;
programmer errors (wrong argument types, relative paths) raise assertions.

## Providers

| Provider | STT | TTS | Notes |
| --- | --- | --- | --- |
| `openai` | `POST /v1/audio/transcriptions` multipart, model `gpt-4o-mini-transcribe` | `POST /v1/audio/speech` JSON, model `gpt-4o-mini-tts`, voice `marin`, input ≤ 4096 chars | [Speech to text](https://developers.openai.com/api/docs/guides/speech-to-text), [Text to speech](https://developers.openai.com/api/docs/guides/text-to-speech) |
| `xai` | `POST /v1/stt` multipart; option fields first, `file` last; no model field | `POST /v1/tts` JSON, voice `eve`, `language = "auto"`, text ≤ 15000 chars, 24 kHz | [Speech to text](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text), [Text to speech](https://docs.x.ai/developers/model-capabilities/audio/text-to-speech) |
| `whisper` | whisper.cpp server `POST /inference` multipart at `speech.whisper.url` (plain `http://` loopback only) | – | local, no key |
| `piper` | – | `speech.piper.cmd`, text on stdin, `--output_file <wav>`; always WAV | local, no key |
| `anthropic` | unavailable: `provider has no speech API` | same | |
| `perplexity` | unavailable: `provider has no speech API (voice API is roadmap only)` | same | |
| `nvidia` | unavailable: `NVIDIA speech requires a self-hosted Speech NIM; not implemented` | same | hosted endpoint has no verified HTTP speech route |

`speech.stt.model`, `speech.tts.model` and `speech.tts.voice` override the
defaults **only** for the provider named in `speech.stt.provider` /
`speech.tts.provider`; xAI STT rejects a model override. Endpoints, credential
hosts and timeouts come from `providers.<name>` exactly as for chat (default
`https://api.openai.com/v1`, `https://api.x.ai/v1`, 120 s).

`provider = "auto"` picks a configured local engine first (whisper for STT,
piper for TTS), then `providers.provider` when it is `openai` or `xai` and cloud
consent is complete, otherwise it fails with the list of available providers.

## Exact limits

| Limit | Value |
| --- | --- |
| Upload size (`transcribe`) | `speech.max_audio_bytes`, default 25 MiB; checked before any process starts |
| Download size (`speak`) | `speech.max_audio_bytes`; the partial file is deleted when exceeded |
| `speech.max_audio_bytes` range | 1024 .. 256 MiB |
| Text length (`speak`) | `speech.max_text_chars` (default 4096, range 1 .. 100000); then the provider limit (OpenAI 4096, xAI 15000) |
| Recording | `record.max_seconds` 1 .. 600; the recorder gets SIGINT, then SIGKILL after 3 s |
| Playback | 600 s per file; `.wav` and `.mp3` only |
| Request timeout | `providers.<name>.timeout` / `speech.whisper.timeout`, default 120 s; piper 120 s |
| Multipart form | ≤ 32 fields, text fields ≤ 16 KiB, exactly one file, filename `audio.<ext>` |
| Upload MIME types | wav, mp3/mpga/mpeg, webm, ogg/oga, m4a/mp4, flac (by extension unless `mime` is given) |
| Language codes | letters and hyphens only, ≤ 16 chars (`en`, `pt-BR`); `"auto"` omits the field |

Temporary audio lives in `stdpath("cache")/rose/speech` with mode `0600` and is
deleted after use unless `keep = true`. Files outside that directory are never
deleted. Provider error bodies are withheld from messages so keys and audio
never reach `:messages`.

## Boundaries

- No realtime or streaming audio: recording finishes before transcription starts
  and synthesis finishes before playback starts.
- No live provider calls were made while building or testing this module; the
  wire formats are asserted by an offline loopback fixture that emulates the
  documented request and response shapes (`tests/speech_fixture.py`).
- NVIDIA, Anthropic and Perplexity speech are reported as unavailable with the
  reasons above; there is no gRPC or WebSocket client.
- No microphone or speaker access from Neovim itself: a recorder/player
  executable is required. Detection is by `executable()`, never by installing.
- The chat model never triggers dictation, synthesis or playback; only the user
  commands and the Lua API do.

## Tests

```sh
ROSE_TEST_PYTHON=python3 nvim --headless -u NONE -l tests/speech.lua
```

The suite starts `tests/speech_fixture.py` on a loopback port with a fake key,
fake recorder/player/piper executables and no network access, and covers the
capability matrix, consent gates, every provider round trip, cancellation,
size/time limits, temp-file cleanup and the user commands.
