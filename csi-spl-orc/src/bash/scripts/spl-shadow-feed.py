#!/usr/bin/env python3
"""spl-shadow-feed.py - one pass of the shadow feed: a READ-ONLY mirror of
the orchestrator and dispatcher spool traffic for a shadow seat that posts
nothing (owner, t1 ee1e58d5, 2026-10-11: "READ-ONLY access to a mirror of
c-001/c-002/c-003's spool traffic ... Keep one safety: drop file
attachments from the mirror").

Usage: spl-shadow-feed.py <spool root> <feed dir> <agent id>...

For each agent, every message file (*.json, *.md) under
<spool root>/<agent>/{inbox,outbox,archive} becomes
<feed dir>/<agent>/<sub>/<same name>, mode 0444, mtime of the source:
- a JSON message keeps every field except its attachments: `files` becomes
  [] and `files_dropped` says how many refs were cut. Only the message file
  is read, never the file a ref points to.
- a legacy .md message is copied as is (it carries no attachment refs).
- anything else (handoff notes, heartbeats, sub dirs) is never copied.
A file whose mirror copy has the source's mtime is skipped; a mirror copy
whose source is gone (an inbox message acked to archive/) is removed, so
the mirror reads like the spool. Never writes under <spool root>.
Prints one line: agents, copied, kept, removed, dropped refs, skipped.
"""

import json
import os
import sys

SUBS = ("inbox", "outbox", "archive")


def drop_files(raw):
    """-> (bytes to write, refs dropped). Raises on a file that is not a
    JSON object: the caller skips it rather than mirror an unknown shape."""
    msg = json.loads(raw)
    if not isinstance(msg, dict):
        raise ValueError("not a message object")
    refs = msg.get("files") or []
    n = len(refs) if isinstance(refs, list) else 1
    if "files" in msg:
        msg["files"] = []
    if n:
        msg["files_dropped"] = n
    return (json.dumps(msg, ensure_ascii=False, sort_keys=True) + "\n").encode(), n


def mirror_one(src, dst, st):
    """Copy src to dst (atomic, 0444, source mtime) -> refs dropped."""
    with open(src, "rb") as f:
        raw = f.read()
    n = 0
    if src.endswith(".json"):
        raw, n = drop_files(raw)
    tmp = f"{os.path.dirname(dst)}/.{os.path.basename(dst)}.tmp.{os.getpid()}"
    with open(tmp, "wb") as f:
        f.write(raw)
    os.chmod(tmp, 0o444)
    os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
    os.replace(tmp, dst)
    return n


def mirror_dir(sdir, ddir, c):
    os.makedirs(ddir, mode=0o755, exist_ok=True)
    for d in (os.path.dirname(os.path.dirname(ddir)), os.path.dirname(ddir), ddir):
        try:
            os.chmod(d, 0o755)  # readable by the seat, writable by this user only
        except OSError:
            pass
    want = set()
    names = os.listdir(sdir) if os.path.isdir(sdir) else []
    for name in names:
        if name.startswith(".") or not name.endswith((".json", ".md")):
            continue
        src = os.path.join(sdir, name)
        try:
            st = os.stat(src)
        except OSError:
            continue  # acked between the listdir and the stat
        if not os.path.isfile(src):
            continue
        dst = os.path.join(ddir, name)
        try:
            if os.stat(dst).st_mtime_ns == st.st_mtime_ns:
                want.add(name)
                c["kept"] += 1
                continue
        except OSError:
            pass
        try:
            c["dropped"] += mirror_one(src, dst, st)
            c["copied"] += 1
            want.add(name)
        except (OSError, ValueError) as e:
            c["skipped"] += 1
            print(f"WARN skipped {src}: {e}", file=sys.stderr)
    for name in os.listdir(ddir):
        if name not in want:
            os.remove(os.path.join(ddir, name))
            c["removed"] += 1


def main(argv):
    if len(argv) < 4:
        print(
            "usage: spl-shadow-feed.py <spool root> <feed dir> <agent id>...",
            file=sys.stderr,
        )
        return 2
    root, feed, agents = argv[1], argv[2], argv[3:]
    rr, fr = os.path.realpath(root), os.path.realpath(feed)
    if fr == rr or fr.startswith(rr + os.sep):
        print(f"FATAL the feed {feed} is inside the spool root {root}", file=sys.stderr)
        return 2
    c = dict(copied=0, kept=0, removed=0, dropped=0, skipped=0)
    for agent in agents:
        for sub in SUBS:
            mirror_dir(
                os.path.join(root, agent, sub), os.path.join(feed, agent, sub), c
            )
    print(
        "OK shadow feed agents=%d copied=%d kept=%d removed=%d files_dropped=%d skipped=%d"
        % (
            len(agents),
            c["copied"],
            c["kept"],
            c["removed"],
            c["dropped"],
            c["skipped"],
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
