"""Deterministic local HTTP and MCP subprocess fixtures; no model or GPU."""

import argparse
import json
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def http_server():
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if self.path.startswith("/slow"):
                time.sleep(0.4)
            if self.path.startswith("/redirect"):
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:1/never")
                self.end_headers()
                return
            if self.path.startswith("/status"):
                self.send_response(503)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            try:
                data = json.loads(body)
                response = {
                    "message": {"role": "assistant", "content": "native HTTP okay"},
                    "received": data,
                }
                self.wfile.write(
                    b"not JSON" if self.path.startswith("/bad") else json.dumps(response).encode()
                )
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()


def mcp_server(args):
    waiting = {}
    if args.case == "stubborn":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)

    def emit(message, partial=False):
        text = json.dumps(message) + "\n"
        if partial:
            sys.stdout.write(text[:9])
            sys.stdout.flush()
            time.sleep(0.01)
            sys.stdout.write(text[9:])
        else:
            sys.stdout.write(text)
        sys.stdout.flush()

    def reply(request_id, result):
        emit({"jsonrpc": "2.0", "id": request_id, "result": result}, args.case == "partial")

    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        request_id = request.get("id")
        if method == "initialize":
            if args.case == "initialize_hang":
                continue
            if args.case == "malformed":
                print("not JSON", flush=True)
                continue
            reply(
                request_id,
                {
                    "protocolVersion": "2099-01-01" if args.case == "version" else "2025-11-25",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "fixture", "version": "1"},
                },
            )
        elif method == "tools/list":
            reply(
                request_id,
                {
                    "tools": [
                        {
                            "name": "echo",
                            "inputSchema": {"type": "object"},
                            "annotations": {"readOnlyHint": True},
                        }
                    ]
                },
            )
        elif method == "tools/call":
            params = request["params"]
            name = params["name"]
            if name == "slow" or args.case == "stubborn" and name == "flow_run":
                continue
            if name == "server_request":
                waiting["server-1"] = request_id
                emit(
                    {
                        "jsonrpc": "2.0",
                        "id": "server-1",
                        "method": "sampling/createMessage",
                        "params": {},
                    }
                )
                continue
            if name == "exit":
                sys.exit(3)
            if not isinstance(params.get("arguments"), dict):
                emit(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": {"code": -32602, "message": "arguments must be an object"},
                    }
                )
                continue
            report = {
                "status": "error" if name == "error" else "ok",
                "arguments": params["arguments"],
                "workspace": args.workspace,
                "nvim": args.nvim,
                "trusted": args.trusted,
            }
            reply(
                request_id,
                {
                    "content": [{"type": "text", "text": json.dumps(report)}],
                    "structuredContent": report,
                    "isError": name == "error",
                },
            )
        elif method == "ping":
            reply(request_id, {})
        elif method is None and request_id in waiting:
            reply(
                waiting.pop(request_id),
                {"content": [], "structuredContent": {"rejected": request.get("error")}},
            )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("http", "mcp"))
    parser.add_argument("--case", default="normal")
    parser.add_argument("--workspace")
    parser.add_argument("--nvim")
    parser.add_argument("--trusted", action="store_true")
    parsed = parser.parse_args()
    if parsed.mode == "http":
        http_server()
    else:
        mcp_server(parsed)
