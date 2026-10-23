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
# @description `*.jsonl` under it), but only ONE session: a dir holding 2 or more
# @description session dirs (children with `CURRENT` or `journal/`, the vibe
# @description store root) is refused, exit 1. The command is found as a JSON key or inside a
# @description JSON-encoded arguments string. vibe compacts a session into
# @description `chunks/*.json` and deletes the journal file a line named: such a
# @description gone `<session>/journal/<n>.jsonl` is read as its session dir. Tool OUTPUT never counts:
# @description a `git diff --stat` that lists a test file is not its run.
# @description Never fetches a log from another box: run it on the reviewer's,
# @description as a user who can read the reviewer's home, or as any user that
# @description may `sudo -n -u` the log's owner (the passwd user whose home the
# @description path is under, else the owner of its nearest existing parent):
# @description a log not readable as this user is read that way, with a
# @description `NOTE read as <owner> (sudo -n)` line.
# @description Prints `MISSING <name>` per test not run (exit 3), else
# @description `OK <n> of <n>`. Exit 2: the log is on another box (named),
# @description with the exact command to run there. REVIEW_LINE_SYNTAX=1 then
# @description checks here what needs no log: the section 1 format, a 40-hex
# @description sha, reviewer = log: owner, the vendor is the id's and any
# @description registry.tsv row of it, ran: names a test (`SYNTAX OK`, exit 0;
# @description `SYNTAX FAIL <why>`, exit 1); the run itself stays unchecked.
# @description The reviewer part (a `<[acgmq]-NNN>@<box>` id = the log: owner,
# @description the vendor of the id and of its registry row) is checked on
# @description both branches: on this box a failure is `SYNTAX FAIL`, exit 1.
# @description Exit 1: no line, no `log:`, or the log cannot be read, not even
# @description through `sudo -n -u <owner>` (the FATAL names the command to run
# @description as the owner).
# @param REVIEW_LINE (required) - the review line, as in the landing commit
# @param REVIEW_LINE_SYNTAX (optional) - 1: a log on another box gets the syntax check here
# @param REVIEW_LINE_BOX (optional) - this box; default SPOOL_BOX_TAG, else box.env, else hostname -s
# @example REVIEW_LINE='review: m-159@box-a mistral PASS <sha> ran: bash spl-review-line-check.tst.sh | read: 3 PASS | log: m-159@box-a:/path/journal' ./run -a do_spl_review_line_check
#------------------------------------------------------------------------------
do_spl_review_line_check() {
  local line="${REVIEW_LINE:-}" ran box path me names owner=
  [[ -n "$line" ]] || { echo "FATAL REVIEW_LINE must be set (the 'review: ...' line)"; return 1; }
  line="${line#"${line%%review: *}"}"
  [[ "$line" == "review: "* ]] || { echo "FATAL REVIEW_LINE holds no 'review: ' line"; return 1; }
  [[ "$line" =~ \|\ log:\ ([^[:space:]@]+)@([^[:space:]:]+):([^[:space:]]+) ]] ||
    { echo "FATAL the line has no '| log: <id>@<box>:<path>'"; return 1; }
  box="${BASH_REMATCH[2]}" path="${BASH_REMATCH[3]}"
  me="$(_spl_review_line_box)"
  [[ "$box" == "$me" ]] || { _spl_review_line_remote "$line" "$box" "$me"; return $?; }
  _spl_review_line_reviewer "${line%%$'\n'*}" || return 1
  ran="${line#* ran: }"
  [[ "$ran" != "$line" ]] || { echo "FATAL the line has no ' ran: '"; return 1; }
  ran="${ran%% | read: *}" ran="${ran%% | log: *}"
  names="$(_spl_review_line_names "$ran")"
  [[ -n "$names" ]] || { echo "MISSING ran: names no test (*.tst.sh, *.test.mjs, *_test.go, go test, pnpm run): '$ran'"; return 3; }
  path="$(_spl_review_line_vibe_session "$path")"
  if [[ ! -r "$path" ]]; then
    owner="$(_spl_review_line_owner "$path")"
    [[ -n "$owner" && "$owner" != "$(id -un)" ]] || { echo "FATAL log $path is not readable on $me as $(id -un)"; return 1; }
    path="$(_spl_review_line_vibe_session "$path" "$owner")"
    _spl_review_line_as "$owner" test -r "$path" 2>/dev/null || {
      line="${line%%$'\n'*}"
      echo "FATAL log $path is not readable on $me as $(id -un), nor through sudo -n -u $owner: run it as $owner: sudo -u $owner env REVIEW_LINE=${line@Q} ./run -a do_spl_review_line_check"
      return 1
    }
    echo "NOTE read as $owner (sudo -n)"
  fi
  _spl_review_line_match "$path" "$owner" <<<"$names"
}

# _spl_review_line_owner <path> - the user whose passwd home the path is under
# (the longest home that prefixes it), else the owner of its nearest existing
# parent; empty when neither is found.
_spl_review_line_owner() {
  local p="$1" u
  u="$(getent passwd 2>/dev/null | awk -F: -v p="$1" 'length($6) > 1 && index(p, $6 "/") == 1 && length($6) > n {n = length($6); u = $1} END {print u}')"
  while [[ -z "$u" && -n "$p" ]]; do
    [[ -e "$p" ]] && u="$(stat -c %U -- "$p" 2>/dev/null)"
    [[ "$p" == */* ]] && p="${p%/*}" || p=
  done
  printf '%s' "$u"
}

# _spl_review_line_as <owner> <cmd>... - the command as is for an empty owner,
# else through `sudo -n -u <owner>` (its argv, never a shell string).
_spl_review_line_as() {
  local u="$1"; shift
  if [[ -n "$u" ]]; then sudo -n -u "$u" "$@"; else "$@"; fi
}

# _spl_review_line_remote <line> <box> <me> - a log on another box: exit 2
# with the query to run there, or with REVIEW_LINE_SYNTAX=1 the line's syntax
# and reviewer checked here (rc 0 OK, rc 1 FAIL), the query still printed.
_spl_review_line_remote() {
  local first="${1%%$'\n'*}" q
  q="on $2: REVIEW_LINE=${first@Q} ./run -a do_spl_review_line_check"
  if [[ "${REVIEW_LINE_SYNTAX:-0}" != 1 ]]; then
    echo "REFUSED the log is on box '$2', this is '$3': run it on $2 (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here"
    echo "$q"
    return 2
  fi
  _spl_review_line_syntax "$first" || return 1
  echo "SYNTAX OK the line's format and reviewer check on $3; the run is not (the log is on $2): $q"
}

# _spl_review_line_syntax <line> - the plan section 1 format, header id@box =
# log: id@box, the vendor is the id's (a agy, c claude, g grok, m mistral,
# q qwen) and any registry row of the id here, ran: names a test.
_spl_review_line_syntax() {
  local rx='^review: ([acgmq]-[0-9]{3,})@([A-Za-z0-9._-]+) ([a-z]+) PASS [0-9a-f]{40} ran: .+ \| read: .+ \| log: ([^[:space:]@]+)@([^[:space:]:]+):/[^[:space:]]+$'
  [[ "$1" =~ $rx ]] ||
    { echo "SYNTAX FAIL not 'review: <id>@<box> <vendor> PASS <40-hex sha> ran: ... | read: ... | log: <id>@<box>:/<path>'"; return 1; }
  _spl_review_line_reviewer "$1" || return 1
  [[ -n "$(_spl_review_line_names "${1#* ran: }")" ]] ||
    { echo "SYNTAX FAIL ran: names no test (*.tst.sh, *.test.mjs, *_test.go, go test, pnpm run)"; return 1; }
}

# _spl_review_line_reviewer <line> - the header reviewer is an agent id
# <[acgmq]-NNN>@<box>, the same as the log: owner, and the vendor is the id's
# (a agy, c claude, g grok, m mistral, q qwen) and any registry row of it here.
_spl_review_line_reviewer() {
  local id vendor reg want who owner
  local rx='^review: ([^[:space:]@]+)@([^[:space:]]+) ([a-z]+) PASS .* \| log: ([^[:space:]@]+)@([^[:space:]:]+):'
  [[ "$1" =~ $rx ]] || { echo "SYNTAX FAIL no 'review: <id>@<box> <vendor> PASS ... | log: <id>@<box>:<path>'"; return 1; }
  id="${BASH_REMATCH[1]}" vendor="${BASH_REMATCH[3]}"
  who="$id@${BASH_REMATCH[2]}" owner="${BASH_REMATCH[4]}@${BASH_REMATCH[5]}"
  [[ "$id" =~ ^[acgmq]-[0-9]{3,}$ ]] || { echo "SYNTAX FAIL reviewer '$who' is not an agent id <[acgmq]-NNN>@<box>"; return 1; }
  [[ "$who" == "$owner" ]] || { echo "SYNTAX FAIL reviewer $who is not the log: owner $owner"; return 1; }
  case "${id%%-*}" in a) want=agy ;; c) want=claude ;; g) want=grok ;; m) want=mistral ;; q) want=qwen ;; esac
  [[ "$vendor" == "$want" ]] || { echo "SYNTAX FAIL vendor '$vendor' is not $id's ($want)"; return 1; }
  reg="$(awk -F'\t' -v i="$id" '{k = $1; sub(/@.*/, "", k)} k == i {v = $2} END {print v}' \
    "${SPOOL_ROOT:-/var/spool-hub}"/registry{,.retired}.tsv 2>/dev/null)"
  [[ -z "$reg" || "$reg" == "$vendor" ]] || { echo "SYNTAX FAIL $id is registered here as $reg, not $vendor"; return 1; }
}

# _spl_review_line_box - this box's tag.
_spl_review_line_box() {
  local v="${REVIEW_LINE_BOX:-${SPOOL_BOX_TAG:-}}" f="${SPOOL_BOX_ENV-/var/spool-hub/box.env}"
  [[ -z "$v" && -n "$f" && -r "$f" ]] && v="$(sed -n 's/^SPOOL_BOX_TAG=["'\'']\{0,1\}\([A-Za-z0-9._-]*\).*/\1/p' "$f" | tail -n1)"
  printf '%s' "${v:-$(hostname -s)}"
}

# _spl_review_line_vibe_session <path> [owner] - the path, or for a vibe
# journal file the store compacted away (`<session>/journal/<n>.jsonl` gone,
# the session dir holding CURRENT or chunks/) that session dir, with a NOTE on
# stderr; with an owner the tests run through `sudo -n -u <owner>`.
_spl_review_line_vibe_session() {
  local d="${1%/*}" u="${2:-}"
  if ! _spl_review_line_as "$u" test -e "$1" 2>/dev/null && [[ "${d##*/}" == journal ]] &&
    { _spl_review_line_as "$u" test -e "${d%/*}/CURRENT" || _spl_review_line_as "$u" test -d "${d%/*}/chunks"; } 2>/dev/null; then
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

# _spl_review_line_match <log path> [owner] < names - prints MISSING per name
# that no "command" in the log names, then the count; exit 0 all found, 3 any
# missing. With an owner only this read runs through `sudo -n -u <owner>`.
_spl_review_line_match() {
  _spl_review_line_as "${2:-}" python3 -I -c "$_SPL_REVIEW_LINE_PY" "$1"
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
    if os.path.isdir(path):
        subs = [os.path.join(path, c) for c in os.listdir(path)]
        n = sum(1 for c in subs if os.path.isdir(c) and (os.path.exists(os.path.join(c, "CURRENT")) or os.path.isdir(os.path.join(c, "journal"))))
        if n >= 2:
            print("FATAL log %s holds %d sessions: name the session dir of the reviewer alone" % (path, n))
            sys.exit(1)
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
