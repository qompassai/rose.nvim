#!/usr/bin/env python3
"""Offline speech fixture: loopback HTTP emulation of OpenAI, xAI and whisper.cpp
speech endpoints plus fake recorder/player/piper executables. Fake credentials
only; nothing here contacts the network or logs request contents.

Usage:
  speech_fixture.py                      HTTP server; prints its port on stdout
  speech_fixture.py --recorder PATH      fake microphone: WAV until SIGINT/SIGTERM
  speech_fixture.py --recorder-broken P  fake microphone that produces nothing
  speech_fixture.py --player PATH        fake player: succeeds if PATH is non-empty
  speech_fixture.py --player-slow PATH   fake player that blocks for 10 seconds
  speech_fixture.py --piper --output_file PATH [--model M]   fake piper (stdin -> WAV)
"""

import json
import signal
import struct
import sys
import threading
import time
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEY = "rose-fixture-fake-key"
LARGE_BYTES = 256 * 1024
SLOW_SECONDS = 2.0
RECORDER_SECONDS_MAX = 30.0


def wav_bytes(seconds, rate=16000):
    """Canonical 44-byte PCM header followed by silence."""
    frames = int(seconds * rate)
    data = b"\x00\x00" * frames
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
    header += struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    header += b"data" + struct.pack("<I", len(data))
    assert len(header) == 44
    return header + data


def mp3_bytes(text):
    """Not decodable audio, just a recognizable ID3 prefix and the spoken text."""
    return b"ID3\x04\x00\x00\x00\x00\x00\x00" + text.encode()


def parse_multipart(content_type, body):
    """Returns ordered [(name, filename, content_type, data)] using the stdlib parser."""
    assert content_type.startswith("multipart/form-data"), "expected multipart body"
    prefix = b"Content-Type: " + content_type.encode() + b"\r\nMIME-Version: 1.0\r\n\r\n"
    message = BytesParser().parsebytes(prefix + body)
    fields = []
    for part in message.get_payload():
        name = part.get_param("name", header="content-disposition")
        filename = part.get_param("filename", header="content-disposition")
        fields.append((name, filename, part.get_content_type(), part.get_payload(decode=True)))
    return fields


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send_bytes(self, raw, content_type, status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
        self.wfile.flush()

    def send_json(self, value, status=200):
        raw = json.dumps(value, separators=(",", ":")).encode()
        self.send_bytes(raw, "application/json", status)

    def do_POST(self):
        try:
            self.respond()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except AssertionError:
            # No request diagnostics on purpose: a wire mismatch is HTTP 422.
            self.send_json({"error": "fixture wire format mismatch"}, 422)

    def respond(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""
        assert not self.headers.get("X-Curlrc-Loaded")
        assert not self.headers.get("Proxy-Authorization")
        segments = [s for s in self.path.split("?", 1)[0].split("/") if s]
        modifiers = set()
        while segments and segments[0] in ("slow", "large", "error", "badjson"):
            modifiers.add(segments.pop(0))
        assert segments, "route must name a provider"
        provider, route = segments[0], "/" + "/".join(segments[1:])
        if provider in ("openai", "xai"):
            assert self.headers.get("Authorization") == "Bearer " + KEY
        else:
            assert provider == "whisper"
            assert not self.headers.get("Authorization")
        if "slow" in modifiers:
            time.sleep(SLOW_SECONDS)
        if "error" in modifiers:
            self.send_json({"error": {"message": KEY + " PRIVATE_AUDIO"}}, 401)
            return
        if "badjson" in modifiers:
            self.send_bytes(b"NOT_JSON " + KEY.encode(), "application/json")
            return
        if (provider, route) == ("openai", "/audio/transcriptions"):
            self.openai_stt(body)
        elif (provider, route) == ("openai", "/audio/speech"):
            self.openai_tts(body, "large" in modifiers)
        elif (provider, route) == ("xai", "/stt"):
            self.xai_stt(body)
        elif (provider, route) == ("xai", "/tts"):
            self.xai_tts(body, "large" in modifiers)
        elif (provider, route) == ("whisper", "/inference"):
            self.whisper(body)
        else:
            raise AssertionError("unknown route")

    def audio_field(self, fields):
        files = [f for f in fields if f[1] is not None]
        assert len(files) == 1, "exactly one file part"
        name, filename, content_type, data = files[0]
        assert name == "file"
        assert filename.startswith("audio.")
        assert content_type.startswith("audio/")
        assert len(data) > 44
        if filename.endswith(".wav"):
            assert data[:4] == b"RIFF"
        return data

    def openai_stt(self, body):
        fields = parse_multipart(self.headers.get("Content-Type", ""), body)
        names = [f[0] for f in fields]
        assert "model" in names and "response_format" in names
        values = {f[0]: f[3].decode() for f in fields if f[1] is None}
        assert values["response_format"] == "json"
        assert values["model"], "model must be set"
        if "language" in values:
            assert values["language"].isalpha()
        data = self.audio_field(fields)
        self.send_json({"text": f"openai:{values['model']}:{len(data)}"})

    def xai_stt(self, body):
        fields = parse_multipart(self.headers.get("Content-Type", ""), body)
        # xAI parses options before the audio: file MUST be the final field.
        assert fields[-1][0] == "file", "file must be the last multipart field"
        for name, filename, _, _ in fields[:-1]:
            assert filename is None and name != "file", "options must precede file"
        values = {f[0]: f[3].decode() for f in fields if f[1] is None}
        assert "model" not in values, "xAI STT has no model field"
        data = self.audio_field(fields)
        language = values.get("language", "en")
        self.send_json(
            {"text": f"xai:{len(data)}", "language": language, "duration": 1.25, "words": []}
        )

    def whisper(self, body):
        fields = parse_multipart(self.headers.get("Content-Type", ""), body)
        values = {f[0]: f[3].decode() for f in fields if f[1] is None}
        assert values.get("response_format") == "json"
        data = self.audio_field(fields)
        self.send_json({"text": f"whisper:{len(data)}"})

    def openai_tts(self, body, large):
        request = json.loads(body)
        assert set(request) == {"model", "voice", "input", "response_format"}
        assert request["model"] and request["voice"]
        assert 1 <= len(request["input"]) <= 4096
        assert request["response_format"] in ("mp3", "wav")
        self.send_audio(request["response_format"], request["input"], large)

    def xai_tts(self, body, large):
        request = json.loads(body)
        assert set(request) == {"text", "voice_id", "language", "output_format"}
        assert 1 <= len(request["text"]) <= 15000
        assert request["voice_id"] and request["language"]
        codec = request["output_format"]["codec"]
        assert codec in ("mp3", "wav")
        assert isinstance(request["output_format"]["sample_rate"], int)
        self.send_audio(codec, request["text"], large)

    def send_audio(self, codec, text, large):
        if large:
            raw = b"\x00" * LARGE_BYTES
        elif codec == "wav":
            raw = wav_bytes(0.05)
        else:
            raw = mp3_bytes(text)
        self.send_bytes(raw, "audio/wav" if codec == "wav" else "audio/mpeg")


def serve():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


def recorder(path):
    stop = threading.Event()
    for name in (signal.SIGINT, signal.SIGTERM):
        signal.signal(name, lambda *_: stop.set())
    with open(path, "wb") as handle:
        handle.write(wav_bytes(0.1))
    started = time.monotonic()
    stop.wait(RECORDER_SECONDS_MAX)
    elapsed = min(time.monotonic() - started, RECORDER_SECONDS_MAX)
    # Finalize like a real recorder: the WAV grows with the elapsed time.
    with open(path, "wb") as handle:
        handle.write(wav_bytes(0.1 + elapsed))
    return 0


def player(path, slow):
    if slow:
        time.sleep(10)
    with open(path, "rb") as handle:
        return 0 if len(handle.read(64)) > 0 else 3


def piper(argv):
    assert "--output_file" in argv, "piper needs --output_file"
    path = argv[argv.index("--output_file") + 1]
    text = sys.stdin.read()
    if not text.strip():
        return 2
    with open(path, "wb") as handle:
        handle.write(wav_bytes(0.05 * min(len(text), 40)))
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        serve()
    elif args[0] == "--recorder":
        sys.exit(recorder(args[1]))
    elif args[0] == "--recorder-broken":
        sys.exit(1)
    elif args[0] == "--player":
        sys.exit(player(args[1], False))
    elif args[0] == "--player-slow":
        sys.exit(player(args[1], True))
    elif args[0] == "--piper":
        sys.exit(piper(args))
    else:
        sys.exit("unknown fixture mode")
