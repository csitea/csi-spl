#!/usr/bin/env python3
"""spool-session-export.py AGENT_ID TOKEN|TRANSCRIPT_PATH [OUT_DIR]

Render ONE agent's CLI transcript as markdown, redacted, for the session
backfill of the terminal mirror (specs/036-spool-terminal-mirror). The file is
what do_spl_desk_session_upload attaches to the agent's DM with the human.

The transcript is the ONE file that contains TOKEN - a string only this
agent's own session holds (its brief path, its own inbox message path) -
among the Claude *.jsonl under $SPOOL_AGENT_HOME/.claude/projects and the
grok session files under $SPOOL_AGENT_HOME/.grok. A path that exists is taken
as the transcript itself. SPOOL_AGENT_HOME defaults to $HOME.

Writes <OUT_DIR>/session-<AGENT_ID>-<utc>.md (mode 0644), prints its path on
stdout (OUT_DIR "-": the markdown itself goes to stdout) and the redaction counts on stderr. Exit 2 when zero or several
transcripts match, 64 on usage.
"""

import datetime
import glob
import json
import os
import sys

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "lib")
)
from spool_redact import redact  # noqa: E402


def find(token, home):
    if os.path.isfile(token):
        return [token]
    cands = glob.glob(f"{home}/.claude/projects/*/*.jsonl") + [
        p for p in glob.glob(f"{home}/.grok/**/*", recursive=True) if os.path.isfile(p)
    ]
    hits = []
    for p in cands:
        try:
            with open(p, "r", errors="replace") as f:
                if token in f.read():
                    hits.append(p)
        except OSError:
            pass
    return hits


def clip(s, n=4000):
    s = s if isinstance(s, str) else json.dumps(s, ensure_ascii=False)
    return s if len(s) <= n else s[:n] + f"\n… [{len(s) - n} more chars clipped]"


def render(agent, src, now):
    lines = [
        f"# Session transcript — {agent}",
        "",
        f"- source: `{os.path.basename(src)}`",
        f"- exported: {now.strftime('%Y-%m-%dT%H:%M:%SZ')}",
        "",
    ]
    if not (src.endswith(".jsonl") and "/.claude/" in src):
        with open(src, errors="replace") as f:
            return lines + ["```", f.read(), "```"]
    with open(src, errors="replace") as f:
        for raw in f:
            try:
                e = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(e, dict) or e.get("type") not in ("user", "assistant"):
                continue
            msg = e.get("message") or {}
            role = msg.get("role", e.get("type"))
            content = msg.get("content")
            ts = e.get("timestamp", "")
            parts = (
                content
                if isinstance(content, list)
                else [{"type": "text", "text": content or ""}]
            )
            for c in parts:
                if not isinstance(c, dict):
                    continue
                t = c.get("type")
                if t == "text" and str(c.get("text", "")).strip():
                    lines += [f"## {role} · {ts}", "", clip(c["text"], 20000), ""]
                elif t == "tool_use":
                    lines += [
                        f"### tool call `{c.get('name')}` · {ts}",
                        "",
                        "```",
                        clip(c.get("input")),
                        "```",
                        "",
                    ]
                elif t == "tool_result":
                    body = c.get("content")
                    if isinstance(body, list):
                        body = "\n".join(
                            x.get("text", "") for x in body if isinstance(x, dict)
                        )
                    lines += ["### tool result", "", "```", clip(body or ""), "```", ""]
    return lines


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 64
    agent, token = argv[1], argv[2]
    out_dir = argv[3] if len(argv) > 3 else "."
    home = os.environ.get("SPOOL_AGENT_HOME") or os.path.expanduser("~")
    hits = find(token, home)
    if len(hits) != 1:
        print(
            f"FATAL {len(hits)} transcripts contain the token: {hits}", file=sys.stderr
        )
        return 2
    now = datetime.datetime.now(datetime.timezone.utc)
    text, counts = redact("\n".join(render(agent, hits[0], now)))
    if out_dir == "-":
        sys.stdout.write(text)
        print(
            json.dumps({"source": hits[0], "redactions": counts}, sort_keys=True),
            file=sys.stderr,
        )
        return 0
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"session-{agent}-{now.strftime('%Y%m%dT%H%M%SZ')}.md")
    with open(out, "w") as f:
        f.write(text)
    os.chmod(out, 0o644)
    print(out)
    print(
        json.dumps({"source": hits[0], "redactions": counts}, sort_keys=True),
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
