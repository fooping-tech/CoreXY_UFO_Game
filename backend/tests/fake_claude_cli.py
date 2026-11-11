"""A stand-in for `claude -p --input-format stream-json --output-format stream-json`.

It answers each user message with the lines the real CLI prints (Claude Code
2.1.319): system init, text deltas, result. The question text picks a behaviour:
  "slow"  -> one delta, then wait for an interrupt (answered; the turn ends with
             error_during_execution)
  "wedge" -> one delta, then ignore everything (no answer to the interrupt)
  "fail"  -> an error result
  "exit"  -> exit without a result
  "images" -> "images:<each image's bytes between the JPEG markers, in order>"
otherwise -> "turn<N>:<question>" in two deltas (N counts this process's turns).
FAKE_CLAUDE_ARGV (env): append this process's argv as a JSON line to that file.
"""

import base64
import json
import os
import sys

if os.environ.get("FAKE_CLAUDE_ARGV"):
    with open(os.environ["FAKE_CLAUDE_ARGV"], "a", encoding="utf-8") as f:
        f.write(json.dumps(sys.argv[1:]) + "\n")


def out(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def delta(text):
    out({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                            "delta": {"type": "text_delta", "text": text}}})


def result(ok=True, text=""):
    out({"type": "result", "subtype": "success" if ok else "error_during_execution",
         "is_error": not ok, "result": text})


turns = 0
waiting_interrupt = False
wedged = False
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get("type") == "control_request":
        if wedged:
            continue
        out({"type": "control_response", "response": {"subtype": "success",
                                                       "request_id": msg["request_id"], "response": {}}})
        if waiting_interrupt:
            waiting_interrupt = False
            result(False)
        continue
    if wedged or msg.get("type") != "user":
        continue
    content = msg["message"]["content"]
    image = next(c for c in content if c["type"] == "image")
    assert base64.b64decode(image["source"]["data"])[:2] == b"\xff\xd8"
    text = next(c["text"] for c in content if c["type"] == "text")
    turns += 1
    out({"type": "system", "subtype": "init", "tools": [], "mcp_servers": []})
    if text == "exit":
        sys.exit(3)
    if text == "fail":
        result(False, "not signed in")
        continue
    if text == "images":
        tags = [base64.b64decode(c["source"]["data"])[2:-2].decode() for c in content if c["type"] == "image"]
        delta("images:" + ",".join(tags))
        result(True)
        continue
    if text in ("slow", "wedge"):
        delta("考え中")
        waiting_interrupt = text == "slow"
        wedged = text == "wedge"
        continue
    delta(f"turn{turns}:")
    delta(text)
    result(True, f"turn{turns}:{text}")
