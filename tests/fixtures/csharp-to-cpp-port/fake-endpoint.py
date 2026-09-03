"""Fake OpenAI-compatible chat endpoint for run-csharp-to-cpp-eval-loop.ps1 tests.

Replies with the golden C++ files for the unit named in the prompt, wrapped the way local models
actually reply: a <think>...</think> block, Korean text, ONE unit in the "### path" heading shape,
and NO charset in the Content-Type header (this is what breaks Invoke-RestMethod in PS 5.1).
Usage: python fake-endpoint.py <port> <golden-root>
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
GOLDEN = sys.argv[2]


def reply_for(prompt):
    m = re.search(r"C# source: `([^`]+)`", prompt)
    if not m:
        return None
    unit = m.group(1).split(" + ")[0].replace("/", os.sep)
    base = os.path.splitext(unit)[0]
    rel = base.replace(os.sep, "/")
    h = os.path.join(GOLDEN, base + ".h")
    c = os.path.join(GOLDEN, base + ".cpp")
    if not os.path.exists(c):
        return None
    parts = ["<think>\n포팅 규칙을 확인했다. 두 파일을 완전하게 쓴다.\n</think>\n"]
    heading_shape = rel.endswith("Util/StringHelpers")
    if os.path.exists(h):
        body = open(h, encoding="utf-8").read().rstrip()
        parts.append(("### %s.h\n" if heading_shape else "// FILE: %s.h\n") % rel)
        parts.append("```cpp\n" + body + "\n```\n\n")
    body = open(c, encoding="utf-8").read().rstrip()
    parts.append(("### %s.cpp\n" if heading_shape else "// FILE: %s.cpp\n") % rel)
    parts.append("```cpp\n" + body + "\n```\n")
    return "".join(parts)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            req = json.loads(raw.decode("utf-8"))
            prompt = req["messages"][-1]["content"]
            if req.get("max_tokens") is None:
                raise ValueError("max_tokens missing")
        except Exception as e:  # noqa
            self.send_response(400)
            self.end_headers()
            self.wfile.write(("bad request: %s" % e).encode("utf-8"))
            return
        content = reply_for(prompt)
        if content is None:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"unit not found")
            return
        body = json.dumps({"choices": [{"message": {"role": "assistant", "content": content}}]}, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")  # deliberately no charset
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
