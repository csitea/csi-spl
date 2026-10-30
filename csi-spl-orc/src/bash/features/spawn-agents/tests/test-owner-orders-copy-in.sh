#!/usr/bin/env bash
# The brief copy-in of spec 168 (part b, build row B2, SPL-4357; owner HUM-10
# poll 10af03a3 answer A): the owner's orders on a brief's paths are copied
# into it by the spawn, word for word, and into a task body by spool-send.
# Synthetic orders only (the real ledgers live outside git). Hermetic: own
# SPOOL_ROOT and ledger dir, a tmux stub, no hub.
#   1. a spawn dry run, a brief whose Repo: and paths match: PLAN owner-orders
#      1 copied, the preview carries the section with the text quoted; the
#      brief itself is unchanged (a dry run)
#   2. a brief whose paths match no order: 0 copied, nothing added
#   3. CONTROL: an empty ledger adds nothing; no ledger at all needs no
#      action, a ledger with no action to read it refuses
#   4. a malformed ledger refuses the spawn (exit 15, the claim released),
#      also for a brief with no Repo: line (every ledger is read);
#      CONTROL: the same briefs with the ledger fixed spawn
#   5. Repo: with no path = every active order of that repo; no Repo: line =
#      every ledger's active orders; a lifted order is never copied
#   6. a real spawn (tmux stub) appends the section to the brief and journals
#      owner_orders=1; the same brief spawned again gets nothing twice
#   7. the seed line: a brief with the section gets it, one without does not
#   8. spool-send --kind task with a Repo: line: the orders ride the body; a
#      malformed ledger refuses the send (exit 3, nothing written); a note
#      is never touched
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
command -v jq >/dev/null || { nok "jq is required"; t_done; exit 1; }
SW="$T_SCRIPTS/spawn-window.sh" SS="$T_SCRIPTS/spool-send.sh"
OD="$T_TMP/orders"; export OWNER_ORDER_DIR="$OD"
M1=11111111-aaaa-4bbb-8ccc-000000000001 M2=22222222-aaaa-4bbb-8ccc-000000000002
M3=33333333-aaaa-4bbb-8ccc-000000000003
HEAD='## Owner orders on these paths (copied by the spawn from the ledger; obey them word for word)'

# order <file> <id> <repo> <glob> <text>: one synthetic add line
order() {
  jq -n -c --arg o "$2" --arg r "$3" --arg p "$4" --arg t "$5" \
    '{op: "add", order: $o, repo: $r, paths: [$p], text: $t, source: "given", gate: "content",
      ts: "2026-10-29T15:46:10Z", owner: "HUM-10", topic: "", expires: "", note: "", by: "c-900", at: "2026-10-29T16:00:00Z"}' >>"$1"
}
ledgers() {
  rm -rf "$OD"; mkdir -p "$OD"
  order "$OD/repo-x.jsonl" "$M1" repo-x 'docs/runbooks/**' $'keep the runbook contents\nchange only the file structure'
  order "$OD/repo-x.jsonl" "$M2" repo-x 'src/app/*.py' 'never rename the entry module'
  order "$OD/repo-y.jsonl" "$M3" repo-y '**' 'bump the version on every push'
}
mkdir -p "$T_TMP/bin"
cat >"$T_TMP/bin/tmux" <<STUB
#!/usr/bin/env bash
while [ "\${1:-}" = -u ] || [ "\${1:-}" = -S ]; do [ "\$1" = -S ] && shift; shift; done
case "\${1:-}" in
  list-sessions) echo '\$1' ;;
  new-window) echo '%42' ;;
esac
exit 0
STUB
chmod +x "$T_TMP/bin/tmux"
# sw <title> <brief> [VAR=value...]: one spawn, its rc in $T_TMP/rc
sw() {
  local title="$1" brief="$2"; shift 2
  env -u SPAWN_REQUESTER -u LANE_FLEET -u SPAWN_BOX -u SPAWN_REUSE_ID PATH="$T_TMP/bin:$PATH" SPOOL_SESSION= \
    SPOOL_BIN=/bin/true SPAWN_START_CHECK=0 SPOOL_SHOW_PANE=0 SPAWN_BOX_PICK=0 SPAWN_SKIP_WORKTREE=1 "$@" \
    bash "$SW" claude "$title" "$T_TMP" "$brief" >"$T_TMP/so" 2>&1
  echo $? >"$T_TMP/rc"
}
dry() { sw "$1" "$2" SPAWN_DRY_RUN=1 SPAWN_OWNER_ORDERS_PREVIEW="$T_TMP/preview" "${@:3}"; }
brief() {  # <file> <lines>...
  printf '%s\n' "# Lane brief: a test lane" "Issue: SPL-1" "$@" >"$1"
}

# ---- 1. a matching brief gets the section -----------------------------------
ledgers
brief "$T_TMP/b1.md" "Repo: repo-x" "Move \`docs/runbooks/deploy.md\` under a new folder."
cp "$T_TMP/b1.md" "$T_TMP/b1.orig"
dry c-901 "$T_TMP/b1.md"
eq "1. dry run: exit 0" 0 "$(cat "$T_TMP/rc")"
has "1. PLAN owner-orders 1 copied" "PLAN owner-orders 1 copied -> $T_TMP/b1.md" "$(cat "$T_TMP/so")"
has "1. the preview carries the section heading" "$HEAD" "$(cat "$T_TMP/preview")"
has "1. ... the order line (id, ts, owner, repo, gate, source, paths)" \
  "- $M1 (2026-10-29T15:46:10Z, HUM-10, repo repo-x, gate content, source given), paths docs/runbooks/**:" "$(cat "$T_TMP/preview")"
has "1. ... every text line quoted, word for word" $'  > keep the runbook contents\n  > change only the file structure' "$(cat "$T_TMP/preview")"
hasnt "1. ... not the order on other paths" "$M2" "$(cat "$T_TMP/preview")"
check "1. the brief itself is unchanged (dry run)" cmp -s "$T_TMP/b1.md" "$T_TMP/b1.orig"
hasnt "1. no order text in the spawn's output" "keep the runbook" "$(cat "$T_TMP/so")"

# ---- 2. a brief on other paths gets nothing ---------------------------------
brief "$T_TMP/b2.md" "Repo: repo-x" "Fix \`lib/util/strings.py\`."
dry c-902 "$T_TMP/b2.md"
has "2. non-matching paths: PLAN owner-orders 0 copied" "PLAN owner-orders 0 copied" "$(cat "$T_TMP/so")"
check "2. ... the preview is the brief, nothing added" cmp -s "$T_TMP/preview" "$T_TMP/b2.md"

# ---- 3. CONTROL: an empty ledger adds nothing --------------------------------
rm -rf "$OD"; mkdir -p "$OD"; : >"$OD/repo-x.jsonl"
dry c-903 "$T_TMP/b1.md"
has "3. CONTROL empty ledger: 0 copied" "PLAN owner-orders 0 copied" "$(cat "$T_TMP/so")"
check "3. ... nothing added" cmp -s "$T_TMP/preview" "$T_TMP/b1.md"
rm -rf "$OD"
dry c-903 "$T_TMP/b1.md"
has "3. CONTROL no ledger dir at all: 0 copied" "PLAN owner-orders 0 copied" "$(cat "$T_TMP/so")"
dry c-903 "$T_TMP/b1.md" OO_FUNC=/nonexistent/spl-owner-order.func.sh
has "3. no ledger: the action is not even needed (0 copied)" "PLAN owner-orders 0 copied" "$(cat "$T_TMP/so")"
ledgers
dry c-903 "$T_TMP/b1.md" OO_FUNC=/nonexistent/spl-owner-order.func.sh
eq "3. CONTROL a ledger but no action to read it: refused, exit 15" 15 "$(cat "$T_TMP/rc")"

# ---- 4. a malformed ledger refuses the spawn ---------------------------------
ledgers; echo '{"op": "add", broken' >>"$OD/repo-x.jsonl"
sw c-904 "$T_TMP/b1.md"
eq "4. malformed ledger: the spawn is refused, exit 15" 15 "$(cat "$T_TMP/rc")"
has "4. ... REFUSED, naming the ledger" "REFUSED c-904: the owner-order ledger refused" "$(cat "$T_TMP/so")"
has "4. ... the ledger file is named" "$OD/repo-x.jsonl" "$(cat "$T_TMP/so")"
check "4. ... the claim is released" test ! -e "$SPOOL_ROOT/c-904"
check "4. ... the brief is untouched" cmp -s "$T_TMP/b1.md" "$T_TMP/b1.orig"
brief "$T_TMP/b4.md" "Tidy whatever needs it."
sw c-904 "$T_TMP/b4.md" SPAWN_DRY_RUN=1
eq "4. no Repo: line (every ledger is read), one malformed: refused, exit 15" 15 "$(cat "$T_TMP/rc")"
has "4. ... naming that ledger" "the repo-x ledger ($OD/repo-x.jsonl) refused (list exit 2)" "$(cat "$T_TMP/so")"
ledgers
dry c-904 "$T_TMP/b1.md"
eq "4. CONTROL the same brief, the ledger fixed: exit 0" 0 "$(cat "$T_TMP/rc")"
dry c-904 "$T_TMP/b4.md"
eq "4. CONTROL no Repo: line, every ledger fixed: exit 0" 0 "$(cat "$T_TMP/rc")"

# ---- 5. no path, no Repo:, lifted --------------------------------------------
brief "$T_TMP/b5.md" "Repo: repo-x" "Tidy the repository."
dry c-905 "$T_TMP/b5.md"
has "5. Repo: with no path: every active order of that repo (2)" "PLAN owner-orders 2 copied" "$(cat "$T_TMP/so")"
hasnt "5. ... none of another repo" "$M3" "$(cat "$T_TMP/preview")"
brief "$T_TMP/b5b.md" "Tidy whatever needs it."
dry c-905 "$T_TMP/b5b.md"
has "5. no Repo: line: every ledger's active orders (3)" "PLAN owner-orders 3 copied" "$(cat "$T_TMP/so")"
jq -n -c --arg o "$M2" '{op: "lift", order: $o, lift_msg: "44444444-aaaa-4bbb-8ccc-000000000004", source: "given", reason: "test", by: "c-900", at: "2026-10-30T00:00:00Z"}' >>"$OD/repo-x.jsonl"
dry c-905 "$T_TMP/b5.md"
has "5. a lifted order is not copied (1 left)" "PLAN owner-orders 1 copied" "$(cat "$T_TMP/so")"
hasnt "5. ... the lifted id is absent" "$M2" "$(cat "$T_TMP/preview")"
brief "$T_TMP/b5c.md" "Repo: repo-x" "Repo: repo-y" "Edit \`docs/runbooks/a.md\`."
ledgers
dry c-905 "$T_TMP/b5c.md"
has "5. two Repo: lines: each repo matched (repo-x 1 + repo-y ** 1)" "PLAN owner-orders 2 copied" "$(cat "$T_TMP/so")"

# ---- 6. a real spawn appends; again adds nothing -----------------------------
ledgers; mkdir -p "$SPOOL_ROOT/dispatch"
cp "$T_TMP/b1.orig" "$T_TMP/b6.md"
sw c-906 "$T_TMP/b6.md"
eq "6. real spawn (tmux stub): exit 0" 0 "$(cat "$T_TMP/rc")"
has "6. ... 'c-906 %42' on stdout" "c-906 %42" "$(cat "$T_TMP/so")"
eq "6. ... the brief carries the section once" 1 "$(grep -cxF "$HEAD" "$T_TMP/b6.md")"
has "6. ... with the order" "  > keep the runbook contents" "$(cat "$T_TMP/b6.md")"
J="$SPOOL_ROOT/dispatch/attempts.tsv"
# shellcheck disable=SC2016 # awk programs
check "6. ... the journal row says owner_orders=1" awk -F'\t' '$4 == "c-906" && $7 == "spawn-window" && $8 == "owner_orders=1" { ok = 1 } END { exit !ok }' "$J"
sw c-907 "$T_TMP/b6.md"
eq "6. the same brief spawned again: exit 0" 0 "$(cat "$T_TMP/rc")"
eq "6. ... still one section (nothing twice)" 1 "$(grep -cxF "$HEAD" "$T_TMP/b6.md")"
has "6. ... the plan says it already carries it" "0 copied -> $T_TMP/b6.md (the brief already carries the section)" "$(cat "$T_TMP/so")"
# shellcheck disable=SC2016 # an awk program
check "6. ... journal owner_orders=0" awk -F'\t' '$4 == "c-907" && $8 == "owner_orders=0" { ok = 1 } END { exit !ok }' "$J"

# ---- 7. the seed line ---------------------------------------------------------
git init -q "$T_TMP/repo" && git -C "$T_TMP/repo" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
seed() {  # <brief> -> the rendered seed
  rm -rf "$T_TMP/plan"; mkdir -p "$T_TMP/plan"
  SPAWN_DRY_RUN=1 SPAWN_PLAN_DIR="$T_TMP/plan" SPOOL_BIN=/bin/true SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>' \
    bash "$T_SCRIPTS/spawn-claude.sh" c-908 "$T_TMP/repo" "$1" fix-it >/dev/null 2>&1
  cat "$T_TMP/plan/prompt.txt" 2>/dev/null
}
s7="$(seed "$T_TMP/b6.md")"
has "7. a brief with the section: the seed says the orders rank first" "Your brief carries OWNER ORDERS" "$s7"
s7="$(seed "$T_TMP/b1.orig")"
check "7. CONTROL the seed rendered" test -n "$s7"
hasnt "7. CONTROL a brief without it: no such line" "OWNER ORDERS" "$s7"

# ---- 8. spool-send --kind task -------------------------------------------------
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
# one recipient per task: a lane takes one topic (exit 3 too, spool-send.sh)
for id in c-782 c-783 c-784 c-785; do
  printf '%s\tclaude\t%%0\t/x\t20260101T000000Z\n' "$id" >>"$SPOOL_ROOT/registry.tsv"
  mkdir -p "$SPOOL_ROOT/$id/inbox"
done
last_body() { find "$SPOOL_ROOT/${1:-c-782}/inbox" -maxdepth 1 -name '*.json' -newer "$T_TMP/mark" -exec jq -r .body {} \; 2>/dev/null; }
ledgers; : >"$T_TMP/mark"
bash "$SS" --from c-781 --to c-782 --kind task --body $'Repo: repo-x\nEdit docs/runbooks/a.md' --no-poke --no-ask >/dev/null 2>"$T_TMP/se"
eq "8. task with Repo: sent, exit 0" 0 "$?"
has "8. ... the body carries the section" "$HEAD" "$(last_body)"
has "8. ... with the order's words" "  > change only the file structure" "$(last_body)"
has "8. ... stderr counts it" "owner-orders: 1 copied into the task body" "$(cat "$T_TMP/se")"
: >"$T_TMP/mark"; sleep 1
bash "$SS" --from c-781 --to c-783 --kind note --body $'Repo: repo-x\nEdit docs/runbooks/a.md' --no-poke --no-ask >/dev/null 2>&1
eq "8. CONTROL a note: sent" 1 "$(last_body c-783 | grep -c 'Edit docs/runbooks/a.md')"
hasnt "8. CONTROL ... and never touched" "$HEAD" "$(last_body c-783)"
echo 'not json' >>"$OD/repo-x.jsonl"; : >"$T_TMP/mark"; sleep 1
err="$(bash "$SS" --from c-781 --to c-784 --kind task --body $'Repo: repo-x\nEdit docs/runbooks/a.md' --no-poke --no-ask 2>&1 >/dev/null)"; rc=$?
eq "8. malformed ledger: the task send is refused, exit 3" 3 "$rc"
has "8. ... saying why" "the owner-order ledger refused" "$err"
eq "8. ... nothing written" 0 "$(find "$SPOOL_ROOT" -name '*.json' -newer "$T_TMP/mark" | wc -l)"
bash "$SS" --from c-781 --to c-785 --kind task --body 'no repo line here' --no-poke --no-ask >/dev/null 2>&1
eq "8. CONTROL a task without Repo: still goes (the ledger is not read)" 0 "$?"

t_done
