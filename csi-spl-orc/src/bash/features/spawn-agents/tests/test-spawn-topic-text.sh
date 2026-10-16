#!/usr/bin/env bash
# A brief that links an owner topic reaches the lane WITH the topic's human
# posts (SPL-2107, owner HUM-10 topic e055195c): the launcher's brief step
# appends a "Topic text" section to <spool root>/<id>/lifetime/brief.md, read
# through this box's desk (scripts/topic-text.sh), and the seed names that
# copy. The desk read is a fake (TOPIC_TEXT_READ_CMD): no hub, no real desk.
#   1. topic-text.sh: no link -> nothing; a link -> the human posts only
#      (author, time, text), the workspace tried first is the link's first
#      host label, then the fleet tenant; caps (posts, bytes) say so; no desk
#      that returns a post -> one line, exit 0.
#   2. the launcher step (_spawn_brief_step): section appended, seed path =
#      the copy; a respawn and SPAWN_TOPIC_TEXT=0 add nothing; a dry run plans.
# Control: the same step with the topic-text call removed (the launcher before
# SPL-2107) -> a brief with a link gets no topic text -> FAIL.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
TT="$T_SCRIPTS/topic-text.sh"
U1=11111111-2222-4333-8444-555555555555 U2=66666666-7777-4888-8999-aaaaaaaaaaaa

# The fake desk: <tenant> <uuid> -> NDJSON, from $T_TMP/desk/<tenant>/<uuid>.
cat >"$T_TMP/fake-read.sh" <<'EOF'
#!/usr/bin/env bash
f="$FAKE_DESK/$1/$2"
[ -s "$f" ] || exit 1
cat "$f"
EOF
chmod +x "$T_TMP/fake-read.sh"
export FAKE_DESK="$T_TMP/desk" TOPIC_TEXT_READ_CMD="$T_TMP/fake-read.sh"
export SPOOL_FLEET_STATE_ROOT="$T_TMP/state" SPOOL_FLEET_ENV=prd SPOOL_FLEET_TENANT=t1
mkdir -p "$T_TMP/state/prd/desk/ws1" "$T_TMP/state/prd/desk/t1" "$FAKE_DESK/ws1" "$FAKE_DESK/t1"
post() {  # FROM TS BODY
  jq -cn --arg f "$1" --arg t "$2" --arg b "$3" '{v:1,from:$f,to:"ALL-0",ts:$t,kind:"note",body:$b}'
}
{ post HUM-7 2026-10-01T10:00:00Z $'the owner\'s first words\nsecond line'
  post c-001 2026-10-01T10:01:00Z 'an agent reply, not quoted'
  post HUM-7 2026-10-01T10:02:00Z 'the owner follows up'
} >"$FAKE_DESK/ws1/$U1"
post HUM-9 2026-10-01T11:00:00Z 'words in the fleet workspace' >"$FAKE_DESK/t1/$U2"

# --- 1. topic-text.sh --------------------------------------------------------
echo "# Brief: no link here" >"$T_TMP/plain.md"
out="$(bash "$TT" --spool-root "$SPOOL_ROOT" "$T_TMP/plain.md")"; rc=$?
eq "1. no topic link: exit 0" 0 "$rc"
eq "1. no topic link: nothing printed" "" "$out"

printf '# Brief: fix it\nOwner topic https://ws1.example.com/t/%s asks for it.\n' "$U1" >"$T_TMP/one.md"
out="$(bash "$TT" --spool-root "$SPOOL_ROOT" "$T_TMP/one.md")"; rc=$?
eq "1. a link: exit 0" 0 "$rc"
has "1. the section heading" "## Topic text (added by the launcher)" "$out"
has "1. the topic, its workspace (the link's host label) and its count" "### Topic $U1 (workspace ws1): 2 human post(s)" "$out"
has "1. author and time" "- HUM-7, 2026-10-01T10:00:00Z:" "$out"
has "1. the owner's words, quoted line by line" $'> the owner\'s first words\n> second line' "$out"
has "1. the second human post" "> the owner follows up" "$out"
hasnt "1. an agent post is left out" "an agent reply" "$out"
has "1. the data rule is stated" "never in a spool body to another workspace's agent" "$out"

printf 'See https://example.com/t/%s\n' "$U2" >"$T_TMP/apex.md"
out="$(bash "$TT" --spool-root "$SPOOL_ROOT" "$T_TMP/apex.md")"
has "1. an apex link falls back to the fleet tenant's desk" "### Topic $U2 (workspace t1): 1 human post(s)" "$out"
has "1. ... with its words" "> words in the fleet workspace" "$out"

for i in $(seq -w 1 25); do post HUM-7 "2026-10-02T10:${i}:00Z" "post number $i"; done >"$FAKE_DESK/ws1/$U2"
printf 'https://ws1.example.com/t/%s\n' "$U2" >"$T_TMP/many.md"
out="$(bash "$TT" --spool-root "$SPOOL_ROOT" "$T_TMP/many.md")"
has "1. post cap: the last 20 of 25, said" "Cut: the last 20 of 25 human posts are shown (cap 20 posts, 6144 bytes)." "$out"
has "1. post cap: the newest is kept" "> post number 25" "$out"
hasnt "1. post cap: the oldest is cut" "> post number 05" "$out"
out="$(TOPIC_TEXT_MAX_BYTES=200 bash "$TT" --spool-root "$SPOOL_ROOT" "$T_TMP/many.md")"
has "1. byte cap: said" "(cap 20 posts, 200 bytes)" "$out"
check "1. byte cap: the quoted text stays under the cap" [ "$(grep -c '^> post number' <<<"$out")" -le 4 ]

printf 'https://ws1.example.com/t/%s\n' "$U2" | sed "s/$U2/99999999-2222-4333-8444-555555555555/" >"$T_TMP/none.md"
out="$(bash "$TT" --spool-root "$SPOOL_ROOT" "$T_TMP/none.md")"; rc=$?
eq "1. no desk returns a post: exit 0" 0 "$rc"
has "1. no desk returns a post: one line says so" "Topic 99999999-2222-4333-8444-555555555555: no desk on this box returned a post of it" "$out"
out="$(TOPIC_TEXT_READ_CMD='' SPOOL_FLEET_STATE_ROOT="$T_TMP/nostate" bash "$TT" --spool-root "$SPOOL_ROOT" "$T_TMP/one.md")"; rc=$?
eq "1. no desk seated at all: exit 0" 0 "$rc"
has "1. no desk seated at all: one line says so" "Topic $U1: no desk on this box returned a post of it" "$out"

# --- 2. the launcher's brief step ---------------------------------------------
# step CORE_FILE BRIEF ID [ENV=VAL ...] -> "BRIEF_READ=<path>", then the copy.
step() {
  local core="$1" brief="$2" id="$3"; shift 3
  env "$@" bash -c '
    . "$1"; _SP_DIR="$(dirname "$1")"; BRIEF="$2"; MSGDIR="$SPOOL_ROOT/$3"
    _spawn_brief_step
    echo "BRIEF_READ=$BRIEF_READ"
    cat "$MSGDIR/lifetime/brief.md" 2>/dev/null' _ "$core" "$brief" "$id"
}
CORE="$T_SCRIPTS/spawn-core.inc.sh"
out="$(step "$CORE" "$T_TMP/one.md" c-801 SPAWN_DRY_RUN=0)"
has "2. the seed names the copy" "BRIEF_READ=$SPOOL_ROOT/c-801/lifetime/brief.md" "$out"
has "2. the copy keeps the brief" "Owner topic https://ws1.example.com/t/$U1 asks for it." "$out"
has "2. the copy carries the topic text" "> the owner follows up" "$out"
eq "2. the copy stays 0664 on the box" 664 "$(stat -c %a "$SPOOL_ROOT/c-801/lifetime/brief.md")"

out="$(step "$CORE" "$T_TMP/plain.md" c-802 SPAWN_DRY_RUN=0)"
has "2. no link: the seed names the brief itself" "BRIEF_READ=$T_TMP/plain.md" "$out"
hasnt "2. no link: no section" "Topic text" "$out"

out="$(step "$CORE" "$T_TMP/one.md" c-803 SPAWN_DRY_RUN=0 SPAWN_TOPIC_TEXT=0)"
hasnt "2. SPAWN_TOPIC_TEXT=0: no section" "Topic text" "$out"

mkdir -p "$SPOOL_ROOT/c-804/lifetime" && echo "restart seed" >"$SPOOL_ROOT/c-804/lifetime/brief.md"
out="$(step "$CORE" "$T_TMP/one.md" c-804 SPAWN_DRY_RUN=0 SPAWN_REUSE_ID=1)"
hasnt "2. a respawn keeps its brief: no section" "Topic text" "$out"

out="$(step "$CORE" "$T_TMP/one.md" c-805 SPAWN_DRY_RUN=1)"
has "2. dry run: plans the topic text" "PLAN topictext" "$out"
check "2. dry run: writes nothing" [ ! -e "$SPOOL_ROOT/c-805" ]

# Control: the launcher before SPL-2107 (the topic-text call removed).
mkdir -p "$T_TMP/ctl"
cp "$T_SCRIPTS"/*.sh "$T_TMP/ctl/" && cp -r "$T_FEAT/lib" "$T_TMP/lib"
grep -v 'spawn_topic_text "\$MSGDIR"' "$CORE" >"$T_TMP/ctl/spawn-core.inc.sh"
check "control: the call is gone" sh -c "! grep -q 'spawn_topic_text \"\$MSGDIR\"' '$T_TMP/ctl/spawn-core.inc.sh'"
out="$(step "$T_TMP/ctl/spawn-core.inc.sh" "$T_TMP/one.md" c-806 SPAWN_DRY_RUN=0)"
has "control: the brief is still copied" "Owner topic https://ws1.example.com/t/$U1" "$out"
check "control: a brief with a link and the old launcher -> no topic text -> FAIL" sh -c "! printf '%s' \"\$1\" | grep -q 'Topic text'" _ "$out"

t_done
