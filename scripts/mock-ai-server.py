#!/usr/bin/env python3
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def chunk_text(text, size=18):
    for index in range(0, len(text), size):
        yield text[index:index + size]


class MockAIHandler(BaseHTTPRequestHandler):
    server_version = "MyIDEMockAI/1.0"

    def log_message(self, format, *args):
        return

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self.send_error(404)
            return

        length = int(self.headers.get("content-length", "0"))
        raw_body = self.rfile.read(length)
        try:
            body = json.loads(raw_body.decode("utf-8"))
        except Exception:
            self.send_error(400)
            return

        messages = body.get("messages", [])
        tool_choice = body.get("tool_choice")
        forced_tool = None
        if isinstance(tool_choice, dict):
            forced_tool = (tool_choice.get("function") or {}).get("name")

        tool_names = []
        for message in messages:
            for tool_call in message.get("tool_calls") or []:
                function = tool_call.get("function") or {}
                tool_names.append(function.get("name"))

        last_tool_content = ""
        if messages and messages[-1].get("role") == "tool":
            last_tool_content = messages[-1].get("content") or ""

        if forced_tool == "get_git_diff" or "get_git_diff" not in tool_names:
            self.respond_tool_call(
                call_id="call_diff",
                name="get_git_diff",
                arguments={"path": None, "max_chars": None},
            )
            return

        if "Captured fix proposal" in last_tool_content:
            self.respond_text("Captured the fix proposal for handoff.")
            return

        user_text = "\n".join(
            str(message.get("content") or "")
            for message in messages
            if message.get("role") == "user"
        ).lower()
        should_capture = forced_tool == "capture_fix" or "please fix" in user_text or "create a fix" in user_text
        if should_capture and "capture_fix" not in tool_names:
            self.respond_tool_call(
                call_id="call_fix",
                name="capture_fix",
                arguments={
                    "title": "Rename page shell instrumentation label",
                    "summary": "Rename the page shell wording so it clearly reads as instrumentation rather than a user-facing shell concept.",
                    "prompt": (
                        "Rename the selected page shell instrumentation label to a clearer telemetry-oriented name. "
                        "Keep behavior unchanged, update nearby tests or snapshots that assert the old label, "
                        "and verify the instrumentation path still reports the same event."
                    ),
                },
            )
            return

        if "credit-error" in user_text:
            self.respond_error("insufficient_quota", "Mock account is out of credits.")
            return

        self.respond_text(
            "This is only used for instrumentation, so a telemetry-oriented name would be more accurate than page shell."
        )

    def begin_stream(self):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()

    def write_event(self, payload):
        data = f"data: {json.dumps(payload, separators=(',', ':'))}\n\n".encode("utf-8")
        self.wfile.write(data)
        self.wfile.flush()

    def end_stream(self):
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def respond_text(self, text):
        self.begin_stream()
        for delta in chunk_text(text):
            self.write_event({"choices": [{"delta": {"content": delta}}]})
        self.end_stream()

    def respond_tool_call(self, call_id, name, arguments):
        self.begin_stream()
        self.write_event({
            "choices": [{
                "delta": {
                    "tool_calls": [{
                        "index": 0,
                        "id": call_id,
                        "type": "function",
                        "function": {
                            "name": name,
                            "arguments": json.dumps(arguments, separators=(",", ":")),
                        },
                    }],
                },
            }],
        })
        self.end_stream()

    def respond_error(self, code, message):
        self.begin_stream()
        self.write_event({
            "error": {
                "type": "billing_error",
                "code": code,
                "message": message,
            },
        })
        self.end_stream()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), MockAIHandler)
    print(f"mock ai server listening on http://{args.host}:{server.server_port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
