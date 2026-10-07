#!/usr/bin/env python3
"""Prepend N earlier turns to a demo bot's Claude Code transcript (demo world only).

  long_chat.py <demo out> <marker text in the transcript> <turns>

Each turn: the owner types, the bot answers in a few paragraphs, the turn ends.
Timestamps run back from the transcript's first record, a turn every 6 minutes.
"""
import glob
import json
import sys
import uuid
from datetime import datetime, timedelta

out, marker, turns = sys.argv[1], sys.argv[2], int(sys.argv[3])
path = next(p for p in glob.glob(f"{out}/user-home/.claude/projects/*/*.jsonl") if marker in open(p).read())
records = [json.loads(line) for line in open(path)]
first = datetime.strptime(records[0]["timestamp"][:19], "%Y-%m-%dT%H:%M:%S")

def stamp(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + "000Z"

body = ("Checked the sync path again: NoteStore applies remote changes in order, SyncClient retries 409s "
        "with backoff, and the banner state lives in ConflictBannerModel. ") * 3
older = []
for i in range(turns, 0, -1):
    t = first - timedelta(minutes=6 * i)
    older.append({"type": "user", "message": {"role": "user", "content": f"Long chat turn {turns - i + 1}: status?"},
                  "uuid": str(uuid.uuid4()), "timestamp": stamp(t)})
    older.append({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "text", "text": f"Turn {turns - i + 1}. {body}\n\n- one\n- two\n- three"}]},
                  "uuid": str(uuid.uuid4()), "timestamp": stamp(t + timedelta(seconds=40))})
    older.append({"type": "system", "subtype": "turn_duration", "durationMs": 45000,
                  "uuid": str(uuid.uuid4()), "timestamp": stamp(t + timedelta(seconds=45))})
with open(path, "w") as handle:
    for record in older + records:
        handle.write(json.dumps(record) + "\n")
print(path, len(older) // 3, "turns added")
