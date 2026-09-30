#!/usr/bin/env python3
"""Gravity Lens: a read-only view of what each Gravity bot is doing.

Every Gravity bot is a Claude Code session, and Claude Code logs each turn to
~/.claude/projects/<workspace>/<session>.jsonl. The daemon does not serve those
logs, so this companion does: it parses them into turns (what the bot was
asked, the commands it ran, the files it changed, what it answered) and serves
them, plus the shared artifacts folder, as JSON for GravitiOS.

Access needs a Gravity device token with the `read` grant. Tokens are checked
by handshaking with the daemon itself, so revoking a device in Gravity cuts it
off here too. Images are served only when a bot's log or a report refers to
them. The only thing written is a thumbnail cache in ~/Library/Caches/GravityLens.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional
from urllib.parse import parse_qs, unquote, urlparse

VERSION = "0.1.0"
OUTPUT_LIMIT = 12_000
DIFF_LINE_LIMIT = 400
TEXT_LIMIT = 8_000
ARTIFACT_LIMIT = 2_000_000
ARTIFACT_SUFFIXES = (".md", ".markdown", ".txt", ".json", ".csv", ".log", ".yaml", ".yml", ".toml")
IMAGE_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
               ".webp": "image/webp", ".heic": "image/heic"}
IMAGE_PATH = re.compile(r"(/[^\s\"'`<>()\[\]{},;|]+\.(?:png|jpe?g|gif|webp|heic))", re.I)
IMAGE_LIMIT = 30_000_000
IMAGES_PER_EVENT = 24
THUMB_DIR = os.path.join(os.path.expanduser("~"), "Library", "Caches", "GravityLens", "thumbs")

PEER_PREFIX = "Another Claude session sent a message:\n"
CONTINUED_PREFIX = "This session is being continued from a previous conversation"
ENVELOPE = re.compile(r"^\[(msg #(?P<num>\d+)|decision (?P<decision>[0-9a-f]+)) from (?P<from>[^·\]]+?)(?P<meta>(?: · [^\]]*)?)\]\s*(?P<body>.*)$", re.S)


def truncate(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit] + f"\n… ({len(text) - limit} more characters)"


def tail(text: str, limit: int) -> str:
    return text if len(text) <= limit else f"… ({len(text) - limit} earlier characters)\n" + text[-limit:]


def mangle(path: str) -> str:
    """Claude Code's project folder name for a working directory."""
    return re.sub(r"[/.]", "-", path)


def parse_envelope(text: str) -> Dict[str, Any]:
    """`[msg #42 from BOB · task · re #7] body` -> its parts."""
    match = ENVELOPE.match(text.strip())
    if not match:
        return {"from": "", "msg_kind": "", "num": None, "text": text.strip()}
    meta = [part.strip() for part in match.group("meta").split("·") if part.strip()]
    kind = "decision" if match.group("decision") else (meta[0] if meta else "")
    sender = match.group("from").strip()
    return {
        "from": "You" if sender == "USER" else sender.title() if sender.isupper() else sender,
        "msg_kind": kind,
        "num": int(match.group("num")) if match.group("num") else None,
        "text": match.group("body").strip(),
    }


def block_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def base(path: str) -> str:
    return os.path.basename(path.rstrip("/")) or path


def short_path(path: str) -> str:
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home) else path


# ---------------------------------------------------------------- transcript

class Turn:
    def __init__(self, turn_id: str, at: str, trigger: Dict[str, Any]):
        self.id = turn_id
        self.started_at = at
        self.updated_at = at
        self.ended_at: Optional[str] = None
        self.duration_ms: Optional[int] = None
        self.trigger = trigger
        self.events: List[Dict[str, Any]] = []
        self.details: Dict[str, Dict[str, Any]] = {}

    def add(self, event: Dict[str, Any], detail: Optional[Dict[str, Any]] = None) -> None:
        self.events.append(event)
        self.updated_at = event.get("at") or self.updated_at
        if detail is not None:
            self.details[event["id"]] = detail

    def stats(self) -> Dict[str, Any]:
        files: List[str] = []
        stats = {"commands": 0, "reads": 0, "edits": 0, "added": 0, "removed": 0,
                 "sent": 0, "incoming": 0, "errors": 0, "steps": 0, "images": 0}
        for event in self.events:
            kind = event["kind"]
            if kind == "tool":
                stats["steps"] += 1
                tool = event.get("tool")
                if tool == "Bash":
                    stats["commands"] += 1
                elif tool == "Read":
                    stats["reads"] += 1
                if event.get("path") and tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
                    if event["path"] not in files:
                        files.append(event["path"])
                if event.get("error"):
                    stats["errors"] += 1
            elif kind == "sent":
                stats["sent"] += 1
            elif kind == "incoming":
                stats["incoming"] += 1
            stats["images"] += len(event.get("images") or [])
            stats["added"] += event.get("added", 0)
            stats["removed"] += event.get("removed", 0)
        stats["edits"] = len(files)
        stats["files"] = files[:30]
        return stats

    def outcome(self) -> Dict[str, Any]:
        """What the turn came to: its last reply, message or task result."""
        for event in reversed(self.events):
            if event["kind"] == "completed":
                return {"kind": "completed", "text": truncate(event.get("text", ""), 1500), "to": ""}
            if event["kind"] == "sent":
                return {"kind": "message", "text": truncate(event.get("text", ""), 1500), "to": event.get("to", "")}
            if event["kind"] == "text":
                return {"kind": "text", "text": truncate(event.get("text", ""), 1500), "to": ""}
        return {"kind": "none", "text": "", "to": ""}

    def summary(self, is_last: bool) -> Dict[str, Any]:
        current = ""
        for event in reversed(self.events):
            if event["kind"] in ("tool", "sent", "completed"):
                current = event["title"]
                break
        trigger = dict(self.trigger)
        trigger["text"] = truncate(trigger.get("text", ""), 700)
        cover = None
        for event in reversed(self.events):
            if event.get("images"):
                cover = event["images"][0]
                break
        return {
            "cover": cover,
            "id": self.id, "started_at": self.started_at, "updated_at": self.updated_at,
            "ended_at": self.ended_at, "duration_ms": self.duration_ms,
            "open": self.ended_at is None and is_last,
            "trigger": trigger, "outcome": self.outcome(), "stats": self.stats(),
            "current": current,
        }


class Transcript:
    """Incrementally parsed Claude Code logs for one bot workspace."""

    def __init__(self, folder: str):
        self.folder = folder
        self.offsets: Dict[str, int] = {}
        self.turns: List[Turn] = []
        self.current: Optional[Turn] = None
        self.pending_tools: Dict[str, Dict[str, Any]] = {}
        self.signature: Any = None
        self.counter = 0
        # image id -> ("inline", media type, base64) or ("file", absolute path)
        self.images: Dict[str, Any] = {}

    # Files -----------------------------------------------------------------

    def sessions(self) -> List[str]:
        try:
            names = [n for n in os.listdir(self.folder) if n.endswith(".jsonl")]
        except FileNotFoundError:
            return []
        paths = [os.path.join(self.folder, n) for n in names]

        def born(path: str) -> float:
            st = os.stat(path)
            return getattr(st, "st_birthtime", st.st_mtime)

        return sorted(paths, key=born)

    def refresh(self) -> bool:
        paths = self.sessions()
        signature = [(p, os.path.getsize(p)) for p in paths]
        if signature == self.signature:
            return False
        self.signature = signature
        for path in paths:
            offset = self.offsets.get(path, 0)
            size = os.path.getsize(path)
            if size < offset:  # rewritten: start over for everything
                self.__init__(self.folder)
                return self.refresh()
            if size == offset:
                continue
            with open(path, "rb") as handle:
                handle.seek(offset)
                data = handle.read()
            # Only whole lines; a half-written one is read next time.
            end = data.rfind(b"\n") + 1
            for raw in data[:end].splitlines():
                try:
                    self.consume(json.loads(raw))
                except (ValueError, KeyError, TypeError, AttributeError):
                    continue
            self.offsets[path] = offset + end
        return True

    # Records ---------------------------------------------------------------

    def next_id(self, prefix: str) -> str:
        self.counter += 1
        return f"{prefix}{self.counter}"

    def start(self, record: Dict[str, Any], trigger: Dict[str, Any]) -> Turn:
        if self.current is not None and self.current.ended_at is None:
            self.current.ended_at = self.current.updated_at
        turn = Turn(record.get("uuid") or self.next_id("t"), record.get("timestamp", ""), trigger)
        self.turns.append(turn)
        self.current = turn
        return turn

    def turn_for(self, record: Dict[str, Any]) -> Turn:
        if self.current is None or self.current.ended_at is not None:
            return self.start(record, {"kind": "continued", "from": "", "msg_kind": "", "num": None, "text": ""})
        return self.current

    def consume(self, record: Dict[str, Any]) -> None:
        if record.get("isSidechain"):
            return
        kind = record.get("type")
        at = record.get("timestamp", "")
        if kind == "user":
            self.user(record, at)
        elif kind == "assistant":
            self.assistant(record, at)
        elif kind == "attachment":
            attachment = record.get("attachment") or {}
            if attachment.get("type") == "queued_command" and attachment.get("prompt"):
                envelope = parse_envelope(str(attachment["prompt"]))
                self.turn_for(record).add({
                    "id": record.get("uuid") or self.next_id("i"), "at": at, "kind": "incoming",
                    "title": f"{envelope['from'] or 'Message'} · {envelope['msg_kind'] or 'message'}",
                    "from": envelope["from"], "msg_kind": envelope["msg_kind"],
                    "text": truncate(envelope["text"], TEXT_LIMIT),
                })
                self.attach_paths(self.current.events[-1], envelope["text"])
        elif kind == "system":
            subtype = record.get("subtype")
            if subtype == "turn_duration" and self.current is not None and self.current.ended_at is None:
                self.current.ended_at = at
                self.current.updated_at = at
                self.current.duration_ms = record.get("durationMs")
            elif subtype == "compact_boundary":
                self.turn_for(record).add({
                    "id": record.get("uuid") or self.next_id("c"), "at": at, "kind": "compacted",
                    "title": "Memory compacted", "text": "",
                })

    def user(self, record: Dict[str, Any], at: str) -> None:
        content = (record.get("message") or {}).get("content")
        if isinstance(content, str):
            if record.get("isMeta"):
                if content.startswith(PEER_PREFIX):
                    envelope = parse_envelope(content[len(PEER_PREFIX):])
                    self.start(record, {"kind": "message", **envelope})
                return
            if content.startswith(CONTINUED_PREFIX):
                return
            if content.startswith("<task-notification>"):
                summary = re.search(r"<summary>(.*?)</summary>", content, re.S)
                self.start(record, {"kind": "background", "from": "", "msg_kind": "", "num": None,
                                    "text": summary.group(1).strip() if summary else "A background job finished"})
                return
            if content.startswith("<"):  # slash commands and local command echoes
                return
            self.start(record, {"kind": "typed", "from": "You", "msg_kind": "", "num": None, "text": content.strip()})
            return
        if not isinstance(content, list):
            return
        typed = block_text(content)
        if typed.strip() and not any(b.get("type") == "tool_result" for b in content if isinstance(b, dict)):
            if not record.get("isMeta"):
                self.start(record, {"kind": "typed", "from": "You", "msg_kind": "", "num": None, "text": typed.strip()})
            return
        result = record.get("toolUseResult")
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_result":
                self.tool_result(block, result if isinstance(result, dict) else {})

    def assistant(self, record: Dict[str, Any], at: str) -> None:
        content = (record.get("message") or {}).get("content")
        if not isinstance(content, list):
            return
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text" and block.get("text", "").strip():
                turn = self.turn_for(record)
                text = block["text"].strip()
                last = turn.events[-1] if turn.events else None
                if last is not None and last["kind"] == "text":
                    last["text"] = truncate(last["text"] + "\n\n" + text, TEXT_LIMIT)
                else:
                    last = {"id": self.next_id("x"), "at": at, "kind": "text",
                            "title": "Reply", "text": truncate(text, TEXT_LIMIT)}
                    turn.add(last)
                self.attach_paths(last, text)
            elif block.get("type") == "tool_use":
                self.tool_use(record, block, at)

    # Images ----------------------------------------------------------------

    def attach_paths(self, event: Dict[str, Any], text: str) -> None:
        """Image files a step or message mentions become viewable with it."""
        refs = event.setdefault("images", [])
        known = {ref.get("path") for ref in refs}
        for path in IMAGE_PATH.findall(text or ""):
            if len(refs) >= IMAGES_PER_EVENT:
                break
            path = os.path.normpath(os.path.expanduser(path))
            if short_path(path) in known:
                continue
            image_id = "f" + hashlib.sha1(path.encode()).hexdigest()[:20]
            self.images[image_id] = ("file", path)
            refs.append({"id": image_id, "kind": "file", "name": base(path), "path": short_path(path)})
            known.add(short_path(path))
        if not refs:
            event.pop("images", None)

    def attach_inline(self, event: Dict[str, Any], blocks: Any) -> None:
        """Images a bot looked at are stored in the log itself."""
        if not isinstance(blocks, list):
            return
        refs = event.setdefault("images", [])
        for block in blocks:
            source = block.get("source") if isinstance(block, dict) and block.get("type") == "image" else None
            if not isinstance(source, dict) or source.get("type") != "base64":
                continue
            image_id = f"i{event['id']}-{len(refs)}"
            self.images[image_id] = ("inline", source.get("media_type", "image/png"), source.get("data", ""))
            path = event.get("path") or ""
            refs.insert(0, {"id": image_id, "kind": "inline", "name": base(path) if path else "image", "path": path})
            # The same picture as a file path would only show twice.
            refs[:] = [r for r in refs if not (r["kind"] == "file" and path and r.get("path") == path)]
        if not refs:
            event.pop("images", None)

    # Tools -----------------------------------------------------------------

    def tool_use(self, record: Dict[str, Any], block: Dict[str, Any], at: str) -> None:
        turn = self.turn_for(record)
        name = block.get("name", "")
        args = block.get("input") or {}
        event_id = block.get("id") or self.next_id("u")
        event: Dict[str, Any] = {"id": event_id, "at": at, "kind": "tool", "tool": name, "error": False}
        detail: Dict[str, Any] = {"input": ""}

        if name == "mcp__gravity-bus__send_message":
            event.update(kind="sent", to=args.get("to", ""), msg_kind=args.get("kind", "chat"),
                         title=f"Sent {args.get('kind') or 'message'} to {args.get('to', '')}",
                         text=truncate(str(args.get("body", "")), TEXT_LIMIT))
        elif name == "mcp__gravity-bus__complete_task":
            artifacts = [a for a in (args.get("artifacts") or []) if isinstance(a, str)]
            event.update(kind="completed", title="Completed a task",
                         text=truncate(str(args.get("result", "")), TEXT_LIMIT),
                         artifacts=[short_path(a) for a in artifacts])
        elif name == "Bash":
            command = str(args.get("command", ""))
            event.update(title=args.get("description") or "Ran a command",
                         subtitle=command.strip().splitlines()[0][:160] if command.strip() else "")
            detail["command"] = command
        elif name in ("Read", "NotebookRead"):
            path = str(args.get("file_path") or args.get("notebook_path") or "")
            event.update(title=f"Read {base(path)}", subtitle=short_path(path), path=short_path(path))
        elif name in ("Edit", "MultiEdit", "Write", "NotebookEdit"):
            path = str(args.get("file_path") or args.get("notebook_path") or "")
            verb = "Wrote" if name == "Write" else "Edited"
            event.update(title=f"{verb} {base(path)}", subtitle=short_path(path), path=short_path(path),
                         added=0, removed=0)
            if name == "Write":
                detail["content"] = truncate(str(args.get("content", "")), OUTPUT_LIMIT)
        elif name == "Grep":
            event.update(title=f"Searched for “{str(args.get('pattern', ''))[:60]}”",
                         subtitle=short_path(str(args.get("path", ""))))
        elif name == "Glob":
            event.update(title=f"Listed files {str(args.get('pattern', ''))[:60]}")
        elif name == "WebFetch":
            event.update(title="Opened a web page", subtitle=str(args.get("url", ""))[:160])
        elif name == "WebSearch":
            event.update(title=f"Searched the web for “{str(args.get('query', ''))[:80]}”")
        elif name in ("Task", "Agent"):
            event.update(title=f"Started a helper: {str(args.get('description', ''))[:80]}")
            detail["content"] = truncate(str(args.get("prompt", "")), OUTPUT_LIMIT)
        elif name == "mcp__gravity-bus__raise_decision":
            event.update(title=f"Asked you to decide: {str(args.get('title', ''))[:100]}", minor=False)
        elif name.startswith("mcp__gravity-bus__"):
            action = name[len("mcp__gravity-bus__"):].replace("_", " ")
            event.update(title=f"Gravity: {action}", minor=True)
        elif name in ("ToolSearch", "Skill", "TaskStop", "TaskOutput"):
            event.update(title=f"{name}", minor=True)
        else:
            label = name.split("__")[-1].replace("_", " ") if name.startswith("mcp__") else name
            event.update(title=label)
        if event["kind"] == "tool" and not detail.get("command"):
            detail["input"] = truncate(json.dumps(args, indent=2, ensure_ascii=False), 4000)
        event.setdefault("subtitle", "")
        if name not in ("Edit", "MultiEdit", "Write"):
            self.attach_paths(event, json.dumps(args, ensure_ascii=False) if not isinstance(args.get("command"), str)
                              else args["command"])
        turn.add(event, detail)
        self.pending_tools[event_id] = event

    def tool_result(self, block: Dict[str, Any], result: Dict[str, Any]) -> None:
        event = self.pending_tools.pop(block.get("tool_use_id", ""), None)
        if event is None:
            return
        turn = self.current
        detail: Dict[str, Any] = {}
        for candidate in reversed(self.turns[-3:]):
            if event["id"] in candidate.details:
                turn = candidate
                detail = candidate.details[event["id"]]
                break
        if turn is None:
            return
        event["error"] = bool(block.get("is_error"))
        self.attach_inline(event, block.get("content"))
        stdout = result.get("stdout")
        if isinstance(stdout, str):
            output = stdout
            if result.get("stderr"):
                output += ("\n" if output else "") + str(result["stderr"])
            detail["output"] = tail(output, OUTPUT_LIMIT)
        else:
            detail["output"] = tail(block_text(block.get("content")), OUTPUT_LIMIT)
        if event.get("tool") in ("Bash", "Glob", "Task", "Agent") or event["kind"] != "tool":
            self.attach_paths(event, detail["output"])
        patch = result.get("structuredPatch")
        if isinstance(patch, list):
            lines: List[str] = []
            added = removed = 0
            for hunk in patch:
                if not isinstance(hunk, dict):
                    continue
                lines.append(f"@@ -{hunk.get('oldStart')},{hunk.get('oldLines')} +{hunk.get('newStart')},{hunk.get('newLines')} @@")
                for line in hunk.get("lines") or []:
                    if line.startswith("+"):
                        added += 1
                    elif line.startswith("-"):
                        removed += 1
                    lines.append(line)
            if result.get("type") == "create" and not patch:
                added = str(result.get("content", "")).count("\n") + 1
            event["added"] = added
            event["removed"] = removed
            if len(lines) > DIFF_LINE_LIMIT:
                lines = lines[:DIFF_LINE_LIMIT] + [f"… {len(lines) - DIFF_LINE_LIMIT} more lines"]
            detail["diff"] = lines
            if lines:
                detail.pop("content", None)
        turn.details[event["id"]] = detail


# ---------------------------------------------------------------- the model

class Lens:
    def __init__(self, gravity_home: str, workspace_home: str, claude_projects: str):
        self.gravity_home = gravity_home
        self.workspace_home = workspace_home
        self.claude_projects = claude_projects
        self.lock = threading.Lock()
        self.transcripts: Dict[str, Transcript] = {}
        self.rev = 0

    def bots(self) -> Dict[str, Dict[str, str]]:
        """bot id -> identity, read from the daemon's own bot.json files."""
        found: Dict[str, Dict[str, str]] = {}
        root = os.path.join(self.gravity_home, "projects")
        for project in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            bots_dir = os.path.join(root, project, "bots")
            if not os.path.isdir(bots_dir):
                continue
            for bot in sorted(os.listdir(bots_dir)):
                try:
                    with open(os.path.join(bots_dir, bot, "bot.json")) as handle:
                        meta = json.load(handle)
                except (OSError, ValueError):
                    continue
                workspace = os.path.join(self.workspace_home, "projects", project, "bots", bot, "workspace")
                found[meta.get("id", "")] = {
                    "id": meta.get("id", ""), "name": meta.get("name", bot), "project": project,
                    "folder": os.path.join(self.claude_projects, mangle(workspace)),
                }
        return found

    def transcript(self, bot: Dict[str, str]) -> Transcript:
        transcript = self.transcripts.get(bot["id"])
        if transcript is None or transcript.folder != bot["folder"]:
            transcript = Transcript(bot["folder"])
            self.transcripts[bot["id"]] = transcript
        if transcript.refresh():
            self.rev += 1
        return transcript

    def refresh_all(self) -> Dict[str, Dict[str, str]]:
        bots = self.bots()
        for bot in bots.values():
            self.transcript(bot)
        return bots

    def named(self, value: Any, names: Dict[str, str]) -> Any:
        """Bus envelopes shout names ("IOS DEV"); give them back their real case."""
        if isinstance(value, list):
            return [self.named(item, names) for item in value]
        if not isinstance(value, dict):
            return value
        fixed = {}
        for key, item in value.items():
            if key in ("from", "to") and isinstance(item, str):
                fixed[key] = names.get(item.lower(), item)
            else:
                fixed[key] = self.named(item, names)
        return fixed

    @staticmethod
    def names_of(bots: Dict[str, Dict[str, str]]) -> Dict[str, str]:
        return {bot["name"].lower(): bot["name"] for bot in bots.values()}

    # Views -----------------------------------------------------------------

    def overview(self) -> Dict[str, Any]:
        with self.lock:
            bots = self.refresh_all()
            rows = []
            for bot in bots.values():
                turns = self.transcripts[bot["id"]].turns
                last = turns[-1].summary(True) if turns else None
                rows.append({"bot_id": bot["id"], "name": bot["name"], "project": bot["project"],
                             "last_turn": last})
            return {"rev": self.rev, "bots": self.named(rows, self.names_of(bots))}

    def feed(self, limit: int) -> Dict[str, Any]:
        with self.lock:
            bots = self.refresh_all()
            rows = []
            for bot in bots.values():
                turns = self.transcripts[bot["id"]].turns
                for index, turn in enumerate(turns[-limit:]):
                    summary = turn.summary(turn is turns[-1])
                    if not turn.events and summary["trigger"]["kind"] == "continued":
                        continue
                    summary.update(bot_id=bot["id"], bot_name=bot["name"], project=bot["project"])
                    rows.append(summary)
            rows.sort(key=lambda row: row["updated_at"] or "", reverse=True)
            return {"rev": self.rev, "turns": self.named(rows[:limit], self.names_of(bots))}

    def turns(self, bot_id: str, limit: int, before: Optional[str]) -> Optional[Dict[str, Any]]:
        with self.lock:
            bots = self.bots()
            bot = bots.get(bot_id)
            if bot is None:
                return None
            turns = self.transcript(bot).turns
            end = len(turns)
            if before:
                ids = [t.id for t in turns]
                end = ids.index(before) if before in ids else end
            start = max(0, end - limit)
            page = [t.summary(t is turns[-1]) for t in reversed(turns[start:end])]
            return {"rev": self.rev, "turns": self.named(page, self.names_of(bots)), "has_more": start > 0}

    def turn(self, bot_id: str, turn_id: str) -> Optional[Dict[str, Any]]:
        with self.lock:
            bots = self.bots()
            bot = bots.get(bot_id)
            if bot is None:
                return None
            turns = self.transcript(bot).turns
            for turn in turns:
                if turn.id == turn_id:
                    events = []
                    for event in turn.events:
                        row = dict(event)
                        row["has_detail"] = bool(turn.details.get(event["id"]))
                        if row.get("images"):
                            row["images"] = [dict(ref, exists=ref["kind"] == "inline"
                                                  or os.path.isfile(os.path.expanduser(ref["path"])))
                                             for ref in row["images"]]
                        events.append(row)
                    return self.named({"rev": self.rev, "turn": turn.summary(turn is turns[-1]), "events": events},
                                      self.names_of(bots))
            return None

    def event(self, bot_id: str, event_id: str) -> Optional[Dict[str, Any]]:
        with self.lock:
            bot = self.bots().get(bot_id)
            if bot is None:
                return None
            for turn in reversed(self.transcript(bot).turns):
                if event_id in turn.details:
                    event = next((e for e in turn.events if e["id"] == event_id), {})
                    return {"event": event, **turn.details[event_id]}
            return None

    def image(self, bot_id: str, image_id: str, thumb: bool) -> Optional[Any]:
        """(bytes, media type) for an image this bot's log refers to, and nothing else."""
        with self.lock:
            bot = self.bots().get(bot_id)
            if bot is None:
                return None
            entry = self.transcript(bot).images.get(image_id)
        if entry is None:
            return None
        if entry[0] == "inline":
            try:
                return base64.b64decode(entry[2]), entry[1]
            except ValueError:
                return None
        return serve_file_image(entry[1], thumb)

    # Artifacts ---------------------------------------------------------------

    def artifact_dirs(self) -> Dict[str, str]:
        root = os.path.join(self.workspace_home, "projects")
        dirs = {}
        for project in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            path = os.path.join(root, project, "artifacts")
            if os.path.isdir(path):
                dirs[project] = path
        return dirs

    def artifacts(self) -> Dict[str, Any]:
        rows = []
        for project, folder in self.artifact_dirs().items():
            for name in os.listdir(folder):
                path = os.path.join(folder, name)
                if not name.lower().endswith(ARTIFACT_SUFFIXES) or not os.path.isfile(path):
                    continue
                st = os.stat(path)
                rows.append({"project": project, "name": name, "title": self.title_of(path, name),
                             "size": st.st_size, "modified_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime))})
        rows.sort(key=lambda row: row["modified_at"], reverse=True)
        return {"artifacts": rows}

    @staticmethod
    def title_of(path: str, name: str) -> str:
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                for _ in range(20):
                    line = handle.readline()
                    if not line:
                        break
                    if line.startswith("#"):
                        return line.lstrip("#").strip()[:160]
        except OSError:
            pass
        return re.sub(r"^[0-9a-f]{8}(-[0-9a-f]{4}){0,4}(-[0-9a-f]{12})?-", "", os.path.splitext(name)[0]).replace("-", " ")

    def artifact_image(self, project: str, name: str, src: str, thumb: bool) -> Optional[Any]:
        """An image a report embeds, resolved against the artifacts folder."""
        text = self.artifact(project, name)
        if text is None or src not in text:
            return None
        folder = self.artifact_dirs()[project]
        path = os.path.normpath(os.path.join(folder, os.path.expanduser(src)))
        return serve_file_image(path, thumb)

    def artifact(self, project: str, name: str) -> Optional[str]:
        folder = self.artifact_dirs().get(project)
        # Only names the folder actually lists: no paths, no traversal.
        if folder is None or "/" in name or name not in os.listdir(folder):
            return None
        path = os.path.join(folder, name)
        if not os.path.isfile(path) or not name.lower().endswith(ARTIFACT_SUFFIXES):
            return None
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read(ARTIFACT_LIMIT)


def serve_file_image(path: str, thumb: bool) -> Optional[Any]:
    kind = IMAGE_TYPES.get(os.path.splitext(path)[1].lower())
    if kind is None or not os.path.isfile(path) or os.path.getsize(path) > IMAGE_LIMIT:
        return None
    if thumb:
        small = thumbnail(path)
        if small is not None:
            with open(small, "rb") as handle:
                return handle.read(), "image/jpeg"
    with open(path, "rb") as handle:
        return handle.read(), kind


def thumbnail(path: str) -> Optional[str]:
    """A 640 px JPEG made once with macOS's own sips, cached by path and mtime."""
    st = os.stat(path)
    key = hashlib.sha1(f"{path}:{st.st_mtime_ns}:{st.st_size}".encode()).hexdigest()
    target = os.path.join(THUMB_DIR, key + ".jpg")
    if os.path.isfile(target):
        return target
    try:
        os.makedirs(THUMB_DIR, exist_ok=True)
        subprocess.run(["/usr/bin/sips", "-Z", "640", "-s", "format", "jpeg", "-s", "formatOptions", "70",
                        path, "--out", target], capture_output=True, timeout=20, check=True)
        return target if os.path.isfile(target) else None
    except (OSError, subprocess.SubprocessError):
        return None


# ---------------------------------------------------------------- auth

class DaemonAuth:
    """Accepts a token only if gravityd accepts it with the `read` grant."""

    def __init__(self, gravity_home: str, port: Optional[int]):
        self.gravity_home = gravity_home
        self.port = port
        self.cache: Dict[str, float] = {}
        self.lock = threading.Lock()

    def daemon_port(self) -> int:
        if self.port:
            return self.port
        try:
            with open(os.path.join(self.gravity_home, "gravityd.port")) as handle:
                return int(handle.read().strip())
        except (OSError, ValueError):
            return 49777

    def allowed(self, token: str) -> bool:
        if not token or len(token) > 512:
            return False
        key = hashlib.sha256(token.encode()).hexdigest()
        now = time.time()
        with self.lock:
            if self.cache.get(key, 0) > now:
                return True
        ok = self.handshake(token)
        if ok:
            with self.lock:
                self.cache[key] = now + 60
        return ok

    def handshake(self, token: str) -> bool:
        try:
            with socket.create_connection(("127.0.0.1", self.daemon_port()), timeout=5) as sock:
                key = base64.b64encode(os.urandom(16)).decode()
                sock.sendall((f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n"
                              f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                              f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
                reader = sock.makefile("rb")
                if b" 101 " not in reader.readline():
                    return False
                while reader.readline() not in (b"\r\n", b""):
                    pass
                hello = json.dumps({"type": "hello", "req_id": "1", "protocol_version": 2,
                                    "token": token, "client": f"gravity-lens/{VERSION}"}).encode()
                sock.sendall(self.frame(hello))
                reply = json.loads(self.read_frame(reader))
                sock.sendall(b"\x88\x80" + os.urandom(4))  # close
                return reply.get("type") == "hello_ok" and "read" in (reply.get("grants") or [])
        except (OSError, ValueError):
            return False

    @staticmethod
    def frame(payload: bytes) -> bytes:
        mask = os.urandom(4)
        header = bytearray([0x81])
        if len(payload) < 126:
            header.append(0x80 | len(payload))
        elif len(payload) < 65536:
            header.append(0x80 | 126)
            header += len(payload).to_bytes(2, "big")
        else:
            header.append(0x80 | 127)
            header += len(payload).to_bytes(8, "big")
        return bytes(header) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

    @staticmethod
    def read_frame(reader: Any) -> bytes:
        first = reader.read(2)
        if len(first) < 2:
            raise ValueError("closed")
        length = first[1] & 0x7F
        if length == 126:
            length = int.from_bytes(reader.read(2), "big")
        elif length == 127:
            length = int.from_bytes(reader.read(8), "big")
        if length > 1_000_000:
            raise ValueError("frame too large")
        return reader.read(length)


# ---------------------------------------------------------------- http

class Handler(BaseHTTPRequestHandler):
    lens: Lens
    auth: DaemonAuth
    server_version = f"GravityLens/{VERSION}"

    def log_message(self, fmt: str, *args: Any) -> None:  # quiet: paths carry no secrets, but keep logs small
        if os.environ.get("GRAVITY_LENS_VERBOSE"):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def send_json(self, status: int, body: Any) -> None:
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def send_bytes(self, data: bytes, kind: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "private, max-age=3600")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802 (http.server naming)
        url = urlparse(self.path)
        parts = [unquote(p) for p in url.path.strip("/").split("/") if p]
        query = {k: v[-1] for k, v in parse_qs(url.query).items()}
        if parts == ["health"]:
            self.send_json(200, {"status": "ok", "version": VERSION})
            return
        header = self.headers.get("Authorization", "")
        token = header[7:].strip() if header.lower().startswith("bearer ") else ""
        if not self.auth.allowed(token):
            self.send_json(401, {"error": "unauthorized"})
            return
        try:
            self.route(parts, query)
        except Exception as error:  # a bad transcript line must not take the service down
            self.send_json(500, {"error": type(error).__name__})

    def route(self, parts: List[str], query: Dict[str, str]) -> None:
        limit = max(1, min(int(query.get("limit", "30") or 30), 200))
        body: Any = None
        if parts == ["v1", "overview"]:
            body = self.lens.overview()
        elif parts == ["v1", "feed"]:
            body = self.lens.feed(limit)
        elif len(parts) == 4 and parts[:2] == ["v1", "bots"] and parts[3] == "turns":
            body = self.lens.turns(parts[2], limit, query.get("before"))
        elif len(parts) == 5 and parts[:2] == ["v1", "bots"] and parts[3] == "turns":
            body = self.lens.turn(parts[2], parts[4])
        elif len(parts) == 5 and parts[:2] == ["v1", "bots"] and parts[3] == "events":
            body = self.lens.event(parts[2], parts[4])
        elif len(parts) == 5 and parts[:2] == ["v1", "bots"] and parts[3] == "images":
            image = self.lens.image(parts[2], parts[4], query.get("size") == "thumb")
            if image is not None:
                self.send_bytes(*image)
                return
        elif len(parts) == 5 and parts[:2] == ["v1", "artifacts"] and parts[4] == "image":
            image = self.lens.artifact_image(parts[2], parts[3], query.get("src", ""), query.get("size") == "thumb")
            if image is not None:
                self.send_bytes(*image)
                return
        elif parts == ["v1", "artifacts"]:
            body = self.lens.artifacts()
        elif len(parts) == 4 and parts[:2] == ["v1", "artifacts"] and parts[3] != "image":
            text = self.lens.artifact(parts[2], parts[3])
            body = None if text is None else {"project": parts[2], "name": parts[3], "text": text}
        if body is None:
            self.send_json(404, {"error": "not_found"})
        else:
            self.send_json(200, body)


def daemon_binds(gravity_home: str) -> List[str]:
    """The addresses gravityd serves on, from gravityd.toml, so both stay in step."""
    try:
        with open(os.path.join(gravity_home, "gravityd.toml")) as handle:
            text = handle.read()
    except OSError:
        return ["127.0.0.1"]
    match = re.search(r"^\s*bind\s*=\s*\[([^\]]*)\]", text, re.M)
    if not match:
        return ["127.0.0.1"]
    binds = re.findall(r'"([^"]+)"', match.group(1))
    return [b for b in binds if b not in ("0.0.0.0", "::")] or ["127.0.0.1"]


def main() -> None:
    home = os.path.expanduser("~")
    parser = argparse.ArgumentParser(description="Read-only view of Gravity bots' work for GravitiOS.")
    parser.add_argument("--port", type=int, default=49778)
    parser.add_argument("--bind", action="append", help="address to listen on (default: gravityd's bind list)")
    parser.add_argument("--gravity-home", default=os.path.join(home, ".gravity"),
                        help="where bot.json files and gravityd.toml live")
    parser.add_argument("--workspace-home", help="gravity home the bot workspaces and artifacts are under (default: --gravity-home)")
    parser.add_argument("--claude-projects", default=os.path.join(home, ".claude", "projects"))
    parser.add_argument("--daemon-port", type=int, help="gravityd port used to check tokens (default: gravityd.port)")
    args = parser.parse_args()

    Handler.lens = Lens(args.gravity_home, args.workspace_home or args.gravity_home, args.claude_projects)
    Handler.auth = DaemonAuth(args.gravity_home, args.daemon_port)
    binds = args.bind or daemon_binds(args.gravity_home)
    servers = []
    for address in binds:
        server = ThreadingHTTPServer((address, args.port), Handler)
        server.daemon_threads = True
        servers.append(server)
        sys.stderr.write(f"gravity-lens {VERSION} listening on {address}:{args.port}\n")
    # Parse every transcript once up front so the first phone request is quick.
    threading.Thread(target=lambda: Handler.lens.overview(), daemon=True).start()
    for server in servers[1:]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    servers[0].serve_forever()


if __name__ == "__main__":
    main()
