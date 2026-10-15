#!/bin/bash
#------------------------------------------------------------------------------
# @description Check an R7 review line against the reviewer's own session
# @description journal, read-only (refactor round 11 row 06; plan section 1:
# @description `review: <id>@<box> <vendor> PASS <sha> ran: <commands> | read:
# @description <output> | log: <id>@<box>:<path>`). The dispatcher read journals
# @description by hand 4 times in round 10; this is that read, named.
# @description Every test the `ran:` part names (`*.tst.sh`, `*.test.mjs`,
# @description `*_test.go` by basename, `go test <pkg>`, `pnpm run <script>`)
# @description needs a `"command"` value in the `log:` file that names it: a
# @description claude `.jsonl`, a vibe journal file or session dir or a grok
# @description `chat_history.jsonl` or an agy `transcript.jsonl` /
# @description `transcript_full.jsonl` (`args.CommandLine` of a `run_command`
# @description tool call, JSON-quoted in `transcript.jsonl`); a dir is read whole (every `*.json` and
# @description `*.jsonl` under it), the command found as a JSON key or inside a
# @description JSON-encoded arguments string. vibe compacts a session into
# @description `chunks/*.json` and deletes the journal file a line named: such a
# @description gone `<session>/journal/<n>.jsonl` is read as its session dir. Tool OUTPUT never counts:
# @description a `git diff --stat` that lists a test file is not its run.
# @description Never fetches a log from another box: run it on the reviewer's,
# @description as a user who can read the reviewer's home.
# @description Prints `MISSING <name>` per test not run (exit 3), else
# @description `OK <n> of <n>`. Exit 2: the log is on another box (named).
# @description Exit 1: no line, no `log:`, or the log cannot be read.
# @param REVIEW_LINE (required) - the review line, as in the landing commit
# @param REVIEW_LINE_BOX (optional) - this box; default SPOOL_BOX_TAG, else box.env, else hostname -s
# @example REVIEW_LINE='review: m-159@box-a mistral PASS <sha> ran: bash spl-review-line-check.tst.sh | read: 3 PASS | log: m-159@box-a:/path/journal' ./run -a do_spl_review_line_check
#------------------------------------------------------------------------------
do_spl_review_line_check() {
  local line="${REVIEW_LINE:-}" ran box path me names
  [[ -n "$line" ]] || { echo "FATAL REVIEW_LINE must be set (the 'review: ...' line)"; return 1; }
  line="${line#"${line%%review: *}"}"
  [[ "$line" == "review: "* ]] || { echo "FATAL REVIEW_LINE holds no 'review: ' line"; return 1; }
  [[ "$line" =~ \|\ log:\ ([^[:space:]@]+)@([^[:space:]:]+):([^[:space:]]+) ]] ||
    { echo "FATAL the line has no '| log: <id>@<box>:<path>'"; return 1; }
  box="${BASH_REMATCH[2]}" path="${BASH_REMATCH[3]}"
  me="$(_spl_review_line_box)"
  [[ "$box" == "$me" ]] ||
    { echo "REFUSED the log is on box '$box', this is '$me': run it on $box (never fetched)"; return 2; }
  ran="${line#* ran: }"
  [[ "$ran" != "$line" ]] || { echo "FATAL the line has no ' ran: '"; return 1; }
  ran="${ran%% | read: *}" ran="${ran%% | log: *}"
  names="$(_spl_review_line_names "$ran")"
  [[ -n "$names" ]] || { echo "MISSING ran: names no test (*.tst.sh, *.test.mjs, *_test.go, go test, pnpm run): '$ran'"; return 3; }
  path="$(_spl_review_line_vibe_session "$path")"
  [[ -r "$path" ]] || { echo "FATAL log $path is not readable on $me as $(id -un)"; return 1; }
  _spl_review_line_match "$path" <<<"$names"
}

# _spl_review_line_box - this box's tag.
_spl_review_line_box() {
  local v="${REVIEW_LINE_BOX:-${SPOOL_BOX_TAG:-}}" f="${SPOOL_BOX_ENV-/var/spool-hub/box.env}"
  [[ -z "$v" && -n "$f" && -r "$f" ]] && v="$(sed -n 's/^SPOOL_BOX_TAG=["'\'']\{0,1\}\([A-Za-z0-9._-]*\).*/\1/p' "$f" | tail -n1)"
  printf '%s' "${v:-$(hostname -s)}"
}

# _spl_review_line_vibe_session <path> - the path, or for a vibe journal file
# the store compacted away (`<session>/journal/<n>.jsonl` gone, the session
# dir holding CURRENT or chunks/) that session dir, with a NOTE on stderr.
_spl_review_line_vibe_session() {
  local d="${1%/*}"
  if [[ ! -e "$1" && "${d##*/}" == journal && ( -e "${d%/*}/CURRENT" || -d "${d%/*}/chunks" ) ]]; then
    echo "NOTE $1 is gone (vibe compacted the session): reading the session dir ${d%/*}" >&2
    printf '%s' "${d%/*}"
  else
    printf '%s' "$1"
  fi
}

# _spl_review_line_names <ran> - one `<kind> <name>` per test the ran: part
# names, deduplicated: `file <basename>`, `go <pkg>`, `pnpm <script>`.
_spl_review_line_names() {
  {
    grep -oE '[A-Za-z0-9._/-]+(\.tst\.sh|\.test\.mjs|_test\.go)' <<<"$1" | sed 's#.*/##; s/^/file /'
    grep -oE 'go test( +-[^ ]+)* +[^ ;|&)'\''"]+' <<<"$1" | awk '{print "go " $NF}'
    grep -oE 'pnpm( +[^ ;|&]+)* +run +[A-Za-z0-9:_.-]+' <<<"$1" | awk '{print "pnpm " $NF}'
  } | awk '!seen[$0]++'
}

# _spl_review_line_match <log path> < names - prints MISSING per name that no
# "command" in the log names, then the count; exit 0 all found, 3 any missing.
_spl_review_line_match() {
  python3 -I -c "$_SPL_REVIEW_LINE_PY" "$1"
}

# shellcheck disable=SC2016
_SPL_REVIEW_LINE_PY='
import json, os, re, sys
path = sys.argv[1]
names = [l.split(" ", 1) for l in sys.stdin.read().splitlines() if " " in l]
cmds = []
def agy(v):
    a = v.get("args") if v.get("name") == "run_command" else None
    c = a.get("CommandLine") if isinstance(a, dict) else None
    if isinstance(c, str) and c[:1] == "\"":
        try:
            c = json.loads(c)
        except ValueError:
            pass
    if isinstance(c, str):
        cmds.append(c)
def walk(v):
    if isinstance(v, dict):
        agy(v)
        for k, x in v.items():
            if k == "command" and isinstance(x, str):
                cmds.append(x)
            walk(x)
    elif isinstance(v, list):
        for x in v:
            walk(x)
    elif isinstance(v, str) and v[:1] in "{[" and "command" in v:
        try:
            walk(json.loads(v))
        except ValueError:
            pass
try:
    files = sorted(os.path.join(r, f) for r, _, fs in os.walk(path) for f in fs if f.endswith((".json", ".jsonl"))) if os.path.isdir(path) else [path]
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        try:
            walk(json.loads(text))
        except ValueError:
            for raw in text.splitlines():
                try:
                    walk(json.loads(raw))
                except ValueError:
                    pass
except OSError as e:
    print("FATAL cannot read the log: %s" % e)
    sys.exit(1)
def found(kind, name):
    n = re.escape(name)
    if kind == "file":
        rx = r"(?<![\w.-])" + n + r"(?![\w.-])"
    elif kind == "go":
        rx = r"\bgo\s+test\b.*(?<!\S)" + n + r"(?!\S)"
    else:
        rx = r"\bpnpm\b.*\brun\s+" + n + r"(?![\w:.-])"
    return any(re.search(rx, c, re.S) for c in cmds)
label = {"go": "go test ", "pnpm": "pnpm run "}
miss = [label.get(k, "") + n for k, n in names if not found(k, n)]
for m in miss:
    print("MISSING %s" % m)
n = len(names)
print("%s %d of %d named in ran: are commands in %s (%d commands read)" % ("FAIL" if miss else "OK", n - len(miss), n, path, len(cmds)))
sys.exit(3 if miss else 0)
'
