#!/usr/bin/env bash
# heredoc-collision-guard.inc.sh — the ONE decision "does this shell command
# nest a heredoc inside another one with the SAME delimiter?", shared by the
# harness pre-tool hooks (claude / grok / agy / qwen: force-push-guard-hook.sh,
# mistral vibe: vibe-push-guard.py). SPL-2474.
#
#   heredoc_collision_check "<command>"
#       rc 0  allow (prints nothing)
#       rc 2  refuse; one line "heredoc-collision: refused: <reason>" on stderr
#   bash heredoc-collision-guard.inc.sh --check "<command>"   the same, run directly
#
# Why: on 2026-10-17 an agent ran `sudo -u <box-user> bash -c 'cat > X' << 'EOF'`
# whose body held an inner `cat >"$BIN/stub" <<'EOF'`. bash ends a heredoc at
# its FIRST bare delimiter line, so the inner stub's EOF closed the OUTER
# heredoc and every line after it ran in the agent's own shell, without the
# body's `set -u` and with BIN / PROC unset: `rm -rf "$PROC"/*` ran as
# `rm -rf /*`.
#
# Refused: a heredoc <<WORD (any quoting, <<- too) whose body holds another
# <<WORD with the same WORD, AND a bare WORD line follows the first one that
# closed it - the author's intended end, so the lines between run as shell.
# A body that only mentions <<WORD with no later WORD line is data and passes.
# Heredoc bodies are data: a nested heredoc inside a uniquely-delimited
# outer one is not read. Here-strings (<<<) and arithmetic shifts are not
# heredocs. Fails CLOSED: no python3 is a refusal.

heredoc_collision_check() {
  case "${1-}" in *"<<"*) ;; *) return 0 ;; esac
  if ! command -v python3 >/dev/null 2>&1; then
    echo "heredoc-collision: refused: python3 is missing, the guard cannot read the command (fail closed)" >&2
    return 2
  fi
  python3 -c "$_HEREDOC_COLLISION_PY" "${1-}"
}

# shellcheck disable=SC2016  # python source, never expanded by bash
_HEREDOC_COLLISION_PY='
import re, sys

# <<WORD, <<-WORD, << "WORD", <<'"'"'WORD'"'"', <<\WORD; not <<< and not $((1<<2))
OP = re.compile(r"(?<![<\w])<<(?!<)(-?)[ \t]*(?:\x27([^\x27\n]+)\x27|\"([^\"\n]+)\"|\\?([A-Za-z_][\w.-]*))")


def ops(line):
    if line.lstrip().startswith("#"):
        return []
    return [(m.group(1) == "-", m.group(2) or m.group(3) or m.group(4)) for m in OP.finditer(line)]


def ends(line, word, dash):
    return (line.lstrip("\t") if dash else line) == word


def check(cmd):
    lines = cmd.split("\n")
    i = 0
    while i < len(lines):
        start = i
        pending = ops(lines[i])
        i += 1
        for dash, word in pending:
            j = i
            while j < len(lines) and not ends(lines[j], word, dash):
                j += 1
            if j >= len(lines):
                i = j
                break
            inner = [k for k in range(i, j) if any(w == word for _, w in ops(lines[k]))]
            later = [k for k in range(j + 1, len(lines)) if ends(lines[k], word, True)]
            if inner and later:
                return (
                    "the heredoc <<%s on line %d holds an inner <<%s on line %d: the %s on line %d "
                    "closes the OUTER heredoc and lines %d..%d run as shell (the 2026-10-17 rm -rf /* "
                    "came from this); give each heredoc its own delimiter, e.g. EOF_OUTER and EOF_INNER"
                    % (word, start + 1, word, inner[0] + 1, word, j + 1, j + 2, later[-1] + 1)
                )
            i = j + 1
    return None


def main():
    try:
        why = check(sys.argv[1])
    except Exception as e:  # fail closed
        why = "the guard failed (%s), fail closed" % type(e).__name__
    if why:
        print("heredoc-collision: refused: " + why, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
'

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1-}" = --check ] && [ $# -eq 2 ]; then
    heredoc_collision_check "$2"
    exit $?
  fi
  echo "usage: bash heredoc-collision-guard.inc.sh --check \"<command>\"  (rc 0 allow, 2 refuse)" >&2
  exit 64
fi
