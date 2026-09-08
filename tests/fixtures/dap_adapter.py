"""Minimal deterministic DAP adapter with fragmented frames for transport tests."""

import json
import sys

seq = 0
launch_seq = None


def send(message):
    global seq
    seq += 1
    payload = json.dumps({"seq": seq, **message}).encode()
    frame = f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload
    sys.stdout.buffer.write(frame[:13])
    sys.stdout.buffer.flush()
    sys.stdout.buffer.write(frame[13:])
    sys.stdout.buffer.flush()


def response(request, body=None, success=True):
    send(
        {
            "type": "response",
            "request_seq": request["seq"],
            "command": request["command"],
            "success": success,
            "body": body or {},
            "message": "" if success else "fixture rejected",
        }
    )


# A probe exchanges a handful of requests; bound the loop so a stuck client cannot pin the fixture.
REQUESTS_MAX = 10000
for _ in range(REQUESTS_MAX):
    header = sys.stdin.buffer.readline()
    if not header:
        break
    length = int(header.decode().split(":")[1])
    assert sys.stdin.buffer.readline() == b"\r\n"
    request = json.loads(sys.stdin.buffer.read(length))
    command = request["command"]
    if "--hang" in sys.argv and command != "disconnect":
        continue
    if command == "initialize":
        response(request, {"supportsConfigurationDoneRequest": True}, "--reject" not in sys.argv)
    elif command == "launch":
        launch_seq = request
        send({"type": "event", "event": "initialized"})
    elif command == "setBreakpoints":
        response(request, {"breakpoints": [{"verified": True, "line": 2}]})
    elif command == "configurationDone":
        response(request)
        response(launch_seq)
        send({"type": "event", "event": "stopped", "body": {"reason": "breakpoint", "threadId": 1}})
    elif command == "stackTrace":
        response(request, {"stackFrames": [{"id": 1, "name": "probe", "line": 2, "column": 1}]})
    elif command == "scopes":
        response(request, {"scopes": [{"name": "Locals", "variablesReference": 1}]})
    elif command == "disconnect":
        response(request)
        break
    else:
        response(request, success=False)
