#!/usr/bin/env python3
"""Offline protocol fixture. Fake credentials only; no upstream calls or request logs."""

import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEY = "rose-fixture-fake-key"
CALL = "call_fixture_17"
SCHEMA = "lookup"
PUBLIC = "Public answer."
PRIVATE = "PRIVATE_REASONING_DO_NOT_DISPLAY"
OPAQUE = "opaque-encrypted-reasoning"
SIGNATURE = "signature-must-replay-exactly"


def responses_output():
    return [
        {
            "id": "rs_fixture",
            "type": "reasoning",
            "summary": [],
            "encrypted_content": OPAQUE,
            "vendor_extension": {"keep": True},
        },
        {
            "id": "msg_fixture",
            "type": "message",
            "role": "assistant",
            "phase": "commentary",
            "content": [{"type": "output_text", "text": PUBLIC, "annotations": []}],
        },
        {
            "id": "fc_fixture",
            "type": "function_call",
            "call_id": CALL,
            "name": SCHEMA,
            "arguments": '{"path":"fixture.txt"}',
            "status": "completed",
        },
    ]


def anthropic_blocks():
    return [
        {"type": "thinking", "thinking": PRIVATE, "signature": SIGNATURE},
        {"type": "redacted_thinking", "data": OPAQUE},
        {"type": "text", "text": PUBLIC},
        {"type": "tool_use", "id": CALL, "name": SCHEMA, "input": {"path": "fixture.txt"}},
    ]


def chat_message():
    return {
        "role": "assistant",
        "content": "<think>" + PRIVATE + "</think>" + PUBLIC,
        "reasoning_content": OPAQUE,
        "vendor_extension": {"keep": True},
        "tool_calls": [
            {
                "id": CALL,
                "type": "function",
                "function": {"name": SCHEMA, "arguments": '{"path":"fixture.txt"}'},
            }
        ],
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send_json(self, value, status=200):
        raw = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
        self.wfile.flush()

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def handle_request(self):
        try:
            self.respond()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except AssertionError:
            # Deliberately no request/header diagnostics: even fixtures should
            # teach safe failure handling. A failed assertion is HTTP 422.
            self.send_json({"error": "fixture wire format mismatch"}, 422)

    def respond(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length)) if length else {}
        assert not self.headers.get("X-Curlrc-Loaded")
        assert not self.headers.get("Proxy-Authorization")
        if self.path.startswith("/anthropic/"):
            assert self.headers.get("x-api-key") == KEY
            assert self.headers.get("anthropic-version") == "2023-06-01"
            assert not self.headers.get("Authorization")
        elif self.path.startswith("/noauth/"):
            assert not self.headers.get("Authorization")
        else:
            assert self.headers.get("Authorization") == "Bearer " + KEY

        action = self.path.rsplit("/", 1)[-1].split("?", 1)[0]
        if action == "error":
            self.send_json({"error": {"message": KEY + " PRIVATE_SOURCE"}}, 401)
            return
        if action == "api_error":
            self.send_json({"error": {"message": KEY + " PRIVATE_SOURCE"}})
            return
        if action == "redirect":
            self.send_response(307)
            self.send_header("Location", "http://127.0.0.1:1/credential-trap?token=" + KEY)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if action == "invalid":
            self.send_response(200)
            raw = ("NOT_JSON " + KEY + " PRIVATE_SOURCE").encode()
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if action == "large":
            self.send_json({"data": "x" * (256 * 1024)})
            return
        if action == "slow":
            time.sleep(2)
            self.send_json({"ok": True})
            return
        if action == "inspect":
            self.send_json(
                {
                    "body": body,
                    "path": self.path,
                    "method": self.command,
                    "auth_ok": True,
                    "beta": self.headers.get("anthropic-beta"),
                }
            )
            return
        if action.startswith("sse"):
            self.stream(action)
            return

        assert body["model"] == "fixture-model"
        assert body["stream"] is False
        if self.path.endswith(("/responses", "/agent")):
            assert "messages" not in body
            assert body["tools"][0]["type"] == "function"
            assert body["tools"][0]["name"] == SCHEMA
            assert body["parallel_tool_calls"] is False
            if self.path.startswith("/openai/"):
                assert body["tools"][0]["strict"] is False
                assert body["store"] is False
                assert "reasoning.encrypted_content" in body["include"]
            inputs = body["input"]
            results = [x for x in inputs if x.get("type") == "function_call_output"]
            if results:
                assert results == [
                    {"type": "function_call_output", "call_id": CALL, "output": '{"ok":true}'}
                ]
                assert inputs[2:5] == responses_output()
                output = [
                    {
                        "id": "msg_final",
                        "type": "message",
                        "role": "assistant",
                        "content": [
                            {
                                "type": "output_text",
                                "text": "Replay verified.",
                                "annotations": [
                                    {
                                        "type": "url_citation",
                                        "url": "https://example.test/doc",
                                        "title": "Fixture",
                                    }
                                ],
                            }
                        ],
                    }
                ]
            else:
                assert inputs == [
                    {"role": "system", "content": "System instructions."},
                    {"role": "user", "content": "Read fixture."},
                ]
                output = responses_output()
            self.send_json(
                {
                    "id": "resp_fixture",
                    "status": "completed",
                    "output": output,
                    "usage": {
                        "input_tokens": 11,
                        "output_tokens": 7,
                        "total_tokens": 18,
                        "output_tokens_details": {"reasoning_tokens": 3},
                    },
                    "vendor_top_level": {"keep": True},
                }
            )
        elif self.path.endswith("/messages"):
            assert body["max_tokens"] == 512
            assert body["system"] == [{"type": "text", "text": "System instructions."}]
            assert body["tools"][0]["name"] == SCHEMA
            assert body["tools"][0]["input_schema"]["type"] == "object"
            assert "parameters" not in body["tools"][0]
            assert body["thinking"] == {"type": "enabled", "budget_tokens": 128}
            messages = body["messages"]
            if len(messages) > 1:
                assert messages[1] == {"role": "assistant", "content": anthropic_blocks()}
                assert messages[2] == {
                    "role": "user",
                    "content": [
                        {"type": "tool_result", "tool_use_id": CALL, "content": '{"ok":true}'}
                    ],
                }
                content, reason = [{"type": "text", "text": "Replay verified."}], "end_turn"
            else:
                content, reason = anthropic_blocks(), "tool_use"
            self.send_json(
                {
                    "id": "msg_fixture",
                    "type": "message",
                    "role": "assistant",
                    "content": content,
                    "stop_reason": reason,
                    "usage": {"input_tokens": 11, "output_tokens": 7},
                }
            )
        elif self.path.endswith("/sonar"):
            assert "tools" not in body
            assert body["search_domain_filter"] == ["example.test"]
            self.send_json(
                {
                    "choices": [
                        {
                            "message": {"role": "assistant", "content": PUBLIC},
                            "finish_reason": "stop",
                        }
                    ],
                    "citations": ["https://example.test/doc"],
                    "search_results": [{"url": "https://example.test/doc", "title": "Fixture"}],
                    "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18},
                }
            )
        else:
            assert self.path.endswith("/chat/completions")
            assert body["tools"][0]["function"]["name"] == SCHEMA
            assert body["parallel_tool_calls"] is False
            if self.path.startswith(("/nvidia/", "/noauth/")):
                assert body["tool_choice"] == "auto"
            messages = body["messages"]
            if len(messages) > 2:
                assert messages[2] == chat_message()
                assert messages[3] == {
                    "role": "tool",
                    "tool_call_id": CALL,
                    "name": SCHEMA,
                    "content": '{"ok":true}',
                }
                message, reason = {"role": "assistant", "content": "Replay verified."}, "stop"
            else:
                message, reason = chat_message(), "tool_calls"
            self.send_json(
                {
                    "choices": [{"message": message, "finish_reason": reason}],
                    "usage": {
                        "prompt_tokens": 11,
                        "completion_tokens": 7,
                        "total_tokens": 18,
                        "prompt_tokens_details": {"cached_tokens": 5},
                    },
                }
            )

    def stream(self, action):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        if action == "sse_bad":
            parts = ["data: " + KEY + "\n\n"]
        elif action == "sse_error":
            parts = ['event: error\ndata: {"type":"error","error":{"message":"' + KEY + '"}}\n\n']
        elif action == "sse_large":
            parts = ['data: {"huge":"' + "x" * 10000 + '"}\n\n']
        elif action == "sse_truncated":
            parts = ['data: {"incomplete":true}']
        elif self.path.startswith("/anthropic/"):
            parts = [
                ': ping\r\n\r\nevent: message_start\r\ndata: {"type":"message_start"}\r\n\r\n',
                (
                    'event: content_block_delta\ndata: {"type":"content_block_delta",\n'
                    'data: "delta":{"type":"text_delta","text":"Hello"}}\n\n'
                ),
                'event: message_stop\ndata: {"type":"message_stop"}\n\n',
            ]
        elif self.path.startswith(("/openai/", "/perplexity/")):
            parts = [
                (
                    "event: response.output_text.delta\n"
                    'data: {"type":"response.output_text.delta","delta":"Hello"}\n\n'
                ),
                (
                    "event: response.completed\n"
                    'data: {"type":"response.completed","response":{"status":"completed"}}\n\n'
                ),
            ]
        else:
            parts = ['data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n', "data: [DONE]\n\n"]
        # Split event frames, JSON, and CRLF across writes to exercise buffering.
        for text in parts:
            raw = text.encode()
            for start in range(0, len(raw), 13):
                self.wfile.write(raw[start : start + 13])
                self.wfile.flush()
                time.sleep(0.001)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
