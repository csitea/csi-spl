#!/usr/bin/env python3
"""Compile every quoted <<'PY' heredoc body found in the given shell/yaml files."""
import re, sys, textwrap
OPEN = re.compile(r"<<(-?)\s*(['\"])(PY|PYEOF|PYTHON|EOF_PY)\2")
bad = n = 0
for path in sys.argv[1:]:
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    i = 0
    while i < len(lines):
        m = OPEN.search(lines[i])
        if not m or "python" not in lines[i]:
            i += 1; continue
        tag, start, body = m.group(3), i + 1, []
        i += 1
        while i < len(lines) and lines[i].strip() != tag:
            body.append(lines[i]); i += 1
        n += 1
        src = textwrap.dedent("\n".join(body))
        try:
            compile(src, f"{path}:{start + 1}", "exec")
        except SyntaxError as e:
            bad += 1
            print(f"{path}:{start + (e.lineno or 1)}: {e.msg}")
        i += 1
print(f"heredocs={n} syntax-errors={bad}", file=sys.stderr)
sys.exit(1 if bad else 0)
