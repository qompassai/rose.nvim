#!/usr/bin/env python3
"""Raw HTTP client for tests/webui.lua. Standard library only, loopback only.

Every subcommand prints one JSON object on stdout so the Lua test can assert on
status codes, headers, bodies and socket behaviour (EOF, timeouts). A raw socket
is used instead of http.client so malformed requests can be sent on purpose.

Usage:
  webui_client.py PORT request --method GET --path /api/health [--token T]
                  [--header 'Name: value']... [--body TEXT | --body-file PATH]
                  [--content-type TYPE] [--omit-content-length] [--chunked]
  webui_client.py PORT raw --data-b64 BASE64 [--read-timeout SECONDS]
  webui_client.py PORT idle --wait-ms MS
  webui_client.py PORT hold --count N --hold-ms MS [--path P --token T]
"""

import argparse
import base64
import json
import socket
import sys
import time

HOST = "127.0.0.1"
RESPONSE_BYTES_MAX = 64 * 1024 * 1024
RECV_CHUNK_BYTES = 65536
DEFAULT_TIMEOUT_SECONDS = 10.0


def read_until_eof(sock, timeout_seconds):
    """Read until the server closes or the deadline passes (bounded size)."""
    deadline = time.monotonic() + timeout_seconds
    chunks = []
    total = 0
    eof = False
    while total <= RESPONSE_BYTES_MAX:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(RECV_CHUNK_BYTES)
        except TimeoutError:
            break
        except (ConnectionResetError, BrokenPipeError, OSError):
            eof = True
            break
        if not chunk:
            eof = True
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks), eof


def parse_response(raw):
    """Split a single HTTP/1.1 response into status, headers and body."""
    head_end = raw.find(b"\r\n\r\n")
    if head_end < 0:
        return {"status": None, "reason": None, "headers": {}, "body": raw}
    head = raw[:head_end].decode("latin-1")
    lines = head.split("\r\n")
    parts = lines[0].split(" ", 2)
    status = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else None
    reason = parts[2] if len(parts) == 3 else ""
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    body = raw[head_end + 4 :]
    length = headers.get("content-length")
    if length is not None and length.isdigit():
        body = body[: int(length)]
    return {"status": status, "reason": reason, "headers": headers, "body": body}


def describe(parsed, eof, elapsed_ms):
    body = parsed["body"]
    text = None
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        text = None
    return {
        "status": parsed["status"],
        "reason": parsed["reason"],
        "headers": parsed["headers"],
        "body_b64": base64.b64encode(body).decode("ascii"),
        "body_text": text,
        "body_bytes": len(body),
        "eof": eof,
        "elapsed_ms": elapsed_ms,
    }


def connect(port, timeout_seconds=DEFAULT_TIMEOUT_SECONDS):
    sock = socket.create_connection((HOST, port), timeout=timeout_seconds)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return sock


def build_request(args):
    body = b""
    if args.body is not None:
        body = args.body.encode("utf-8")
    elif args.body_file is not None:
        with open(args.body_file, "rb") as handle:
            body = handle.read()
    lines = [f"{args.method} {args.path} HTTP/1.1", f"Host: {HOST}:{args.port}"]
    if args.token:
        lines.append(f"Authorization: Bearer {args.token}")
    if args.content_type:
        lines.append(f"Content-Type: {args.content_type}")
    lines.extend(args.header or [])
    if args.chunked:
        lines.append("Transfer-Encoding: chunked")
        body = b"%x\r\n%s\r\n0\r\n\r\n" % (len(body), body) if body else b"0\r\n\r\n"
    elif body and not args.omit_content_length:
        lines.append(f"Content-Length: {len(body)}")
    elif args.content_length is not None:
        lines.append(f"Content-Length: {args.content_length}")
    head = ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")
    return head + body


def command_request(args):
    payload = build_request(args)
    started = time.monotonic()
    sock = connect(args.port)
    try:
        sock.sendall(payload)
    except (BrokenPipeError, ConnectionResetError):
        pass  # The server may legitimately close early (e.g. 413); read what it sent.
    raw, eof = read_until_eof(sock, args.read_timeout)
    sock.close()
    return describe(parse_response(raw), eof, int((time.monotonic() - started) * 1000))


def command_raw(args):
    payload = base64.b64decode(args.data_b64)
    started = time.monotonic()
    sock = connect(args.port)
    try:
        sock.sendall(payload)
    except (BrokenPipeError, ConnectionResetError):
        pass
    raw, eof = read_until_eof(sock, args.read_timeout)
    sock.close()
    return describe(parse_response(raw), eof, int((time.monotonic() - started) * 1000))


def command_idle(args):
    started = time.monotonic()
    sock = connect(args.port)
    raw, eof = read_until_eof(sock, args.wait_ms / 1000.0)
    sock.close()
    return describe(parse_response(raw), eof, int((time.monotonic() - started) * 1000))


def command_hold(args):
    """Open N idle connections, optionally probe with one more, then wait."""
    started = time.monotonic()
    held = []
    for _ in range(args.count):
        held.append(connect(args.port))
    time.sleep(0.05)  # Let the server register every accepted client first.
    probe = None
    if args.path:
        args.method, args.body, args.body_file = "GET", None, None
        args.content_type, args.header, args.chunked = None, [], False
        args.omit_content_length, args.content_length = False, None
        probe = command_request(args)
    eof_count = 0
    deadline = time.monotonic() + args.hold_ms / 1000.0
    for sock in held:
        remaining = max(0.01, deadline - time.monotonic())
        raw, eof = read_until_eof(sock, remaining)
        if eof or raw:
            eof_count += 1
        sock.close()
    return {
        "opened": len(held),
        "eof_count": eof_count,
        "probe": probe,
        "elapsed_ms": int((time.monotonic() - started) * 1000),
    }


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", type=int)
    subparsers = parser.add_subparsers(dest="command", required=True)
    request = subparsers.add_parser("request")
    request.add_argument("--method", default="GET")
    request.add_argument("--path", default="/")
    request.add_argument("--token")
    request.add_argument("--header", action="append")
    request.add_argument("--body")
    request.add_argument("--body-file")
    request.add_argument("--content-type")
    request.add_argument("--content-length")
    request.add_argument("--omit-content-length", action="store_true")
    request.add_argument("--chunked", action="store_true")
    request.add_argument("--read-timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    raw = subparsers.add_parser("raw")
    raw.add_argument("--data-b64", required=True)
    raw.add_argument("--read-timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    idle = subparsers.add_parser("idle")
    idle.add_argument("--wait-ms", type=int, required=True)
    hold = subparsers.add_parser("hold")
    hold.add_argument("--count", type=int, required=True)
    hold.add_argument("--hold-ms", type=int, required=True)
    hold.add_argument("--path")
    hold.add_argument("--token")
    hold.add_argument("--read-timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    args = parser.parse_args(argv)
    handlers = {
        "request": command_request,
        "raw": command_raw,
        "idle": command_idle,
        "hold": command_hold,
    }
    result = handlers[args.command](args)
    sys.stdout.write(json.dumps(result))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
