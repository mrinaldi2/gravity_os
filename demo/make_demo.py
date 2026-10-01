#!/usr/bin/env python3
"""A made-up Gravity team for trying GravitiOS without your own bots.

Starts a throwaway gravityd in its own folder with the deterministic "double"
runtime (no Claude sessions, no tokens spent), creates two projects and eight
bots, has them raise decisions, writes Claude Code style logs and reports for
Gravity Lens to read, and optionally serves the lot:

    python3 demo/make_demo.py --serve

Nothing outside the output folder (default /tmp/gravitios-demo) is touched.
Everything in it is fiction. Standard library only.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
LENS = os.path.join(HERE, "..", "companion", "gravity_lens.py")
NOW = datetime.now(timezone.utc)


# ---------------------------------------------------------------- daemon

class Socket:
    """Just enough WebSocket for the daemon's control plane."""

    def __init__(self, port: int):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        self.reader = self.sock.makefile("rb")
        if b" 101 " not in self.reader.readline():
            raise SystemExit("gravityd refused the WebSocket upgrade")
        while self.reader.readline() not in (b"\r\n", b""):
            pass
        self.next = 0

    def send(self, message: Dict[str, Any]) -> None:
        payload = json.dumps(message).encode()
        mask = os.urandom(4)
        header = bytearray([0x81])
        if len(payload) < 126:
            header.append(0x80 | len(payload))
        elif len(payload) < 65536:
            header += bytes([0x80 | 126]) + len(payload).to_bytes(2, "big")
        else:
            header += bytes([0x80 | 127]) + len(payload).to_bytes(8, "big")
        self.sock.sendall(bytes(header) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def receive(self) -> Dict[str, Any]:
        data = b""
        while True:
            first = self.reader.read(2)
            length = first[1] & 0x7F
            if length == 126:
                length = int.from_bytes(self.reader.read(2), "big")
            elif length == 127:
                length = int.from_bytes(self.reader.read(8), "big")
            data += self.reader.read(length)
            if first[0] & 0x80:
                break
        return json.loads(data)

    def request(self, kind: str, **fields: Any) -> Dict[str, Any]:
        self.next += 1
        req_id = str(self.next)
        self.send({"type": kind, "req_id": req_id, **fields})
        while True:
            reply = self.receive()
            if reply.get("req_id") == req_id:
                if reply.get("type") == "error":
                    raise SystemExit(f"{kind} failed: {reply.get('message')}")
                return reply


def find_gravityd(explicit: Optional[str]) -> str:
    for path in (explicit, os.path.expanduser("~/.gravity/bin/gravityd"),
                 "/Applications/Gravity.app/Contents/MacOS/gravityd"):
        if path and os.access(path, os.X_OK):
            return path
    raise SystemExit("gravityd not found: install Gravity (getgravity.build) or pass --gravityd")


def healthy(port: int) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1) as response:
            return response.status == 200
    except OSError:
        return False


def start_daemon(gravityd: str, out: str, port: int) -> subprocess.Popen:
    home = os.path.join(out, "gravity")
    os.makedirs(home, exist_ok=True)
    config = os.path.join(out, "gravityd.toml")
    with open(config, "w") as handle:
        # user_home: where the daemon reads Claude Code transcripts (~/.claude/projects),
        # for daemons that serve the chat themselves.
        handle.write(f'home = "{home}"\nuser_home = "{os.path.join(out, "user-home")}"\n'
                     f'bind = ["127.0.0.1"]\nport = {port}\nnegotiate_port = false\nruntime = "double"\n')
    log = open(os.path.join(out, "gravityd.log"), "ab")
    daemon = subprocess.Popen([gravityd, "--config", config], stdout=log, stderr=log)
    for _ in range(50):
        if healthy(port):
            return daemon
        time.sleep(0.2)
    daemon.kill()
    raise SystemExit(f"the demo daemon did not start; see {out}/gravityd.log")


def bot_tool(port: int, home: str, bot_id: str, name: str, **arguments: Any) -> Dict[str, Any]:
    """What bots do on the bus (decisions, tasks) goes through their MCP tools, with the bot's token."""
    with open(os.path.join(home, "secrets", f"bot-{bot_id}.token")) as handle:
        token = handle.read().strip()
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": name, "arguments": arguments}}).encode()
    request = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", data=body, headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream"})
    reply = json.loads(urllib.request.urlopen(request, timeout=10).read())
    try:
        return json.loads(reply["result"]["content"][0]["text"])
    except (KeyError, IndexError, ValueError):
        return {}


def raise_decision(port: int, home: str, bot_id: str, **arguments: Any) -> None:
    bot_tool(port, home, bot_id, "raise_decision", **arguments)


def hand_out_tasks(port: int, home: str, bots: Dict[str, Dict[str, str]]) -> None:
    """Work bots gave each other, for the Tasks tab: open, waiting and done."""
    def send(sender: str, to: str, body: str, hours: int = 24) -> str:
        return bot_tool(port, home, bots[sender]["id"], "send_message", to=to, kind="task", body=body,
                        deadline_hours=hours).get("task_id", "")

    send("iOS Dev", "QA Tester", "Run the sync suite on build 142 on the SE and the 15, and report every layout "
         "bug in the conflict banner with a screenshot.", hours=8)
    send("QA Tester", "Backend Dev", "The SE run needs a sync server with two devices' worth of conflicting edits. "
         "Can you seed the staging server with the conflict fixtures?", hours=4)
    schema = send("Architect", "Backend Dev", "Write the conflict resolution note for the sync server. It should "
                  "cover:\n\n1. **Vector clocks** per note: how they are stored, merged and compacted.\n"
                  "2. **Last-writer-wins** for titles and tags, and why bodies are different.\n"
                  "3. The **three-way merge** for bodies when edits do not overlap, with the paragraph as the unit.\n"
                  "4. What the server sends the app when it cannot merge, so the banner can show both versions.\n"
                  "5. The migration for notes written before clocks existed.\n\n"
                  "Put it in the artifacts as sync-conflicts.md and keep it under two pages.")
    bot_tool(port, home, bots["Backend Dev"]["id"], "complete_task", task_id=schema, result=(
        "Done: **sync-conflicts.md** is in the artifacts.\n\n"
        "- Each note carries a vector clock keyed by device, merged element-wise and compacted when a device has "
        "been silent for 90 days.\n- Titles and tags are last-writer-wins on the clock; bodies are not, because a "
        "lost paragraph is worse than a banner.\n- Bodies merge three ways by paragraph when edits do not overlap.\n"
        "- When they do, the server answers `409 conflict` with both versions and their clocks, which is exactly "
        "what the banner needs.\n- Old notes get a clock of zero on first sync, so any edit wins over them.\n\n"
        "The test fixtures cover all five cases."), artifacts=["sync-conflicts.md"])
    copy = send("Designer", "Copywriter", "Two lines for the conflict banner: one for 'edited on two devices', "
                "one for the merge that worked.")
    bot_tool(port, home, bots["Copywriter"]["id"], "complete_task", task_id=copy,
             result="\"This note changed on two devices. Keep both?\" and \"Merged edits from your other device.\"")


# ---------------------------------------------------------------- logs

def stamp(minutes_ago: float) -> str:
    return (NOW - timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%S.") + "000Z"


class Log:
    """Writes one bot's Claude Code session log, turn by turn."""

    def __init__(self) -> None:
        self.records: List[Dict[str, Any]] = []
        self.clock = 0.0
        self.started = 0.0

    def _add(self, record: Dict[str, Any], seconds: float = 20) -> None:
        self.clock -= seconds / 60
        record.setdefault("uuid", str(uuid.uuid4()))
        record["timestamp"] = stamp(max(self.clock, 0.05))
        self.records.append(record)

    def message(self, minutes_ago: float, sender: str, kind: str, num: int, text: str) -> "Log":
        self.clock = self.started = minutes_ago
        self._add({"type": "user", "isMeta": True, "message": {"role": "user", "content":
                   f"Another Claude session sent a message:\n[msg #{num} from {sender.upper()} · {kind}] {text}"}}, 0)
        return self

    def typed(self, minutes_ago: float, text: str) -> "Log":
        self.clock = self.started = minutes_ago
        self._add({"type": "user", "message": {"role": "user", "content": text}}, 0)
        return self

    def say(self, text: str) -> "Log":
        self._add({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}})
        return self

    def tool(self, name: str, arguments: Dict[str, Any], output: Optional[str] = None,
             result: Optional[Dict[str, Any]] = None, content: Any = None, error: bool = False) -> "Log":
        tool_id = "toolu_" + uuid.uuid4().hex[:20]
        self._add({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": tool_id, "name": name, "input": arguments}]}}, 15)
        if output is None and result is None and content is None:
            return self  # still running
        block = {"type": "tool_result", "tool_use_id": tool_id, "content": content if content is not None else output or ""}
        if error:
            block["is_error"] = True
        self._add({"type": "user", "message": {"role": "user", "content": [block]},
                   "toolUseResult": result if result is not None else {"stdout": output or "", "stderr": ""}}, 25)
        return self

    def bash(self, description: str, command: str, output: Optional[str], error: bool = False) -> "Log":
        return self.tool("Bash", {"command": command, "description": description}, output=output,
                         result=None if output is None else {"stdout": output, "stderr": "", "interrupted": False},
                         error=error)

    def read(self, path: str, lines: int = 120) -> "Log":
        return self.tool("Read", {"file_path": path}, output=f"{lines} lines")

    def look(self, path: str, image: str) -> "Log":
        with open(image, "rb") as handle:
            data = base64.b64encode(handle.read()).decode()
        return self.tool("Read", {"file_path": path}, content=[{"type": "image", "source": {
            "type": "base64", "media_type": "image/png", "data": data}}], result={"type": "image"})

    def edit(self, path: str, start: int, lines: List[str]) -> "Log":
        old = sum(1 for line in lines if not line.startswith("+"))
        new = sum(1 for line in lines if not line.startswith("-"))
        return self.tool("Edit", {"file_path": path, "old_string": "…", "new_string": "…"}, result={
            "filePath": path, "structuredPatch": [{"oldStart": start, "oldLines": old, "newStart": start,
                                                   "newLines": new, "lines": lines}]}, output="ok")

    def send(self, to: str, kind: str, body: str) -> "Log":
        return self.tool("mcp__gravity-bus__send_message", {"to": to, "kind": kind, "body": body}, output="sent")

    def incoming(self, sender: str, kind: str, num: int, text: str) -> "Log":
        self._add({"type": "attachment", "attachment": {"type": "queued_command",
                   "prompt": f"[msg #{num} from {sender.upper()} · {kind}] {text}"}})
        return self

    def complete(self, result: str, artifacts: List[str]) -> "Log":
        return self.tool("mcp__gravity-bus__complete_task", {"task_id": str(uuid.uuid4()), "result": result,
                                                             "artifacts": artifacts}, output="completed")

    def end(self) -> "Log":
        self._add({"type": "system", "subtype": "turn_duration",
                   "durationMs": int((self.started - self.clock) * 60_000) + 4000}, 2)
        return self

    def write(self, folder: str) -> None:
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, f"{uuid.uuid4()}.jsonl"), "w") as handle:
            for record in self.records:
                handle.write(json.dumps(record) + "\n")


def project_folder(workspace: str) -> str:
    """Claude Code's folder name: every character but letters and digits becomes "-"."""
    return re.sub(r"[^A-Za-z0-9]", "-", workspace)


# ---------------------------------------------------------------- the team

PROJECTS = [
    ("Aurora Notes", [
        ("Architect", "icon:orbit", "Owns the architecture of Aurora Notes and keeps the team's plan coherent."),
        ("iOS Dev", "icon:ember", "Builds the SwiftUI app: sync, editor and widgets."),
        ("Backend Dev", "icon:tide", "Runs the sync API and its Postgres schema."),
        ("QA Tester", "icon:volt", "Tests every build on devices and writes the release reports."),
        ("Designer", "icon:bloom", "Owns the design system, icons and screens."),
        ("Tech Writer", "icon:quartz", "Writes the docs, changelog and App Store copy."),
    ]),
    ("Website", [
        ("Web Dev", "icon:comet", "Builds the marketing site."),
        ("Copywriter", "icon:mint", "Writes the words on the website."),
    ]),
]

SRC = "/Users/you/Code/aurora-notes"


def write_logs(bots: Dict[str, Dict[str, str]], shots: str, artifacts: Dict[str, str]) -> Dict[str, Log]:
    aurora = artifacts["Aurora Notes"]
    logs: Dict[str, Log] = {name: Log() for name in bots}

    # iOS Dev: finished the conflict banner, now running the UI tests.
    ios = logs["iOS Dev"]
    ios.message(95, "Architect", "task", 41,
                "Build the sync-conflict banner from the design in design-tokens.md. When the server returns 409, "
                "keep both versions and show the banner on the notes list. Flag it behind `syncConflictsUI`.")
    ios.say("Starting on the conflict banner. I'll read the store and the sync client first.")
    ios.read(f"{SRC}/Sources/Sync/NoteStore.swift", 212).read(f"{SRC}/Sources/Sync/SyncClient.swift", 148)
    ios.edit(f"{SRC}/Sources/Sync/NoteStore.swift", 88, [
        "     func apply(_ change: RemoteChange) throws {",
        "-        notes[change.id] = change.note",
        "+        if let local = notes[change.id], local.revision != change.baseRevision {",
        "+            conflicts.append(Conflict(local: local, remote: change.note))",
        "+            return",
        "+        }",
        "+        notes[change.id] = change.note",
        "     }"])
    ios.edit(f"{SRC}/Sources/Views/NotesList.swift", 31, [
        "     var body: some View {",
        "         List {",
        "+            if featureFlags.syncConflictsUI, !store.conflicts.isEmpty {",
        "+                ConflictBanner(count: store.conflicts.count)",
        "+            }",
        "             ForEach(store.sortedNotes) { NoteRow(note: $0) }"])
    ios.bash("Build for the simulator", "xcodebuild -scheme Aurora -destination 'platform=iOS Simulator,name=iPhone 16' build",
             "CompileSwift normal arm64 NoteStore.swift\nCompileSwift normal arm64 NotesList.swift\nLd Aurora.app\n** BUILD SUCCEEDED ** [41.2 sec]")
    ios.bash("Screenshot the notes list in light and dark", "./scripts/snap.sh notes-list --appearance light,dark",
             f"saved {shots}/notes_list_light.png\nsaved {shots}/notes_list_dark.png")
    ios.send("QA Tester", "task", "Build 142 is up on TestFlight with the conflict banner behind `syncConflictsUI`. "
             "Please run the sync suite on the iPhone 15 and the SE, and check the banner in dark mode.")
    ios.incoming("QA Tester", "reply", 58, "On it. Starting with the SE, it had the layout bugs last time.")
    ios.say("Handed build 142 to QA. While they test I'm running the UI tests locally.")
    ios.bash("Run the UI tests", "xcodebuild test -scheme AuroraUITests -destination 'platform=iOS Simulator,name=iPhone 16'", None)

    # QA Tester: tested build 141, filed a report with a chart.
    qa = logs["QA Tester"]
    qa.message(180, "iOS Dev", "task", 37, "Build 141 is on TestFlight: offline mode and faster launch. Full regression please.")
    qa.bash("Install build 141 on the test devices", "./qa/install.sh --build 141 --devices iphone15,iphonese",
            "iPhone 15 (17.5): installed 141\niPhone SE (17.5): installed 141")
    qa.bash("Run the regression suite", "./qa/run.sh --suite regression --build 141",
            "Regression · build 141\n  sync ............ 48 passed\n  editor .......... 61 passed\n  widgets ......... 12 passed\n"
            "  offline ......... 29 passed, 2 FAILED\n    ✗ offline_edit_then_delete_on_other_device\n    ✗ offline_rename_while_syncing\n"
            "150 passed, 2 failed", error=True)
    qa.bash("Measure cold launch time", "./qa/launch_time.py --builds 136-142 --device iphone15 --runs 10",
            f"median cold launch: 431 ms (budget 500 ms)\nchart: {shots}/launch_time.png")
    qa.look(f"{shots}/notes_list_light.png", os.path.join(shots, "notes_list_light.png"))
    qa.say("Two offline failures, both about a note changing on another device while this one is offline. "
           "That is exactly what the conflict banner is for, so I'm sending them to iOS Dev rather than filing them as regressions.")
    qa.send("iOS Dev", "reply", "Build 141: 150 passed, 2 failed, both offline edits racing another device "
            "(`offline_edit_then_delete_on_other_device`, `offline_rename_while_syncing`). Launch is down to 431 ms. Report attached.")
    qa.complete("Regression for build 141: 150/152 pass; the 2 failures are sync conflicts the banner will cover. "
                "Cold launch 431 ms, inside the 500 ms budget.", [f"{aurora}/qa-build-141.md"])
    qa.end()
    qa.message(20, "iOS Dev", "task", 57, "Build 142 is up on TestFlight with the conflict banner behind `syncConflictsUI`.")
    qa.bash("Install build 142", "./qa/install.sh --build 142 --devices iphone15,iphonese", "iPhone 15: installed 142\niPhone SE: installed 142")
    qa.send("iOS Dev", "reply", "On it. Starting with the SE, it had the layout bugs last time.")
    qa.bash("Run the sync suite on the SE", "./qa/run.sh --suite sync --build 142 --device iphonese", None)

    # Architect: the owner asked for a plan; wrote the design and raised a decision.
    arch = logs["Architect"]
    arch.typed(240, "Plan how sync conflicts should work end to end. Keep it simple enough to ship this month.")
    arch.read(f"{SRC}/docs/architecture.md", 310).read(f"{SRC}/server/sync/changes.go", 180)
    arch.tool("Write", {"file_path": f"{aurora}/sync-engine-design.md", "content": "# Sync engine…"},
              result={"type": "create", "filePath": f"{aurora}/sync-engine-design.md", "content": "…",
                      "structuredPatch": []}, output="written")
    arch.tool("mcp__gravity-bus__raise_decision", {"title": "Resolve conflicts automatically or always ask?"}, output="raised")
    arch.say("## Plan\n\nConflicts are **detected on the server** and **resolved on the device**:\n\n"
             "1. Every note carries a `revision`. A change is sent with the revision it was based on.\n"
             "2. The server rejects a stale change with `409` and returns the current note.\n"
             "3. The app keeps both versions and shows a banner; nothing is lost silently.\n\n"
             "| Field | Rule |\n|---|---|\n| Title | last writer wins |\n| Body | keep both, ask |\n| Tags | union |\n\n"
             "I've written it up in `sync-engine-design.md` and asked you one question in Decisions: "
             "whether bodies should merge automatically.")
    arch.end()
    arch.message(100, "User", "chat", 40, "Go with the plan. Split the work between iOS Dev and Backend Dev.")
    arch.send("iOS Dev", "task", "Build the sync-conflict banner from the design in design-tokens.md.")
    arch.send("Backend Dev", "task", "Return 409 with the current note when a change is based on a stale revision.")
    arch.say("Split the work: Backend Dev returns `409` on stale revisions, iOS Dev builds the banner behind a flag.")
    arch.end()

    # Backend Dev: shipped the 409 path.
    be = logs["Backend Dev"]
    be.message(98, "Architect", "task", 42, "Return 409 with the current note when a change is based on a stale revision.")
    be.read("/Users/you/Code/aurora-notes/server/sync/changes.go", 180)
    be.edit("/Users/you/Code/aurora-notes/server/sync/changes.go", 64, [
        "     current, err := s.notes.Get(ctx, change.NoteID)",
        "     if err != nil { return err }",
        "+    if current.Revision != change.BaseRevision {",
        "+        return conflictError(current) // 409 with the note as it is now",
        "+    }",
        "     return s.notes.Put(ctx, change.Apply(current))"])
    be.bash("Run the server tests", "go test ./server/...",
            "ok  \taurora/server/auth\t0.412s\nok  \taurora/server/sync\t1.873s\nok  \taurora/server/notes\t0.955s")
    be.bash("Deploy to staging", "./deploy.sh staging", "staging: v2.14.0 → v2.15.0 · healthy in 38 s")
    be.send("iOS Dev", "note", "Staging now returns `409` with the current note in the body. Shape: `{ \"note\": {…}, \"revision\": 18 }`.")
    be.complete("Stale changes now get 409 with the current note; tests pass; on staging as v2.15.0.", [])
    be.end()

    # Designer: design tokens with the palette.
    design = logs["Designer"]
    design.message(300, "Architect", "task", 33, "We need a banner style for sync conflicts that works in both themes.")
    design.bash("Export the palette", "./design/export.sh tokens --format png", f"wrote {shots}/palette.png")
    design.look(f"{shots}/notes_list_dark.png", os.path.join(shots, "notes_list_dark.png"))
    design.complete("Banner uses amber/500 on paper in light and amber/500 at 20% on ink in dark. Tokens and palette attached.",
                    [f"{aurora}/design-tokens.md"])
    design.end()

    # Tech Writer and the website team.
    writer = logs["Tech Writer"]
    writer.message(60, "iOS Dev", "note", 50, "The conflict banner ships behind a flag in 142. Changelog entry please.")
    writer.edit(f"{SRC}/CHANGELOG.md", 1, ["+## 1.8 (build 142)", "+", "+- Notes edited on two devices at once are kept side by side, with a banner to review them.",
                                           "+- The app opens up to 30% faster.", "+", " ## 1.7"])
    writer.say("Changelog for 1.8 is in. I kept it to what people will notice: no lost edits, faster launch.")
    writer.end()

    web = logs["Web Dev"]
    web.message(420, "Copywriter", "note", 12, "Hero copy is final: “Your notes, everywhere, even offline.”")
    web.edit("/Users/you/Code/aurora-site/src/pages/index.astro", 12, [
        "-<h1>Notes that sync</h1>", "+<h1>Your notes, everywhere, even offline.</h1>"])
    web.bash("Build the site", "npm run build", "✓ 14 pages built in 2.31s")
    web.end()

    copy = logs["Copywriter"]
    copy.typed(460, "Write the homepage hero for the offline launch.")
    copy.say("Three options, shortest first:\n\n1. **Your notes, everywhere, even offline.**\n2. Write anywhere. Sync when you can.\n"
             "3. Offline is not an excuse to forget.\n\nI'd go with 1: it names the feature and the benefit in six words.")
    copy.send("Web Dev", "note", "Hero copy is final: “Your notes, everywhere, even offline.”")
    copy.end()
    return logs


def write_reports(folder: str, shots: str) -> None:
    for image in ("launch_time.png", "palette.png"):
        shutil.copy(os.path.join(ASSETS, image), os.path.join(folder, image))
    reports = {
        "qa-build-141.md": """# QA report · build 141

**Result:** 150 of 152 pass. Both failures are sync conflicts that the conflict banner (build 142) will surface.

| Suite | Passed | Failed |
|---|---:|---:|
| Sync | 48 | 0 |
| Editor | 61 | 0 |
| Widgets | 12 | 0 |
| Offline | 29 | 2 |

## Failures

- `offline_edit_then_delete_on_other_device`: the edit is lost when another device deletes the note.
- `offline_rename_while_syncing`: the title from the other device overwrites the local one.

## Launch time

Cold launch is **431 ms** (median of 10 on an iPhone 15), inside the 500 ms budget.

![Cold launch time by build](launch_time.png)
""",
        "sync-engine-design.md": """# Sync engine: conflicts

Conflicts are detected on the server and resolved on the device.

1. Every note carries a `revision`.
2. A change is sent with the revision it was based on.
3. A stale change gets `409 Conflict` and the current note.
4. The app keeps both versions and shows a banner.

```swift
if local.revision != change.baseRevision {
    conflicts.append(Conflict(local: local, remote: change.note))
}
```

## Open question

Should note bodies merge automatically when the edits do not overlap? Raised as a decision.
""",
        "design-tokens.md": """# Design tokens

The conflict banner uses **amber/500** on paper in light mode and amber/500 at 20% on ink in dark mode.

![Colour tokens](palette.png)

| Token | Light | Dark |
|---|---|---|
| banner.background | `#FFF3E0` | `#FFB240` @ 20% |
| banner.text | `#AA6400` | `#FFB240` |
""",
    }
    for name, text in reports.items():
        with open(os.path.join(folder, name), "w") as handle:
            handle.write(text)


def write_home(home: str) -> None:
    """A small made-up home folder for the file browser."""
    files = {
        "Code/aurora-notes/README.md": "# Aurora Notes\n\nNotes that sync, even offline.\n\n```bash\nswift build\n```\n",
        "Code/aurora-notes/CHANGELOG.md": "## 1.8 (build 142)\n\n- Conflicting edits are kept side by side.\n- Up to 30% faster launch.\n",
        "Code/aurora-notes/Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\n",
        "Code/aurora-notes/Sources/Sync/NoteStore.swift": "final class NoteStore {\n    var notes: [UUID: Note] = [:]\n}\n",
        "Code/aurora-notes/Sources/Sync/SyncClient.swift": "struct SyncClient {}\n",
        "Code/aurora-notes/Sources/Views/NotesList.swift": "import SwiftUI\n",
        "Code/aurora-notes/server/sync/changes.go": "package sync\n",
        "Code/aurora-site/src/pages/index.astro": "<h1>Your notes, everywhere, even offline.</h1>\n",
        "Documents/Offsite agenda.md": "# Offsite\n\n1. Roadmap\n2. Hiring\n",
        "Downloads/aurora-1.8.zip": "not really a zip",
    }
    for relative, text in files.items():
        path = os.path.join(home, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)
    shots = os.path.join(home, "Code", "aurora-notes", "docs", "screenshots")
    os.makedirs(shots, exist_ok=True)
    for image in ("notes_list_light.png", "notes_list_dark.png", "launch_time.png"):
        shutil.copy(os.path.join(ASSETS, image), os.path.join(shots, image))
    os.makedirs(os.path.join(home, "Desktop"), exist_ok=True)
    shutil.copy(os.path.join(ASSETS, "palette.png"), os.path.join(home, "Desktop", "palette.png"))


# ---------------------------------------------------------------- main

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="/tmp/gravitios-demo")
    parser.add_argument("--port", type=int, default=49790, help="demo gravityd port")
    parser.add_argument("--lens-port", type=int, default=49788)
    parser.add_argument("--gravityd", help="path to gravityd (default: the one Gravity installed)")
    parser.add_argument("--serve", action="store_true", help="keep the daemon running and start Gravity Lens")
    args = parser.parse_args()

    out = args.out
    if os.path.exists(out):
        shutil.rmtree(out)
    home = os.path.join(out, "gravity")
    claude = os.path.join(out, "user-home", ".claude", "projects")
    shots = os.path.join(out, "shots")
    os.makedirs(shots)
    for image in os.listdir(ASSETS):
        shutil.copy(os.path.join(ASSETS, image), os.path.join(shots, image))

    daemon = start_daemon(find_gravityd(args.gravityd), out, args.port)
    with open(os.path.join(home, "secrets", "client.token")) as handle:
        token = handle.read().strip()
    ws = Socket(args.port)
    ws.request("hello", protocol_version=2, token=token, client="gravitios-demo")

    bots: Dict[str, Dict[str, str]] = {}
    artifacts: Dict[str, str] = {}
    for project_name, members in PROJECTS:
        project = ws.request("create_project", name=project_name)["project"]
        artifacts[project_name] = os.path.join(home, "projects", project["dir_name"], "artifacts")
        os.makedirs(artifacts[project_name], exist_ok=True)
        for name, avatar, description in members:
            bot = ws.request("create_bot", project_id=project["id"], name=name, avatar=avatar,
                             description=description, instructions=description)["bot"]
            bots[name] = {"id": bot["id"], "workspace": os.path.join(home, "projects", project["dir_name"],
                                                                      "bots", bot["dir_name"], "workspace")}

    for name, log in write_logs(bots, shots, artifacts).items():
        log.write(os.path.join(claude, project_folder(bots[name]["workspace"])))
    write_reports(artifacts["Aurora Notes"], shots)

    raise_decision(args.port, home, bots["Architect"]["id"], kind="decision",
                   title="Resolve conflicts automatically or always ask?",
                   body="When two devices edit the same note body, we can **merge automatically** when the edits "
                        "don't overlap, or **always ask**. Merging is less friction; asking never surprises anyone.\n\n"
                        "Meanwhile the banner asks in every case.",
                   options=[{"key": "merge", "label": "Merge when edits don't overlap",
                             "description": "Fewer banners; about two more days of work."},
                            {"key": "ask", "label": "Always ask", "description": "Ships with build 142 as it is."}],
                   recommendation="ask", priority="urgent", tags=["sync"])
    raise_decision(args.port, home, bots["Designer"]["id"], kind="question",
                   title="Which accent colour for the App Store screenshots?",
                   body="Amber matches the app; blue tests better in the store. Your call.")
    raise_decision(args.port, home, bots["Copywriter"]["id"], kind="decision",
                   title="Launch the site with the offline headline?",
                   options=[{"key": "yes", "label": "Yes, go live Monday"}, {"key": "wait", "label": "Wait for sharing"}],
                   body="The page is built and staged.")
    hand_out_tasks(args.port, home, bots)
    ws.request("send_user_message", to_bot_id=bots["iOS Dev"]["id"],
               body="Nice work on the banner. Keep it behind the flag until QA signs off.")

    launch = (f"xcrun simctl launch booted <your bundle id> -gravHost 127.0.0.1 -gravPort {args.port} "
              f"-lensPort {args.lens_port} -gravToken {token}")
    print(f"Demo ready in {out}\n  daemon: 127.0.0.1:{args.port}  token: {home}/secrets/client.token")
    print(f"  simulator (Debug build): {launch}")
    if not args.serve:
        print("Stop the demo daemon with: kill", daemon.pid)
        return
    mac_home = os.path.join(out, "mac-home")
    write_home(mac_home)
    lens = subprocess.Popen([sys.executable, LENS, "--port", str(args.lens_port), "--bind", "127.0.0.1",
                             "--gravity-home", home, "--claude-projects", claude, "--daemon-port", str(args.port),
                             "--files-root", mac_home, "--displays-json", json.dumps([
                                 {"id": 1, "main": True, "x": 0, "y": 0, "width": 1920, "height": 1200},
                                 {"id": 2, "main": False, "x": 1920, "y": 0, "width": 1920, "height": 1200}])])
    print(f"  Gravity Lens: 127.0.0.1:{args.lens_port}\nServing. Ctrl-C stops both.")
    try:
        daemon.wait()
    except KeyboardInterrupt:
        pass
    finally:
        lens.terminate()
        daemon.terminate()


if __name__ == "__main__":
    main()
