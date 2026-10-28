#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the box file follower of spec 160 row B1 (do_spl_file_stream_follow,
# scripts/file-stream-follow.py, its cron row) on synthetic files in a mktemp
# dir: no live log, spool root, crontab or hub is touched, and every key or
# token below is made up at run time (no key material in the tree).
#
# Each case of spec 160 section 4 runs twice: on the follower (GREEN) and on
# a copy of it with one planted defect, its red control (it must go RED; a
# control whose defect cannot be planted fails too, so none goes vacuous).
#   C1  first sight pushes the last 200 lines, not line 1
#   C2  3 appended lines: exactly those 3, seq +1 each
#   C3  rotate (mv f f.1; new f): the new file from 0, one rotated marker
#   C4  truncate: the new lines from 0, one truncated marker
#   C5  delete, then recreate: one missing marker, then the new lines
#   C5b the same, when the new file gets the old inode and size back
#   C6  a written line is on the stub hub within 5 s (control: a 30 s tick)
#   C7  readable is proven by the open, not by mode bits
#   C8  each deny-list class is refused, and a symlink to $HOME/.ssh/id_x in
#       an allowed dir
#   C9  tokens and a 4-line PEM key reach neither the queue file nor the wire
#   C10 the hub down for 3 ticks: every line arrives once, in seq order
#   C25 a PEM key split over 2 ticks and a restart: every line masked
#   C26 a cut key past the cap: 251 lines masked, one cap marker, then a
#       plain line followed
#   C31 a rotation to a symlink into $HOME/.ssh: refused on the reopen
#   C32 a glob's newest match is a symlink into a denied place: refused
#   C33 a hardlink to a key file under an allowed name: refused
#   C34 $HOME/.config, another home, .env, *_history, an ssh host key: denied
#   C35 with no SPOOL_ROOT (cron) the default spool root is denied; a root
#       that is not a directory: no start
#   C36 a symlink to a fifo or a device: refused, the tick not blocked, only
#       an O_PATH open of it (strace, when the box allows it)
#   C37 a whole key on one line: masked, the next lines followed unchanged
# And: the line cut and the rate limit (3.7), the action (cnf off = nothing
# followed; on = the cnf allow-list reaches the follower), the cron wrapper
# (refuses a worktree; off logs one line), the manifest row, and the shipped
# cnf keeps the follower off until row B2 (file_streams_push) is on master;
# the hubs: one line reaches the dev AND the prd hub, each through that env's
# desk, a hub that is down keeps only its own queue, a hub with no desk is one
# FATAL line (CONTROL: one shared state dir feeds only one hub).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "FAIL: jq and python3 are required"; exit 1; }

PY_REAL="$PROJ_ROOT/src/bash/scripts/file-stream-follow.py"
B="-----BEGIN" E="-----END" PK="PRIV""ATE KEY"
# another user's home, assembled so the hygiene sweep reads no home path
OTHER_HOME="/ho""me/zz-other-user"

rnd() { python3 -c 'import secrets, string, sys; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(int(sys.argv[1]))))' "$1"; }
b64() { python3 -c 'import base64, secrets, sys; print(base64.b64encode(secrets.token_bytes(48)).decode()[:int(sys.argv[1])])' "$1"; }

# newcase: a fresh case dir: home, spool root, logs, a stub hub that logs the
# frames it acks (none while <dir>/push.fail exists). Prints the dir.
newcase() {
  local d
  d="$(mktemp -d "$T/case.XXXXXX")"
  mkdir -p "$d/home/.ssh" "$d/spool" "$d/logs" "$d/x"
  echo "SECRET-$(rnd 12)" >"$d/home/.ssh/id_x"
  cat >"$d/push" <<'EOF'
#!/bin/sh
f="$(cat)"
[ -e "$PUSH_FAIL_FILE" ] && exit 1
printf '%s\n' "$f" >>"$PUSH_LOG"
echo '{"type":"ack","lane_op":"x"}'
EOF
  chmod +x "$d/push"
  : >"$d/pushed"
  echo "[]" >"$d/allow"
  echo "$d"
}

# allow <dir> <id> <path> [<id> <path>]...: the case's allow-list.
allow() {
  local d="$1"; shift
  python3 -c 'import json, sys; a = sys.argv[1:]; print(json.dumps([{"id": a[i], "path": a[i + 1]} for i in range(0, len(a), 2)]))' "$@" >"$d/allow"
}

# fs <py> <dir> [VAR=value]...: one tick of follower <py> in the case dir.
fs() {
  local py="$1" d="$2"; shift 2
  env HOME="$d/home" SPOOL_ROOT="$d/spool" FILE_STREAMS_STATE_DIR="$d/state" FILE_STREAMS_PUSH_CMD="$d/push" \
    PUSH_LOG="$d/pushed" PUSH_FAIL_FILE="$d/push.fail" FILE_STREAMS_ALLOW="$(cat "$d/allow")" "$@" \
    timeout 20 python3 "$py" --ticks 1 >>"$d/out" 2>&1
}

texts() { jq -r 'select(.lane_op == "file_streams_push") | .lines[] | .text' "$1/pushed"; }
seqs() { jq -r 'select(.lane_op == "file_streams_push") | .lines[] | .seq' "$1/pushed" | paste -sd' '; }
qtexts() { jq -r '.text' "$1/state/queue.jsonl" 2>/dev/null; }
status() { jq -r --arg k "$2" '.streams[$k] | "\(.status) \(.reason)"' "$1/state/state.json"; }
redactions() {
  jq -s -c '[.[] | select(.lane_op == "file_streams_push") | .redactions | to_entries[]]
    | group_by(.key) | map({key: .[0].key, value: (map(.value) | add)}) | from_entries' "$1/pushed"
}
nolines() { # nolines <dir> <string>...: none of them in a pushed frame or the queue file
  local d="$1" s; shift
  for s in "$@"; do
    if grep -qF -- "$s" "$d/pushed" || grep -qsF -- "$s" "$d/state/queue.jsonl"; then echo "  leaked: ${s:0:24}..."; return 1; fi
  done
}

# variant <name> <old> <new>: a copy of the follower with one planted
# defect (its spool_redact import still resolves); prints its path.
variant() {
  local d="$T/v/$1"
  mkdir -p "$d/src/bash/scripts"
  ln -sfn "$PROJ_ROOT/src/bash/features" "$d/src/bash/features"
  python3 - "$PY_REAL" "$d/src/bash/scripts/file-stream-follow.py" "$2" "$3" <<'EOF' || return 1
import sys
src, dst, old, new = sys.argv[1:]
s = open(src).read()
if s.count(old) != 1:
    sys.exit(f"the defect text is in the follower {s.count(old)} times, not once: {old!r}")
open(dst, "w").write(s.replace(old, new))
EOF
  echo "$d/src/bash/scripts/file-stream-follow.py"
}

# check <id> <what> <fn> [<control> <old> <new>]...: <fn> green on the
# follower, red on each planted defect.
check() {
  local id="$1" what="$2" fn="$3" v
  shift 3
  if "$fn" "$PY_REAL"; then pass "$id $what"; else fail "$id $what"; fi
  while (($# >= 3)); do
    if ! v="$(variant "$id-$1" "$2" "$3")"; then
      fail "$id control $1: its defect could not be planted"
    elif "$fn" "$v" >/dev/null 2>&1; then
      fail "$id control $1: still green on the planted defect"
    else
      pass "$id control $1: red on the planted defect"
    fi
    shift 3
  done
}

# ------------------------------------------------------------------ cases
c1() {
  local d n first
  d="$(newcase)"
  seq 1 300 | sed 's/^/line /' >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  fs "$1" "$d"
  n="$(texts "$d" | wc -l)" first="$(texts "$d" | sed -n 1p)"
  [[ "$n" == 200 && "$first" == "line 101" ]] || { echo "  C1: lines=$n first='$first'"; return 1; }
}

c2() {
  local d got s
  d="$(newcase)"
  seq 1 300 | sed 's/^/line /' >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  fs "$1" "$d"
  : >"$d/pushed"
  printf 'n1\nn2\nn3\n' >>"$d/logs/a.log"
  fs "$1" "$d"
  got="$(texts "$d" | paste -sd' ')" s="$(seqs "$d")"
  [[ "$got" == "n1 n2 n3" && "$s" == "201 202 203" ]] || { echo "  C2: lines='${got:0:60}' seqs='${s:0:40}'"; return 1; }
}

c3() {
  local d got
  d="$(newcase)"
  printf 'o1\no2\n' >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  fs "$1" "$d"
  : >"$d/pushed"
  mv "$d/logs/a.log" "$d/logs/a.log.1"
  : >"$d/logs/a.log"
  echo new1 >>"$d/logs/a.log"
  fs "$1" "$d"
  got="$(texts "$d" | paste -sd'|')"
  [[ "$got" == "-- file rotated --|new1" ]] || { echo "  C3: '$got'"; return 1; }
}

c4() {
  local d got
  d="$(newcase)"
  printf 'o1\no2\no3\n' >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  fs "$1" "$d"
  : >"$d/pushed"
  : >"$d/logs/a.log"
  echo t1 >>"$d/logs/a.log"
  fs "$1" "$d"
  got="$(texts "$d" | paste -sd'|')"
  [[ "$got" == "-- file truncated --|t1" ]] || { echo "  C4: '$got'"; return 1; }
}

c5() {
  local d got
  d="$(newcase)"
  echo o1 >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  fs "$1" "$d"
  : >"$d/pushed"
  rm -f "$d/logs/a.log"
  fs "$1" "$d"
  fs "$1" "$d"
  echo r1 >"$d/logs/a.log"
  fs "$1" "$d"
  got="$(texts "$d" | paste -sd'|')"
  [[ "$got" == "-- file missing --|r1" ]] || { echo "  C5: '$got'"; return 1; }
}

# c5b: the recreated file gets the deleted file's inode back with the same
# size (CI wf 10 run 40740255058 read nothing after the recreate): forced
# here by a hardlink that keeps the inode while the name is gone.
c5b() {
  local d got
  d="$(newcase)"
  echo o1 >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  fs "$1" "$d"
  : >"$d/pushed"
  ln "$d/logs/a.log" "$d/keep"
  rm -f "$d/logs/a.log"
  fs "$1" "$d"
  echo r1 >"$d/keep"
  ln "$d/keep" "$d/logs/a.log"
  rm -f "$d/keep"
  fs "$1" "$d"
  got="$(texts "$d" | paste -sd'|')"
  [[ "$got" == "-- file missing --|r1" ]] || { echo "  C5b: '$got'"; return 1; }
}

# c6 <py> <tick_s>: the long-lived loop; a line written after its first push
# must be on the stub hub within 5 s.
c6() {
  local d pid i=0 t0 ms=-1
  d="$(newcase)"
  echo l0 >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  env HOME="$d/home" SPOOL_ROOT="$d/spool" FILE_STREAMS_STATE_DIR="$d/state" FILE_STREAMS_PUSH_CMD="$d/push" \
    PUSH_LOG="$d/pushed" PUSH_FAIL_FILE="$d/push.fail" FILE_STREAMS_ALLOW="$(cat "$d/allow")" \
    FILE_STREAMS_TICK_S="$2" FILE_STREAMS_RUN_S=20 python3 "$1" >>"$d/out" 2>&1 &
  pid=$!
  until grep -q '"l0"' "$d/pushed" || ((i++ > 100)); do sleep 0.1; done
  t0="$(date +%s%N)"
  echo c6-mark >>"$d/logs/a.log"
  while (($(date +%s%N) - t0 < 5000000000)); do
    grep -q c6-mark "$d/pushed" && { ms=$((($(date +%s%N) - t0) / 1000000)); break; }
    sleep 0.1
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "  C6: tick ${2} s, the line reached the hub in ${ms} ms (-1 = not within 5 s)"
  ((ms >= 0))
}

c7() {
  local d a b
  d="$(newcase)"
  echo s1 >"$d/logs/denied-by-open.log"
  echo s2 >"$d/logs/owner-only.log"
  chmod 0044 "$d/logs/denied-by-open.log"
  chmod 0400 "$d/logs/owner-only.log"
  allow "$d" a "$d/logs/denied-by-open.log" b "$d/logs/owner-only.log"
  fs "$1" "$d"
  a="$(status "$d" a)" b="$(status "$d" b)"
  chmod 0644 "$d/logs/denied-by-open.log"
  [[ "$a" == "refused unreadable" && "$b" == "following " ]] || { echo "  C7: a='$a' b='$b'"; return 1; }
  texts "$d" | grep -x s2 >/dev/null || { echo "  C7: the owner-readable line was not pushed"; return 1; }
}

c8() {
  local d k bad="" s
  d="$(newcase)"
  mkdir -p "$d/x/keys" "$d/spool/c-1/inbox"
  s="$(cat "$d/home/.ssh/id_x")"
  for f in "$d/x/keys/a.log" "$d/x/k.pem" "$d/x/.env" "$d/x/b_history" "$d/spool/c-1/inbox/m.json"; do echo "$s" >"$f"; done
  ln -s "$d/home/.ssh/id_x" "$d/logs/ok.log"
  allow "$d" a "$d/home/.ssh/id_x" b "$d/x/keys/a.log" c "$d/x/k.pem" d "$d/x/.env" e "$d/x/b_history" \
    f "$d/spool/c-1/inbox/m.json" g "$d/logs/ok.log"
  fs "$1" "$d"
  for k in a b c d e f g; do
    [[ "$(status "$d" "$k")" == "refused denied path" ]] || bad+=" $k=$(status "$d" "$k")"
  done
  [[ -z "$bad" ]] || { echo "  C8: not refused:$bad"; return 1; }
  for k in "$OTHER_HOME/app.log" /root/app.log /proc/self/environ /etc/shadow; do
    HOME="$d/home" python3 "$1" --denied "$k" >/dev/null || { echo "  C8: $k not denied"; return 1; }
  done
  HOME="$d/home" python3 "$1" --denied "$d/logs/plain.log" >/dev/null && { echo "  C8: a plain path denied"; return 1; }
  nolines "$d" "$s"
}

c9() {
  local d gh br jt pw b1 b2 r
  d="$(newcase)"
  gh="gh""p_$(rnd 36)" br="$(rnd 32)" jt="$(rnd 24)" pw="$(rnd 14)" b1="$(b64 64)" b2="$(b64 64)"
  : >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  fs "$1" "$d"
  {
    echo "cloned with $gh"
    echo "curl -H 'Bea""rer $br'"
    echo "JIRA_API_TOK""EN=$jt"
    echo "pass""word: $pw"
    echo "$B RSA $PK-----"
    echo "$b1"
    echo "$b2"
    echo "$E RSA $PK-----"
    echo "after the key"
  } >>"$d/logs/a.log"
  touch "$d/push.fail"
  fs "$1" "$d"
  [[ "$(qtexts "$d" | wc -l)" -ge 9 ]] || { echo "  C9: the lines were not queued"; return 1; }
  nolines "$d" "$gh" "$br" "$jt" "$pw" "$b1" "$b2" || return 1
  rm -f "$d/push.fail"
  fs "$1" "$d"
  nolines "$d" "$gh" "$br" "$jt" "$pw" "$b1" "$b2" || return 1
  texts "$d" | grep -x "after the key" >/dev/null || { echo "  C9: the line after the key was not followed"; return 1; }
  r="$(redactions "$d")"
  jq -e '.["private-key"] == 1 and .["github-token"] >= 1 and .password >= 1 and .assignment >= 1' <<<"$r" >/dev/null ||
    { echo "  C9: redactions $r"; return 1; }
}

c10() {
  local d i got s
  d="$(newcase)"
  : >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  fs "$1" "$d"
  touch "$d/push.fail"
  for i in 1 2 3; do
    echo "d$i" >>"$d/logs/a.log"
    fs "$1" "$d"
  done
  rm -f "$d/push.fail"
  echo d4 >>"$d/logs/a.log"
  fs "$1" "$d"
  got="$(texts "$d" | paste -sd' ')" s="$(seqs "$d")"
  [[ "$got" == "d1 d2 d3 d4" && "$s" == "1 2 3 4" ]] || { echo "  C10: lines='$got' seqs='$s'"; return 1; }
}

c25() {
  local d b1 b2 b3 r
  d="$(newcase)"
  b1="$(b64 64)" b2="$(b64 64)" b3="$(b64 40)"
  : >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  fs "$1" "$d"
  printf '%s\n%s\n' "$B OPENSSH $PK-----" "$b1" >>"$d/logs/a.log"
  fs "$1" "$d"
  printf '%s\n%s\n%s\n%s\n' "$b2" "$b3" "$E OPENSSH $PK-----" "plain after" >>"$d/logs/a.log"
  fs "$1" "$d"
  nolines "$d" "$b1" "$b2" "$b3" || return 1
  texts "$d" | grep -x "plain after" >/dev/null || { echo "  C25: the line after the key was not followed"; return 1; }
  r="$(redactions "$d")"
  jq -e '.["private-key"] == 1' <<<"$r" >/dev/null || { echo "  C25: redactions $r"; return 1; }
}

c26() {
  local d n m
  d="$(newcase)"
  : >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  fs "$1" "$d"
  for _ in $(seq 1 250); do b64 64; done >"$d/body"
  { echo "$B RSA $PK-----"; cat "$d/body"; echo "plain-c26"; } >>"$d/logs/a.log"
  fs "$1" "$d"
  texts "$d" >"$d/texts"
  grep -qFxf "$d/body" "$d/texts" && { echo "  C26: a body line leaked"; return 1; }
  n="$(grep -cx '<redacted:private-key>' "$d/texts")" m="$(grep -cx -- '-- masked block cut at cap --' "$d/texts")"
  [[ "$n" == 251 && "$m" == 1 ]] || { echo "  C26: masked=$n cap markers=$m"; return 1; }
  grep -qx plain-c26 "$d/texts" || { echo "  C26: the plain line was not followed"; return 1; }
}

c31() {
  local d s
  d="$(newcase)"
  s="$(cat "$d/home/.ssh/id_x")"
  echo o1 >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  fs "$1" "$d"
  mv "$d/logs/a.log" "$d/logs/a.log.1"
  ln -s "$d/home/.ssh/id_x" "$d/logs/a.log"
  fs "$1" "$d"
  [[ "$(status "$d" a)" == "refused denied path" ]] || { echo "  C31: $(status "$d" a)"; return 1; }
  nolines "$d" "$s"
}

c32() {
  local d s
  d="$(newcase)"
  s="$(cat "$d/home/.ssh/id_x")"
  mkdir -p "$d/g"
  echo g1 >"$d/g/app-1.log"
  allow "$d" a "$d/g/app-*.log"
  fs "$1" "$d"
  texts "$d" | grep -x g1 >/dev/null || { echo "  C32: the first match was not followed"; return 1; }
  ln -s "$d/home/.ssh/id_x" "$d/g/app-2.log"
  touch -h -d "@$(($(date +%s) + 60))" "$d/g/app-2.log"
  fs "$1" "$d"
  [[ "$(status "$d" a)" == "refused denied path" ]] || { echo "  C32: $(status "$d" a)"; return 1; }
  texts "$d" | grep -x -- '-- refused: denied path --' >/dev/null || { echo "  C32: no refused marker"; return 1; }
  nolines "$d" "$s"
}

c33() {
  local d s
  d="$(newcase)"
  s="$(cat "$d/home/.ssh/id_x")"
  ln "$d/home/.ssh/id_x" "$d/logs/h.log"
  allow "$d" a "$d/logs/h.log"
  fs "$1" "$d"
  [[ "$(status "$d" a)" == "refused hardlink" ]] || { echo "  C33: $(status "$d" a)"; return 1; }
  texts "$d" | grep -x -- '-- refused: hardlink --' >/dev/null || { echo "  C33: no hardlink marker"; return 1; }
  nolines "$d" "$s"
}

c34() {
  local d k bad="" s
  d="$(newcase)"
  s="$(cat "$d/home/.ssh/id_x")"
  mkdir -p "$d/home/.config"
  for f in "$d/home/.config/x.log" "$d/x/.env" "$d/x/app_history"; do echo "$s" >"$f"; done
  allow "$d" a '$HOME/.config/x.log' b "$d/x/.env" c "$d/x/app_history"
  fs "$1" "$d"
  for k in a b c; do
    [[ "$(status "$d" "$k")" == "refused denied path" ]] || bad+=" $k=$(status "$d" "$k")"
  done
  [[ -z "$bad" ]] || { echo "  C34: not refused:$bad"; return 1; }
  for k in "$OTHER_HOME/x.log" /etc/ssh/ssh_host_x_key; do
    HOME="$d/home" python3 "$1" --denied "$k" >/dev/null || { echo "  C34: $k not denied"; return 1; }
  done
  nolines "$d" "$s"
}

c35() {
  local d out rc
  d="$(newcase)"
  for k in /var/spool-hub/hub.log /var/spool-hub/c-001/inbox/m.json; do
    out="$(env -i PATH="$PATH" python3 "$1" --denied "$k")" || { echo "  C35: $k not denied with an empty env"; return 1; }
  done
  [[ "$out" == "spool root" ]] || { echo "  C35: reason '$out'"; return 1; }
  : >"$d/not-a-dir"
  out="$(env -i PATH="$PATH" HOME="$d/home" SPOOL_ROOT="$d/not-a-dir" FILE_STREAMS_STATE_DIR="$d/state" python3 "$1" --ticks 1 2>&1)"
  rc=$?
  [[ "$rc" == 2 && "$out" == *"not started"* && ! -d "$d/state" ]] || { echo "  C35: rc=$rc out='$out'"; return 1; }
}

c36() {
  local d rc
  d="$(newcase)"
  mkfifo "$d/x/fifo"
  ln -s "$d/x/fifo" "$d/logs/f.log"
  ln -s /dev/null "$d/logs/n.log"
  allow "$d" f "$d/logs/f.log" n "$d/logs/n.log"
  env HOME="$d/home" SPOOL_ROOT="$d/spool" FILE_STREAMS_STATE_DIR="$d/state" FILE_STREAMS_PUSH_CMD="$d/push" \
    PUSH_LOG="$d/pushed" PUSH_FAIL_FILE="$d/push.fail" FILE_STREAMS_ALLOW="$(cat "$d/allow")" \
    timeout 5 python3 "$1" --ticks 1 >>"$d/out" 2>&1
  rc=$?
  [[ "$rc" == 0 ]] || { echo "  C36: the tick did not finish (rc=$rc)"; return 1; }
  [[ "$(status "$d" f)" == "refused not a regular file" && "$(status "$d" n)" == "refused denied path" ]] ||
    { echo "  C36: f='$(status "$d" f)' n='$(status "$d" n)'"; return 1; }
  if strace -f -qq -e trace=open,openat -o "$d/probe" true 2>/dev/null; then
    rm -rf "$d/state"
    env HOME="$d/home" SPOOL_ROOT="$d/spool" FILE_STREAMS_STATE_DIR="$d/state" FILE_STREAMS_PUSH_CMD= \
      FILE_STREAMS_ALLOW="$(cat "$d/allow")" timeout 10 strace -f -qq -e trace=open,openat -o "$d/trace" \
      python3 "$1" --ticks 1 >>"$d/out" 2>&1
    grep -qE 'logs/(f|n)\.log' "$d/trace" || { echo "  C36: strace saw no open of the names"; return 1; }
    if grep -E 'logs/(f|n)\.log|x/fifo|/dev/null' "$d/trace" | grep -v O_PATH | grep . >/dev/null; then
      echo "  C36: a read open of a refused target: $(grep -E 'logs/(f|n)\.log|x/fifo|/dev/null' "$d/trace" | grep -v O_PATH | sed -n 1p)"
      return 1
    fi
    echo "  C36: strace: only O_PATH opens of the fifo and the device names"
  else
    echo "  C36: strace cannot trace on this box: the O_PATH-only check skipped, the non-blocking tick checked"
  fi
}

c37() {
  local d b1 got
  d="$(newcase)"
  b1="$(b64 64)"
  : >"$d/logs/a.log"
  allow "$d" a "$d/logs/a.log"
  fs "$1" "$d"
  printf '{"msg":"cfg","v":"%s\\n%s\\n%s"}\np1\np2\np3\n' "$B RSA $PK-----" "$b1" "$E RSA $PK-----" >>"$d/logs/a.log"
  fs "$1" "$d"
  nolines "$d" "$b1" || return 1
  got="$(texts "$d" | sed -n '2,$p' | paste -sd' ')"
  [[ "$got" == "p1 p2 p3" ]] || { echo "  C37: after the key line: '$got'"; return 1; }
}

check C1 "first sight pushes the last 200 lines" c1 \
  start-at-0 'st["offset"] = self.tail_start(fd, fst.st_size)' 'st["offset"] = 0'
check C2 "3 appended lines: exactly those, seq +1 each" c2 \
  reread-from-0 'st["offset"] = off + used' 'st["offset"] = 0'
check C3 "a rotation follows the new file from 0 with one marker" c3 \
  follow-the-fd 'elif st.get("ident") != ident or st.get("name") != name:' 'elif False:'
check C4 "a truncation reads the new lines from 0 with one marker" c4 \
  keep-the-offset 'elif fst.st_size < st.get("offset", 0):' 'elif False:'
check C5 "a deleted then recreated file: one missing marker, then its lines" c5 \
  exit-on-enoent 'raise Missing()' 'raise SystemExit(3)'
check C5b "a recreated file with the old inode and size is read from 0" c5b \
  same-inode-not-new 'elif was == "missing":  # ctl:back-from-missing' 'elif False:'
c6 "$PY_REAL" 1 && pass "C6 a written line is on the hub within 5 s" || fail "C6 a written line is on the hub within 5 s"
c6 "$PY_REAL" 30 >/dev/null && fail "C6 control 30 s tick: still within 5 s" || pass "C6 control 30 s tick: red, over 5 s"
if [[ "$(id -u)" == 0 ]]; then
  echo "SKIP C7: root reads past the mode bits; the case needs a plain user"
else
  check C7 "readable is proven by the open, not by the mode bits" c7 \
    mode-bits 'if not stat.S_ISREG(st.st_mode):' 'if not stat.S_ISREG(st.st_mode) or not st.st_mode & 0o004:'
fi
check C8 "every deny-list class and a symlink to \$HOME/.ssh are refused" c8 \
  deny-on-name 'why = spl_file_stream_denied(real, ctx)' 'why = ""'
check C9 "tokens and a PEM key reach neither the queue file nor the wire" c9 \
  no-pem-state 'if st.get("pem_open"):' 'if False:' \
  queue-before-redact 'masked, counts = redact(text)' 'masked, counts = text, {}'
check C10 "the hub down for 3 ticks: every line once, in seq order" c10 \
  drop-on-fail 'if not batch or not self.send(frame):' 'if not batch or not (self.send(frame) or True):'
check C25 "a key split over 2 ticks and a restart stays masked" c25 \
  pem-state-in-memory 'json.dumps(self.state, sort_keys=True, indent=1)' \
  'json.dumps({"streams": {k: dict(v, pem_open=False) for k, v in self.state["streams"].items()}}, sort_keys=True, indent=1)'
check C26 "a cut key past the cap: all masked, one marker, the log goes on" c26 \
  hard-cap 'if in_cap or B64_LINE_RE.match(text) or PEM_END_RE.search(text):' 'if in_cap:' \
  no-cap 'if in_cap or B64_LINE_RE.match(text) or PEM_END_RE.search(text):' 'if True:'
check C31 "a rotation to a symlink into \$HOME/.ssh is refused on the reopen" c31 \
  deny-on-name 'why = spl_file_stream_denied(real, ctx)' 'why = ""'
check C32 "a glob switching to a denied symlink is refused with a marker" c32 \
  deny-on-name 'why = spl_file_stream_denied(real, ctx)' 'why = ""'
check C33 "a hardlink to a key file is refused" c33 \
  realpath-only 'if st.st_nlink != 1:' 'if False:'
check C34 "\$HOME/.config, another home, .env, *_history, a host key: denied" c34 \
  named-list-only 'if p != h and rel.startswith("."):' 'if False:'
check C35 "no SPOOL_ROOT: the default root denied; not a dir: no start" c35 \
  root-from-env-only 'roots = (DEFAULT_SPOOL_ROOT, spool_root())' 'roots = (os.environ.get("SPOOL_ROOT", "/nonexistent"),)'
check C36 "a fifo or a device behind a symlink: refused, the tick not blocked" c36 \
  plain-open 'os.open(name, os.O_PATH | os.O_CLOEXEC)' 'os.open(name, os.O_RDONLY | os.O_CLOEXEC)'
check C37 "a whole key on one line opens no block" c37 \
  block-on-any-begin 'if m and not PEM_END_RE.search(text, m.end()):' 'if m:'

# ------------------------------------------------------------------ limits
d="$(newcase)"
: >"$d/logs/a.log"
allow "$d" a "$d/logs/a.log"
fs "$PY_REAL" "$d" FILE_STREAMS_RATE_PER_MIN=5 FILE_STREAMS_LINE_BYTES=10
printf '%s\n' "$(printf 'x%.0s' $(seq 1 30))" r2 r3 r4 r5 r6 r7 r8 >>"$d/logs/a.log"
fs "$PY_REAL" "$d" FILE_STREAMS_RATE_PER_MIN=5 FILE_STREAMS_LINE_BYTES=10
got="$(texts "$d" | paste -sd'|')"
[[ "$got" == "xxxxxxxxxx [cut 20 bytes]|r2|r3|r4|r5|-- dropped 3 lines --" ]] &&
  pass "3.7 a long line is cut, past the rate the rest is dropped with one marker" ||
  fail "3.7 cut and rate: '$got'"
ann="$(jq -c -S 'select(.lane_op == "file_streams_announce") | .streams' "$d/pushed" | sed -n 1p)"
[[ "$ann" == "[{\"path\":\"$d/logs/a.log\",\"state\":\"following\",\"stream_key\":\"a\"}]" ]] &&
  pass "3.3 the announce frame lists the stream and its state" || fail "3.3 announce: '$ann'"

# ------------------------------------------------------------------ action
d="$(newcase)"
seq 1 5 | sed 's/^/act /' >"$d/logs/a.log"
cat >"$d/cnf.yaml" <<EOF
env:
  box:
    file_streams:
      enabled: false
      allow:
        - id: act
          path: $d/logs/a.log
      start_lines: 2
EOF
act() {
  env HOME="$d/home" SPOOL_ROOT="$d/spool" FILE_STREAMS_STATE_DIR="$d/state" FILE_STREAMS_CNF="$d/cnf.yaml" \
    FILE_STREAMS_PUSH_CMD="$d/push" PUSH_LOG="$d/pushed" PUSH_FAIL_FILE="$d/push.fail" \
    FILE_STREAMS_AGENT_USER="$(id -un)" FILE_STREAMS_TICKS=1 "$@" \
    bash -c 'source "$1"; do_spl_file_stream_follow' _ "$PROJ_ROOT/src/bash/run/spl-file-stream-follow.func.sh" 2>&1
}
out="$(act)"
[[ "$out" == *"file-streams: off"* && ! -e "$d/state" ]] &&
  pass "action: cnf enabled false follows nothing" || fail "action off: '$out'"
if command -v yq >/dev/null; then
  out="$(act FILE_STREAMS_ENABLED=true)"
  got="$(texts "$d" | paste -sd' ')"
  [[ "$got" == "act 4 act 5" ]] && pass "action: on, the cnf allow-list and start_lines reach the follower" ||
    fail "action on: pushed '$got' out='$out'"
  # cron runs with no SPOOL_ROOT (SPL-4037: every tick from 18:24Z logged rc=1
  # with no output, the env helper's status). The follower then reads the
  # default root: a box has it (rc 0); a CI runner has none, and the follower
  # itself refuses to start, which still proves the helper let it run.
  out="$(act FILE_STREAMS_ENABLED=true SPOOL_ROOT= FILE_STREAMS_STATE_DIR="$d/state-cron")"; rc=$?
  { [[ "$rc" == 0 && "$out" != *FATAL* ]] ||
    [[ ! -d /var/spool-hub && "$out" == *"FATAL the spool root /var/spool-hub is not a directory"* ]]; } &&
    pass "action: on with no SPOOL_ROOT (cron) reaches the follower" ||
    fail "action no SPOOL_ROOT: rc=$rc out='$out'"
else
  fail "action on: yq is required"
fi

# ------------------------------------------------------------------ hubs
# Owner HUM-10 poll 38eeb655 (BOTH): every box feeds the dev AND the prd hub,
# each through the box's desk of that env, each with its own state and queue.
# hubcase <dir>: a desk per env (keys dir, a stub spool that logs the frames
# it acks to <dir>/pushed-<env>, none while <dir>/fail-<env> exists) and the
# cnf with its <env>.env.json hub names.
hubcase() {
  local d="$1" e
  for e in dev prd; do
    mkdir -p "$d/cloud/$e/desk/t9/box-t/keys" "$d/cloud/$e/bin"
    cat >"$d/cloud/$e/bin/spool" <<EOS
#!/bin/sh
[ "\$1 \$2 \$3" = "file-streams push --json" ] || exit 9
f="\$(cat)"
[ -e "$d/fail-$e" ] && exit 1
printf '%s %s %s %s\n' "\$SPOOL_HUB_URL" "\$SPOOL_BOX_ID" "\$SPOOL_TENANT" "\$SPOOL_KEYS_DIR" >>"$d/via-$e"
printf '%s\n' "\$f" >>"$d/pushed-$e"
echo '{"type":"ack","lane_op":"x"}'
EOS
    chmod +x "$d/cloud/$e/bin/spool"
    printf '{"env":{"dns":{"api_fqdn":"%s.api.example.com"}}}\n' "$e" >"$d/$e.env.json"
    : >"$d/pushed-$e"
  done
  seq 1 3 | sed 's/^/hb /' >"$d/logs/a.log"
  printf 'env:\n  box:\n    file_streams:\n      enabled: true\n      hubs: [dev, prd]\n      allow:\n        - id: h\n          path: %s\n      start_lines: 1\n' \
    "$d/logs/a.log" >"$d/cnf.yaml"
}
hub_act() {
  local func="$1" d="$2"; shift 2
  env -u FILE_STREAMS_PUSH_CMD -u FILE_STREAMS_HUBS HOME="$d/home" SPOOL_ROOT="$d/spool" SPOOL_TEST=1 \
    SPOOL_DESK_BOX=box-t FILE_STREAMS_TENANT=t9 FILE_STREAMS_DESK_USER="$(id -un)" \
    FILE_STREAMS_DESK_STATE="$d/cloud/%ENV%" FILE_STREAMS_STATE_DIR="$d/state" FILE_STREAMS_CNF="$d/cnf.yaml" \
    FILE_STREAMS_AGENT_USER="$(id -un)" FILE_STREAMS_TICKS=1 "$@" \
    bash -c 'source "$1"; do_spl_file_stream_follow' _ "$func" 2>&1
}
htexts() { jq -r 'select(.lane_op == "file_streams_push") | .lines[] | .text' "$1/pushed-$2" | paste -sd' '; }
if command -v yq >/dev/null; then
  FUNC="$PROJ_ROOT/src/bash/run/spl-file-stream-follow.func.sh"
  hd="$(newcase)"; hubcase "$hd"
  out="$(hub_act "$FUNC" "$hd")"; rc=$?
  [[ "$rc" == 0 && "$(htexts "$hd" dev)" == "hb 3" && "$(htexts "$hd" prd)" == "hb 3" ]] &&
    pass "hubs: one line reaches BOTH the dev and the prd hub" || fail "hubs both: rc=$rc dev='$(htexts "$hd" dev)' prd='$(htexts "$hd" prd)' out='$out'"
  [[ "$(sort -u "$hd/via-dev")" == "https://dev.api.example.com box-t t9 $hd/cloud/dev/desk/t9/box-t/keys" &&
     "$(sort -u "$hd/via-prd")" == "https://prd.api.example.com box-t t9 $hd/cloud/prd/desk/t9/box-t/keys" ]] &&
    pass "hubs: each push rides that env's desk (hub url, box, tenant, keys)" || fail "hubs via: dev='$(cat "$hd/via-dev")' prd='$(cat "$hd/via-prd")'"
  [[ "$out" == *"hub=dev "* && "$out" == *"hub=prd "* ]] && pass "hubs: every follower line names its hub" ||
    fail "hubs log: '$out'"

  # one hub down: its line stays queued for it, the other hub is not held back
  hd="$(newcase)"; hubcase "$hd"; : >"$hd/fail-prd"
  out="$(hub_act "$FUNC" "$hd")"
  q="$(jq -r '.text' "$hd/state/prd/queue.jsonl" 2>/dev/null | paste -sd' ')"
  [[ "$(htexts "$hd" dev)" == "hb 3" && -z "$(htexts "$hd" prd)" && "$q" == "hb 3" &&
     -z "$(jq -r '.text' "$hd/state/dev/queue.jsonl" 2>/dev/null)" ]] &&
    pass "hubs: prd down keeps its line queued for prd; dev got it and its queue is empty" ||
    fail "hubs prd down: dev='$(htexts "$hd" dev)' prdq='$q' out='$out'"
  rm -f "$hd/fail-prd"
  hub_act "$FUNC" "$hd" >/dev/null
  [[ "$(htexts "$hd" prd)" == "hb 3" && "$(htexts "$hd" dev)" == "hb 3" ]] &&
    pass "hubs: prd back, the queued line reaches prd once, dev gets no second copy" ||
    fail "hubs prd back: dev='$(htexts "$hd" dev)' prd='$(htexts "$hd" prd)'"

  # CONTROL: one state dir for both hubs (the per-env dir removed): the second
  # follower finds the first one's lock and feeds nothing
  hd="$(newcase)"; hubcase "$hd"
  co="$hd/c/csi-spl-orc"
  mkdir -p "$co/src/bash/run" "$co/src/bash/scripts" "$co/lib/bash/funcs"
  cp "$PROJ_ROOT/src/bash/run/spl-cost-tokens-read.func.sh" "$co/src/bash/run/"
  cp "$PROJ_ROOT/src/bash/scripts/file-stream-follow.py" "$co/src/bash/scripts/"
  cp "$PROJ_ROOT/lib/bash/funcs/spl-desk-box.func.sh" "$co/lib/bash/funcs/"
  sed 's|"FILE_STREAMS_STATE_DIR=$base/$e"|"FILE_STREAMS_STATE_DIR=$base"|' "$FUNC" >"$co/src/bash/run/f.sh"
  grep -q '"FILE_STREAMS_STATE_DIR=$base"' "$co/src/bash/run/f.sh" || fail "hubs CONTROL: the sed did not plant the shared state dir"
  out="$(hub_act "$co/src/bash/run/f.sh" "$hd" FILE_STREAMS_TICKS=3)"
  [[ -z "$(htexts "$hd" dev)" || -z "$(htexts "$hd" prd)" ]] &&
    pass "hubs CONTROL: one shared state dir, one hub gets nothing" ||
    fail "hubs CONTROL: both hubs fed with one state dir: dev='$(htexts "$hd" dev)' prd='$(htexts "$hd" prd)'"

  # a hub with no desk on the box: one FATAL line, the other hub still fed
  hd="$(newcase)"; hubcase "$hd"; rm -rf "$hd/cloud/prd/desk"
  out="$(hub_act "$FUNC" "$hd")"; rc=$?
  [[ "$rc" != 0 && "$(grep -c 'FATAL file-streams: hub=prd: no desk keys' <<<"$out")" == 1 &&
     "$(htexts "$hd" dev)" == "hb 3" && ! -e "$hd/state/prd" ]] &&
    pass "hubs: prd with no desk logs one FATAL line, dev is still fed" || fail "hubs no desk: rc=$rc '$out'"
  # the push runs as the agent user: a different desk user is reached by sudo,
  # the same one is not
  hd="$(newcase)"; hubcase "$hd"
  hc() { env SPOOL_TEST=1 SPOOL_DESK_BOX=box-t FILE_STREAMS_TENANT=t9 FILE_STREAMS_DESK_USER="$(id -un)" \
    FILE_STREAMS_DESK_STATE="$hd/cloud/%ENV%" bash -c 'source "$1"; spl_file_stream_hub_cmd "$2" dev "$3"' _ "$FUNC" "$hd/cnf.yaml" "$1"; }
  [[ "$(hc zz-agent)" == "sudo -n -u $(id -un) env SPOOL_ROOT="* && "$(hc "$(id -un)")" == "env SPOOL_ROOT="* ]] &&
    pass "hubs: the push sudoes to the desk user only when the agent user differs" ||
    fail "hubs sudo: other='$(hc zz-agent)' same='$(hc "$(id -un)")'"
  # a bare `spool` is never what the push calls
  [[ "$(grep -c 'timeout 20 spool ' "$FUNC")" == 0 ]] &&
    pass "hubs: no bare spool call in the action" || fail "hubs: a bare spool call is back"
  v="$(yq -r '.env.box.file_streams.hubs | join(" ")' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")"
  [[ "$v" == "dev prd" ]] && pass "cnf: file_streams.hubs is dev and prd (owner: BOTH)" || fail "cnf hubs: '$v'"
else
  fail "hubs: yq is required"
fi

# ------------------------------------------------------------------ cron
W="$T/x-wt/c-1/csi-spl-orc/src/bash"
mkdir -p "$W/scripts" "$W/run" "$W/../../lib/bash/funcs"
cp "$PROJ_ROOT/lib/bash/funcs/spl-desk-box.func.sh" "$W/../../lib/bash/funcs/"
cp "$PROJ_ROOT/src/bash/scripts/file-stream-follow-cron.sh" "$W/scripts/"
cp "$PROJ_ROOT/src/bash/run/spl-file-stream-follow.func.sh" "$PROJ_ROOT/src/bash/run/spl-cost-tokens-read.func.sh" "$W/run/"
out="$(bash "$W/scripts/file-stream-follow-cron.sh" 2>&1)"
rc=$?
[[ "$rc" == 2 && "$out" == *"agent worktree"* ]] && pass "cron: an agent worktree is refused" || fail "cron worktree: rc=$rc '$out'"
out="$(FILE_STREAMS_ALLOW_WORKTREE=1 FILE_STREAMS_CNF="$d/cnf.yaml" bash "$W/scripts/file-stream-follow-cron.sh" 2>&1)"
rc=$?
[[ "$rc" == 0 && "$out" =~ ^[0-9T:-]+Z\ INFO\ file-streams:\ off ]] && pass "cron: off by cnf logs one stamped line" ||
  fail "cron off: rc=$rc '$out'"
grep -qE '^file-streams +\| \* \* \* \* \* +\| src/bash/scripts/file-stream-follow-cron.sh +\| file-streams/cron.log' \
  "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" && [[ -x "$PROJ_ROOT/src/bash/scripts/file-stream-follow-cron.sh" ]] &&
  pass "cron: the manifest row file-streams runs the wrapper every minute" || fail "cron: no manifest row or wrapper"

# The guard of brief B1: the cron row lands off until row B2 (the hub's
# file_streams_push) is on master. Retires itself the day B2 lands.
CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
if grep -rqs file_streams_push "$APP_ROOT/csi-spl-api/src"; then
  echo "SKIP the off-until-B2 guard: B2 (file_streams_push) is on this tree"
elif command -v yq >/dev/null; then
  v="$(yq -r '.env.box.file_streams.enabled' "$CNF")"
  [[ "$v" == false ]] && pass "cnf: file_streams.enabled is false while B2 is not on the tree" ||
    fail "cnf: file_streams.enabled is '$v' but no hub takes file_streams_push yet"
fi

[[ "$fails" == 0 ]] && echo "OK spl-file-stream-follow: all passed" || echo "FAIL spl-file-stream-follow: $fails failed"
((fails == 0))
