#!/usr/bin/env python3
"""H-172 QA: put two demo bots into waiting_for_approval through their own hook channel.

  approval_waits.py <demo out> <port> <control port>

Architect: the bare Notification (via the demo's /approval) -> "Architect needs approval".
Designer: a PreToolUse whose input carries a fake secret, then the Notification -> the row's
summary must come out masked.
"""
import json, os, sys, urllib.request
sys.path.insert(0, "demo")
from make_demo import Socket

out, port, control = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
home = os.path.join(out, "gravity")
ws = Socket(port)
ws.request("hello", protocol_version=2, token=open(os.path.join(home, "secrets", "client.token")).read().strip(), client="qa-h172")
bots = {b["name"]: b["id"] for b in ws.request("list_bots")["bots"] if not b.get("peer")}

def post(path, body=b""):
    return urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{control}{path}", data=body, method="POST"), timeout=10).read()

def hook(bot, payload):
    token = open(os.path.join(home, "secrets", f"bot-{bots[bot]}.token")).read().strip()
    urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/hook", data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}), timeout=10).read()

print("Architect:", post("/approval?bot=Architect"))
hook("Designer", {"hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": "curl -H 'Authorization: Bearer sk-live-QA172s3cr3tTOKEN' https://api.example.com/v1/upload",
                                 "description": "Upload the screenshots"}})
hook("Designer", {"hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"})
for name in ("Architect", "Designer"):
    bot = next(b for b in ws.request("list_bots")["bots"] if b["name"] == name and not b.get("peer"))
    print(name, bot.get("state"), json.dumps(bot.get("state_reason") or bot.get("reason") or "")[:200])
