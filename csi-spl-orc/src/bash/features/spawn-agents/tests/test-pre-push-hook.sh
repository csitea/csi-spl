#!/usr/bin/env bash
# test-pre-push-hook.sh (SPL-1252) — the deploy-gate pre-push hook and its
# per-worktree installer, with a STUBBED gate so nothing heavy runs.
#   HOOK
#     1. gate passes            -> exit 0, PASS logged
#     2. gate fails             -> exit 1 (REFUSE)
#     3. SPL_PREPUSH_OVERRIDE=1  -> exit 0 even when the full gate would fail, audited;
#        it still runs the cheap parts (PRE_PUSH_ONLY=override) and exit 1 when THEY fail
#     4. the hook asks the gate to skip a tree it already passed whole
#        (PRE_PUSH_SKIP_PASSED=1 + the tree-pass record; the gate's test is
#        check-pre-push-tree-pass.tst.sh); the override never does (=0), and
#        the old index-keyed pre-push.green stamp is neither read nor written
#     5. not the spool tree      -> exit 0 (fail-open), never blocks a foreign repo
#    13. the gate gets the per-part log, the verdict cache and tier=fast
#    14. a STALE shared checkout: the lane's own hook runs (trampoline)
#    15. the run and refusal text give SPL_PREPUSH_OVERRIDE to the owner's go only
#    16. SPL-5163: real pushes through git: wip-only and no-ref pushes are never
#        gated, the ref lines are logged; mixed, master and malformed stay gated;
#        the non-ff, R7 and owner-order guards still come first (red controls)
#   INSTALLER
#     6. installs core.hooksPath for ONE worktree only, others untouched
#     7. idempotent (second run still 0)
#     8. a non-git dir           -> exit 2
set -uo pipefail
# Defensive git-env scrub: this test creates commits in throwaway repos; a leaked
# GIT_DIR/GIT_INDEX_FILE (e.g. when run through the pre-push hook) would override
# "git -C" and land commits on the real pushing branch. The hook scrubs them; do
# it here too so the test is safe however it is invoked.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
HOOK="$(cd "$HERE/../hooks" && pwd)/pre-push"
INSTALL="$SCRIPTS/install-pre-push-hook.sh"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1 ${2:+:: $2}"; fails=$((fails + 1)); }
eq()   { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT

# --- a throwaway spool-shaped repo with a STUB gate --------------------------
REPO="$ROOT/repo"
mkdir -p "$REPO/csi-spl-iac"
cat >"$REPO/csi-spl-iac/run" <<'EOF'
#!/usr/bin/env bash
# stub ./run: the full gate fails iff STUB_FAIL=1, the override's cheap parts
# (PRE_PUSH_ONLY=override) iff STUB_CHEAP_FAIL=1; args (-a do_check_pre_push) ignored
[ -n "${STUB_ONLY_LOG:-}" ] && echo "only=${PRE_PUSH_ONLY:-}" >>"$STUB_ONLY_LOG"
[ -n "${STUB_SKIP_LOG:-}" ] && echo "only=${PRE_PUSH_ONLY:-} skip=${PRE_PUSH_SKIP_PASSED:-} pass=${PRE_PUSH_PASS:-}" >>"$STUB_SKIP_LOG"
if [ "${PRE_PUSH_ONLY:-}" = override ]; then [ "${STUB_CHEAP_FAIL:-0}" = 1 ] && exit 7; exit 0; fi
[ "${STUB_FAIL:-0}" = 1 ] && exit 7
exit 0
EOF
chmod +x "$REPO/csi-spl-iac/run"
git -C "$REPO" init -q
echo seed >"$REPO/seed"; git -C "$REPO" add -A; git -C "$REPO" commit -qm seed

# git pipes the ref lines into the hook; its `cat` must never read this test's
# own stdin (an idle terminal hangs it forever, SPL-2458). Every hook call gets
# them explicitly: a push of a new lane branch (not trunk, not wip/*), so the
# gate runs as usual and the non-ff guard has nothing to refuse.
ZERO=0000000000000000000000000000000000000000
lane_refs() {  # <repo> -> one ref line for a push of its HEAD to a new branch
  printf 'refs/heads/lane %s refs/heads/lane %s\n' "$(git -C "$1" rev-parse HEAD 2>/dev/null)" "$ZERO"
}

# Run the hook with CWD at the repo top (as git does), an isolated log/stamp dir.
run_hook() {  # <logdir> [env assignments...]
  local ld="$1"; shift
  ( cd "$REPO" && lane_refs "$REPO" | env "$@" SPL_PREPUSH_LOG_DIR="$ld" bash "$HOOK" origin file://x >/dev/null 2>&1 )
}

# 1. gate passes
L="$ROOT/l1"; run_hook "$L"; eq "1. gate passes -> exit 0" 0 "$?"
grep -q '^PASS ' <(sed 's/^[^ ]* [^ ]* //' "$L/pre-push.log") 2>/dev/null \
  && pass "1. logged PASS" || fail "1. logged PASS"

# 2. gate fails
L="$ROOT/l2"; run_hook "$L" STUB_FAIL=1; eq "2. gate fails -> exit 1 (REFUSE)" 1 "$?"
grep -q 'REFUSE' "$L/pre-push.log" && pass "2. logged REFUSE" || fail "2. logged REFUSE"

# 3. override beats a failing gate
L="$ROOT/l3"; run_hook "$L" STUB_FAIL=1 SPL_PREPUSH_OVERRIDE=1; eq "3. override -> exit 0" 0 "$?"
grep -q 'OVERRIDE' "$L/pre-push.log" && pass "3. logged OVERRIDE" || fail "3. logged OVERRIDE"
L="$ROOT/l3b"; run_hook "$L" STUB_FAIL=1 SPL_PREPUSH_OVERRIDE=1 STUB_ONLY_LOG="$ROOT/l3b.only"
eq "3. ... the override still ran the cheap parts, and only those" "only=override" "$(cat "$ROOT/l3b.only" 2>/dev/null)"
L="$ROOT/l3c"; run_hook "$L" STUB_CHEAP_FAIL=1 SPL_PREPUSH_OVERRIDE=1; eq "3. override + a failing cheap part (duplicate migration) -> exit 1" 1 "$?"
grep -q 'REFUSE .*SPL_PREPUSH_OVERRIDE=1' "$L/pre-push.log" && pass "3. ... logged REFUSE under the override" || fail "3. ... logged REFUSE under the override" "$(cat "$L/pre-push.log" 2>/dev/null)"

# 4. the skip of an already-passed tree is the gate's (tree-pass record): the
#    hook asks for it, the override does not, and a failing gate is never
#    skipped by a stamp the hook wrote itself
L="$ROOT/l4"; run_hook "$L" STUB_SKIP_LOG="$ROOT/l4.skip"
eq "4. the hook asks the gate to skip a passed tree, with the record path" \
  "only= skip=1 pass=$L/pre-push.tree.pass" "$(cat "$ROOT/l4.skip" 2>/dev/null)"
run_hook "$L" SPL_PREPUSH_OVERRIDE=1 STUB_SKIP_LOG="$ROOT/l4.skipo"
eq "4. ... the override run never skips" "only=override skip=0 pass=$L/pre-push.tree.pass" "$(cat "$ROOT/l4.skipo" 2>/dev/null)"
run_hook "$L" STUB_FAIL=1; eq "4. CONTROL: same tree after a pass, gate now fails -> exit 1 (no hook-side stamp)" 1 "$?"
[ ! -e "$L/pre-push.green" ] && pass "4. ... and the hook wrote no pre-push.green stamp" || fail "4. ... and the hook wrote no pre-push.green stamp"

# 5. a non-spool repo (no csi-spl-iac/run) -> fail-open
NS="$ROOT/nonspool"; git -C . init -q "$NS" >/dev/null 2>&1 || git init -q "$NS"
git -C "$NS" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
L="$ROOT/l5"
( cd "$NS" && lane_refs "$NS" | env SPL_PREPUSH_LOG_DIR="$L" bash "$HOOK" origin file://x >/dev/null 2>&1 )
eq "5. not the spool tree -> exit 0 (fail-open)" 0 "$?"

# --- installer: config-free common-hooks-dir install -------------------------
# It installs ONE hook in the common hooks dir and writes NO git config, so the
# whole extensions.worktreeConfig / core.bare landmine is gone.
MAIN="$ROOT/main"
git -C . init -q "$MAIN" >/dev/null 2>&1 || git init -q "$MAIN"
git -C "$MAIN" commit -q --allow-empty -m init
mkdir -p "$MAIN/csi-spl-orc/src/bash/features/spawn-agents/hooks"
install -m 0755 "$HOOK" "$MAIN/csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push"
git -C "$MAIN" worktree add -q "$ROOT/wtA" -b wtA >/dev/null 2>&1
git -C "$MAIN" worktree add -q "$ROOT/wtB" -b wtB >/dev/null 2>&1

bash "$INSTALL" "$ROOT/wtA" >/dev/null 2>&1; eq "6. installer on wtA -> exit 0" 0 "$?"
# the hook lands in the COMMON hooks dir as a COPY of the trampoline (never a
# symlink into the shared checkout, which is fetch-only and goes stale)
dest="$MAIN/.git/hooks/pre-push"
{ [ -f "$dest" ] && [ ! -L "$dest" ] && [ -x "$dest" ] && cmp -s "$dest" "$HERE/../hooks/pre-push-trampoline"; } \
  && pass "6. common hooks dir has the trampoline (a copy, executable)" || fail "6. common hooks dir has the trampoline" "$(ls -l "$dest" 2>&1)"
# every linked worktree resolves hooks to that same common dir
eq "6. wtA resolves hooks to the common dir" "$MAIN/.git/hooks" "$(git -C "$ROOT/wtA" rev-parse --git-path hooks 2>/dev/null)"

# 7. CONTROL: the installer writes NO git config (no worktreeConfig, no
#    core.bare / core.worktree churn) -- the poison bug class is impossible.
eq "7. installer does NOT enable extensions.worktreeConfig" "" \
  "$(git config -f "$MAIN/.git/config" --get extensions.worktreeConfig 2>/dev/null)"
eq "7. installer leaves no core.worktree in the common config" "" \
  "$(git config -f "$MAIN/.git/config" --get core.worktree 2>/dev/null)"
[ ! -e "$MAIN/.git/config.worktree" ] && pass "7. no per-worktree config.worktree written" || fail "7. no per-worktree config.worktree written"

bash "$INSTALL" "$ROOT/wtA" >/dev/null 2>&1; eq "8. installer is idempotent" 0 "$?"
bash "$INSTALL" "$ROOT/not-a-repo-$$" >/dev/null 2>&1; eq "8. non-git dir -> exit 2" 2 "$?"

# 9. CONTROL: a repo carrying core.bare=true in its COMMON config is UNAFFECTED
#    by the installer -- it never enables worktreeConfig, so it cannot flip the
#    main checkout to bare. The main stays exactly as it was.
MB="$ROOT/barelm"
git -C . init -q "$MB" >/dev/null 2>&1 || git init -q "$MB"
git -C "$MB" commit -q --allow-empty -m init
mkdir -p "$MB/csi-spl-orc/src/bash/features/spawn-agents/hooks"
install -m 0755 "$HOOK" "$MB/csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push"
git -C "$MB" worktree add -q "$ROOT/wtLM" -b wtLM >/dev/null 2>&1
bash "$INSTALL" "$ROOT/wtLM" >/dev/null 2>&1; eq "9. installer on any repo -> exit 0" 0 "$?"
eq "9. it did NOT enable worktreeConfig (no bare landmine)" "" \
  "$(git config -f "$MB/.git/config" --get extensions.worktreeConfig 2>/dev/null)"
[ -e "$MB/.git/hooks/pre-push" ] && pass "9. the common hook is installed" || fail "9. the common hook is installed"

# 11. the hook REFUSES when the common config is poisoned with core.worktree
git -C "$REPO" config core.worktree /somewhere/else
( cd "$REPO" && lane_refs "$REPO" | bash "$HOOK" origin file://x >/dev/null 2>&1 ); eq "11. poisoned common core.worktree -> hook refuses (exit 1)" 1 "$?"
# ... but the override still lets a fixer through
( cd "$REPO" && lane_refs "$REPO" | env SPL_PREPUSH_OVERRIDE=1 bash "$HOOK" origin file://x >/dev/null 2>&1 ); eq "11. ... override still escapes the poison" 0 "$?"
git -C "$REPO" config --unset-all core.worktree 2>/dev/null || true

# 12. REGRESSION (git-env leak): git invokes the hook with GIT_DIR/GIT_INDEX_FILE
#     set. A gate that creates commits in a throwaway repo must NOT land them on
#     the PUSHING branch, and must not set core.bare on it -- the hook scrubs
#     git's env before the gate. Without the scrub, git -C in the gate is
#     overridden by GIT_DIR and hits the pushing repo (the 2026-09-30 junk
#     "head/pinned/tip" commits + core.bare=true).
GR="$ROOT/leakrepo"
git init -q "$GR"
git -C "$GR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m real1
git -C "$GR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m real2
before="$(git -C "$GR" rev-parse HEAD)"
mkdir -p "$GR/csi-spl-iac"
cat >"$GR/csi-spl-iac/run" <<'EOF'
#!/usr/bin/env bash
# a gate that commits into its OWN throwaway repo via git -C, and sets core.bare
# there. If git's env leaked from the hook, -C is overridden and this lands on
# the PUSHING repo instead -- which the assertions below catch.
tmp="$(mktemp -d)"; git init -q "$tmp"
git -C "$tmp" -c user.email=t@example.com -c user.name=t commit --allow-empty -m throwaway 2>/dev/null || true
git -C "$tmp" config core.bare true 2>/dev/null || true
rm -rf "$tmp"
exit 0
EOF
chmod +x "$GR/csi-spl-iac/run"
( cd "$GR" && lane_refs "$GR" | env GIT_DIR="$GR/.git" GIT_INDEX_FILE="$GR/.git/index" SPL_PREPUSH_LOG_DIR="$ROOT/l12" \
    bash "$HOOK" origin file://x >/dev/null 2>&1 )
eq "12. gate through the hook leaves the pushing branch HEAD untouched" "$before" "$(git -C "$GR" rev-parse HEAD)"
[ "$(git -C "$GR" config --get core.bare 2>/dev/null)" != true ] \
  && pass "12. ... and does not flip core.bare=true on the pushing repo" \
  || fail "12. ... and does not flip core.bare=true on the pushing repo"

# 13. the hook hands the gate its per-part log, its verdict cache and the FAST
#     tier (CLE-77824), and records its own wall time on the verdict line.
#     A fresh repo: case 11 leaves $REPO's config poisoned on purpose.
R13="$ROOT/repo13"; mkdir -p "$R13/csi-spl-iac"
cat >"$R13/csi-spl-iac/run" <<'STUB'
#!/usr/bin/env bash
printf 'log=%s cache=%s tier=%s mode=%s\n' "${PRE_PUSH_LOG:-}" "${PRE_PUSH_CACHE:-}" "${PRE_PUSH_TIER:-}" "${PRE_PUSH_MODE:-}" >"$SEEN"
exit 0
STUB
chmod +x "$R13/csi-spl-iac/run"
git init -q "$R13"; git -C "$R13" add -A; git -C "$R13" commit -qm c13
L="$ROOT/l13"
( cd "$R13" && lane_refs "$R13" | env SEEN="$ROOT/seen13" SPL_PREPUSH_LOG_DIR="$L" bash "$HOOK" origin file://x >/dev/null 2>&1 )
eq "13. gate passes -> exit 0" 0 "$?"
eq "13. the gate got the log, the cache, tier=fast and mode=fast" \
  "log=$L/pre-push.log cache=$L/pre-push.parts.green tier=fast mode=fast" "$(cat "$ROOT/seen13" 2>/dev/null)"
grep -q 'PASS .* secs=[0-9]*s' "$L/pre-push.log" \
  && pass "13. the PASS line carries the hook's wall time" || fail "13. the PASS line carries the hook's wall time" "$(cat "$L/pre-push.log")"

# 14. STALE SHARED CHECKOUT (CLE-77824): the main checkout carries an OLD hook,
#     a lane worktree carries the NEW one. A push from the lane must run the
#     lane's hook; a push from the main checkout runs the main's; a repo with no
#     hook at all lets the push through. Stub hooks record which one ran.
ST="$ROOT/stale"; git init -q "$ST"
HP="csi-spl-orc/src/bash/features/spawn-agents/hooks"
mkdir -p "$ST/$HP"
printf '#!/usr/bin/env bash\necho OLD >"$RAN"; read -r line; echo "$1 $line" >>"$RAN"; exit 0\n' >"$ST/$HP/pre-push"
chmod +x "$ST/$HP/pre-push"
git -C "$ST" add -A; git -C "$ST" commit -qm old-hook
git -C "$ST" worktree add -q "$ROOT/stale-lane" -b lane >/dev/null 2>&1
printf '#!/usr/bin/env bash\necho NEW >"$RAN"; read -r line; echo "$1 $line" >>"$RAN"; exit 0\n' >"$ROOT/stale-lane/$HP/pre-push"
git -C "$ROOT/stale-lane" commit -qam new-hook
bash "$INSTALL" "$ROOT/stale-lane" >/dev/null 2>&1; eq "14. installer from a lane -> exit 0" 0 "$?"
( cd "$ROOT/stale-lane" && echo "refs/heads/lane abc refs/heads/master def" | RAN="$ROOT/ran14" "$ST/.git/hooks/pre-push" origin file://x )
eq "14. a push from the lane runs the LANE's hook, not the stale shared one" NEW "$(head -1 "$ROOT/ran14" 2>/dev/null)"
eq "14. ... with git's args and stdin passed through" "origin refs/heads/lane abc refs/heads/master def" "$(sed -n 2p "$ROOT/ran14" 2>/dev/null)"
( cd "$ST" && echo x | RAN="$ROOT/ran14b" "$ST/.git/hooks/pre-push" origin file://x )
eq "14. a push from the main checkout runs the main's hook" OLD "$(head -1 "$ROOT/ran14b" 2>/dev/null)"
NH="$ROOT/nohook"; git init -q "$NH"; git -C "$NH" commit -q --allow-empty -m x
( cd "$NH" && echo x | RAN="$ROOT/ran14c" bash "$HERE/../hooks/pre-push-trampoline" origin file://x ); eq "14. no spool hook anywhere -> exit 0" 0 "$?"
[ ! -e "$ROOT/ran14c" ] && pass "14. ... and nothing ran" || fail "14. ... and nothing ran"
# installing over an old SYMLINK replaces the link and never writes through it
ln -sfn "$ST/$HP/pre-push" "$ST/.git/hooks/pre-push"; before="$(cat "$ST/$HP/pre-push")"
bash "$INSTALL" "$ROOT/stale-lane" >/dev/null 2>&1
{ [ ! -L "$ST/.git/hooks/pre-push" ] && [ "$(cat "$ST/$HP/pre-push")" = "$before" ]; } \
  && pass "14. an old symlink is replaced, its target untouched" || fail "14. an old symlink is replaced, its target untouched"

# 15. SPL-3657, fleet-rules-index.md section 2 (never force-push master): the override only
#     on the owner's go for that one push, never an agent's. The hook printed
#     "Fix it, or override once with ..." to an agent at the very moment its
#     push was refused. Every sentence of the run and refusal text that names
#     the override must name the owner's go or forbid it. Control: the old text.
override_ok() {  # TEXT -> 0 when every sentence naming the override names the owner's go or a never
  local s; while IFS= read -r s; do
    case "$s" in *SPL_PREPUSH_OVERRIDE*) case "$s" in *"owner's go"*|*"does not skip"*) ;; *) return 1 ;; esac ;; esac
  done < <(printf '%s\n' "$1" | sed 's/\. /.\n/g')
}
R15="$ROOT/repo15"; mkdir -p "$R15/csi-spl-iac"  # a fresh repo: case 11 poisoned $REPO's config
cp "$REPO/csi-spl-iac/run" "$R15/csi-spl-iac/run"
git init -q "$R15"; git -C "$R15" add -A; git -C "$R15" commit -qm c15
hook_text() {  # <hook> <logdir> [env...] -> the hook's stderr
  local h="$1" ld="$2"; shift 2
  mkdir -p "$ld"
  ( cd "$R15" && lane_refs "$R15" | env "$@" SPL_PREPUSH_LOG_DIR="$ld" bash "$h" origin file://x >/dev/null 2>"$ld/stderr" )
  cat "$ld/stderr"
}
t15p="$(hook_text "$HOOK" "$ROOT/l15p")"; t15f="$(hook_text "$HOOK" "$ROOT/l15f" STUB_FAIL=1)"
case "$t15f" in *"REFUSED -- the deploy-gate failed"*) pass "15. the refusal text was rendered" ;; *) fail "15. the refusal text was rendered" "$t15f" ;; esac
case "$t15f" in *"rebase onto origin/master, re-test and push again"*) pass "15. ... it says fetch, rebase, re-test" ;; *) fail "15. ... it says fetch, rebase, re-test" "$t15f" ;; esac
override_ok "$t15p" && pass "15. the run line gives the override to the owner's go only" || fail "15. the run line gives the override to the owner's go only" "$t15p"
override_ok "$t15f" && pass "15. the refusal gives the override to the owner's go only" || fail "15. the refusal gives the override to the owner's go only" "$t15f"
OHOOK="$ROOT/old-pre-push"
OLD_RUN="Override once with 'SPL_PREPUSH_OVERRIDE=1 git push …'." OLD_FIX="Fix it, or override once with 'SPL_PREPUSH_OVERRIDE=1 git push …' (audited in \$_pp_log)." \
  python3 - "$HOOK" "$OHOOK" <<'PY2'
import os, sys
s = open(sys.argv[1], encoding="utf-8").read()
s = s.replace("SPL_PREPUSH_OVERRIDE=1 only on the owner's go for that one push, never an agent's.\" >&2\ntree=", os.environ["OLD_RUN"] + "\" >&2\ntree=")
s = s.replace("Fix it, fetch, rebase onto origin/master, re-test and push again (log: $_pp_log). SPL_PREPUSH_OVERRIDE=1 only on the owner's go for that one push, never an agent's.", os.environ["OLD_FIX"])
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY2
o15p="$(hook_text "$OHOOK" "$ROOT/l15op")"; o15f="$(hook_text "$OHOOK" "$ROOT/l15of" STUB_FAIL=1)"
case "$o15f" in *"Fix it, or override once"*) pass "15. control: the old hook renders the old refusal" ;; *) fail "15. control: the old hook renders the old refusal" "$o15f" ;; esac
override_ok "$o15p" && fail "15. control (old run line) -> FAIL" "$o15p" || pass "15. control (old run line) -> FAIL"
override_ok "$o15f" && fail "15. control (old refusal) -> FAIL" "$o15f" || pass "15. control (old refusal) -> FAIL"

# 16. SPL-5163: git runs the hook even when it dropped every ref, with EMPTY
#     stdin (a stale lease, an up to date ref): that ran the whole gate. Real
#     pushes through git, a bare remote and a gate that records its run.
R16="$ROOT/r16"; git init -q --bare "$R16/o.git"; git clone -q "$R16/o.git" "$R16/c" 2>/dev/null
mkdir -p "$R16/c/csi-spl-iac" "$R16/hk"
printf '#!/usr/bin/env bash\necho ran >>"$GATE"\nexit 0\n' >"$R16/c/csi-spl-iac/run"; chmod +x "$R16/c/csi-spl-iac/run"
git -C "$R16/c" add -A; git -C "$R16/c" commit -qm s16; git -C "$R16/c" push -q --no-verify origin HEAD:refs/heads/master
git -C "$R16/c" config core.hooksPath "$R16/hk"
A16="$(git -C "$R16/c" rev-parse HEAD)"
B16="$(git -C "$R16/c" commit-tree "$A16^{tree}" -p "$A16" -m b)"
C16="$(git -C "$R16/c" commit-tree "$A16^{tree}" -p "$B16" -m c)"
W16=refs/heads/wip/c-999-x
push16() {  # <hook> <logdir> <git push args...> -> the push's rc; the gate records in <logdir>/gate
  local h="$1" ld="$2"; shift 2
  mkdir -p "$ld"; install -m 0755 "$h" "$R16/hk/pre-push"
  GATE="$ld/gate" SPL_PREPUSH_LOG_DIR="$ld" git -C "$R16/c" push -q origin "$@" >/dev/null 2>&1
}
gated16() { [ -s "$1/gate" ] && echo gated || echo no; }
logged16() { grep -c "$2" "$1/pre-push.log" 2>/dev/null; }
L="$ROOT/l16a"; push16 "$HOOK" "$L" --force-with-lease="$W16:" "$A16:$W16"; eq "16a. new wip ref, empty expect -> pushed" 0 "$?"
eq "16a. ... not gated" no "$(gated16 "$L")"; eq "16a. ... SKIP-WIP" 1 "$(logged16 "$L" ' SKIP-WIP ')"
grep -q "REFS .* -- $W16 000000000000..${A16:0:12}; " "$L/pre-push.log" && pass "16a. ... the ref line is logged, 12-char shas" || fail "16a. ... the ref line is logged, 12-char shas" "$(cat "$L/pre-push.log")"
L="$ROOT/l16b"; push16 "$HOOK" "$L" --force-with-lease="$W16:$A16" "$B16:$W16"; eq "16b. wip update, right lease -> pushed" 0 "$?"
eq "16b. ... not gated" no "$(gated16 "$L")"
L="$ROOT/l16c"; push16 "$HOOK" "$L" --force-with-lease="$W16:" "$C16:$W16"; eq "16c. existing wip ref, empty expect -> git rejects the stale lease" 1 "$?"
eq "16c. ... not gated" no "$(gated16 "$L")"; eq "16c. ... SKIP-NOREFS" 1 "$(logged16 "$L" ' SKIP-NOREFS ')"; eq "16c. ... REFS none" 1 "$(logged16 "$L" 'REFS .* -- none$')"
eq "16c. ... the remote ref did not move" "$B16" "$(git -C "$R16/o.git" rev-parse "$W16")"
L="$ROOT/l16d"; push16 "$HOOK" "$L" --force-with-lease="$W16:$B16" "$B16:$W16"; eq "16d. wip up to date -> exit 0" 0 "$?"
eq "16d. ... not gated" no "$(gated16 "$L")"; eq "16d. ... SKIP-NOREFS" 1 "$(logged16 "$L" ' SKIP-NOREFS ')"
L="$ROOT/l16e"; push16 "$HOOK" "$L" "$B16:refs/heads/lane16" "$C16:refs/heads/wip/c-999-y"; eq "16e. mixed wip + lane ref -> pushed" 0 "$?"
eq "16e. ... GATED" gated "$(gated16 "$L")"; eq "16e. ... no SKIP line" 0 "$(logged16 "$L" ' SKIP-')"
L="$ROOT/l16f"; push16 "$HOOK" "$L" "$B16:refs/heads/master"; eq "16f. master push -> pushed" 0 "$?"
eq "16f. ... GATED" gated "$(gated16 "$L")"

# The rest by hand on the hook's stdin; the guards are stubbed in the pushing
# tree's own files, as the hook sources them.
R16G="$ROOT/r16g"; mkdir -p "$R16G/csi-spl-iac" "$R16G/csi-spl-orc/src/bash/run" "$R16G/csi-spl-orc/src/bash/features/spawn-agents/lib"
cp "$R16/c/csi-spl-iac/run" "$R16G/csi-spl-iac/run"
cat >"$R16G/csi-spl-orc/src/bash/run/spl-push-master.func.sh" <<'EOF'
_spl_push_master_unreviewed() { [ "${STUB_R7:-0}" = 1 ] && echo "abc r7 row"; return 0; }
EOF
cat >"$R16G/csi-spl-orc/src/bash/features/spawn-agents/lib/owner-order-guard.inc.sh" <<'EOF'
oog_pre_push() { cat >/dev/null; if [ "${STUB_OOG:-0}" = 1 ]; then echo "owner-orders: REFUSED stub"; return 1; fi; return 0; }
EOF
git init -q "$R16G"; git -C "$R16G" add -A; git -C "$R16G" commit -qm a; git -C "$R16G" commit -q --allow-empty -m b
G0="$(git -C "$R16G" rev-parse HEAD~1)"; G1="$(git -C "$R16G" rev-parse HEAD)"
hook16() {  # <hook> <logdir> <stdin> [env...] -> the hook's rc
  local h="$1" ld="$2" in="$3"; shift 3
  mkdir -p "$ld"
  ( cd "$R16G" && printf '%s' "$in" | env "$@" GATE="$ld/gate" SPL_PREPUSH_LOG_DIR="$ld" bash "$h" origin file://x >/dev/null 2>&1 )
}
L="$ROOT/l16g"; hook16 "$HOOK" "$L" "garbage"$'\n'; eq "16g. a line with no remote ref -> exit 0 from the gate" 0 "$?"
eq "16g. ... GATED, never read as no refs" gated "$(gated16 "$L")"; eq "16g. ... no SKIP line" 0 "$(logged16 "$L" ' SKIP-')"
eq "16g. ... REFS shows the line, not none" 0 "$(logged16 "$L" 'REFS .* -- none$')"
L="$ROOT/l16l"; hook16 "$HOOK" "$L" "   "$'\n'; eq "16l. blank stdin -> exit 0 from the gate" 0 "$?"; eq "16l. ... GATED" gated "$(gated16 "$L")"
unread16() { mkdir -p "$2"; ( cd "$R16G" && GATE="$2/gate" SPL_PREPUSH_LOG_DIR="$2" bash "$1" origin file://x </ >/dev/null 2>&1 ); }
L="$ROOT/l16m"; unread16 "$HOOK" "$L"; eq "16m. unreadable stdin -> exit 0 from the gate" 0 "$?"; eq "16m. ... GATED" gated "$(gated16 "$L")"
NF16="refs/heads/master $G0 refs/heads/master $G1"$'\n'"refs/heads/w $G1 refs/heads/wip/x $ZERO"$'\n'
R716="refs/heads/master $G1 refs/heads/master $G0"$'\n'"refs/heads/w $G1 refs/heads/wip/x $ZERO"$'\n'
OO16="refs/heads/w $G1 refs/heads/wip/x $ZERO"$'\n'
L="$ROOT/l16h"; hook16 "$HOOK" "$L" "$NF16"; eq "16h. non-ff guard still refuses (wip beside master)" 1 "$?"; eq "16h. ... before the gate" no "$(gated16 "$L")"
L="$ROOT/l16i"; hook16 "$HOOK" "$L" "$R716" STUB_R7=1; eq "16i. R7 line check still refuses" 1 "$?"; eq "16i. ... before the gate" no "$(gated16 "$L")"
L="$ROOT/l16j"; hook16 "$HOOK" "$L" "$OO16" STUB_OOG=1; eq "16j. owner-order guard still refuses a wip-only push, before the skip" 1 "$?"
grep -q 'REFUSE .*owner order' "$L/pre-push.log" && pass "16j. ... logged" || fail "16j. ... logged" "$(cat "$L/pre-push.log")"

U16="https://x-access-token:SECRET16@example.invalid/o.git"
pushurl16() {  # <hook> <logdir> <dst ref>: a push to a credentialed URL, rewritten to the bare remote
  mkdir -p "$2"; install -m 0755 "$1" "$R16/hk/pre-push"
  GATE="$2/gate" SPL_PREPUSH_LOG_DIR="$2" git -C "$R16/c" -c "url.$R16/o.git.insteadOf=$U16" push -q "$U16" "$A16:$3" >/dev/null 2>&1
}
L="$ROOT/l16k"; pushurl16 "$HOOK" "$L" refs/heads/lane16k; eq "16k. push to a credentialed URL -> pushed" 0 "$?"
eq "16k. ... the token is in no log line" 0 "$(logged16 "$L" SECRET16)"
eq "16k. ... REFS keeps the masked URL" 1 "$(logged16 "$L" 'REFS .* remote=https://\*\*\*@example.invalid/o.git ')"

# Red controls: each planted defect must change the verdict asserted above.
mut16() {  # <out> <old> <new> -> a copy of the hook with the one edit; fails when <old> is absent
  OLD16="$2" NEW16="$3" python3 - "$HOOK" "$1" <<'PY16'
import os, sys
s = open(sys.argv[1], encoding="utf-8").read()
old = os.environ["OLD16"]
if old not in s: sys.exit("mutation target absent: " + old)
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(old, os.environ["NEW16"]))
PY16
}
M="$ROOT/m16tk"; mut16 "$M" '_pp_remote="${BASH_REMATCH[1]}***@${BASH_REMATCH[2]}"' ':' || fail "16 control: the url mask mutation applies"
L="$ROOT/l16ck"; pushurl16 "$M" "$L" refs/heads/lane16ck; eq "16 control: without the mask the token IS logged" 1 "$(logged16 "$L" 'REFS .*SECRET16')"
STDINLINE='if [ "$_pp_read_rc" != 0 ] || [ -n "$_pp_refs" ]; then _pp_wip=2; fi'
M="$ROOT/m16bl"; mut16 "$M" "$STDINLINE" 'if [ "$_pp_read_rc" != 0 ]; then _pp_wip=2; fi' || fail "16 control: the blank stdin mutation applies"
L="$ROOT/l16cl"; hook16 "$M" "$L" "   "$'\n'; eq "16 control: blank stdin read as no refs is ungated" no "$(gated16 "$L")"
M="$ROOT/m16ur"; mut16 "$M" "$STDINLINE" 'if [ -n "$_pp_refs" ]; then _pp_wip=2; fi' || fail "16 control: the unreadable stdin mutation applies"
L="$ROOT/l16cm"; unread16 "$M" "$L"; eq "16 control: a failed read taken as no refs is ungated" no "$(gated16 "$L")"
M="$ROOT/m16n2"; mut16 "$M" '[ -n "${_pp_lref:-}" ] || continue
  _pp_seen' '[ -n "${_pp_rref:-}" ] || continue
  _pp_seen' || fail "16 control: the REFS mutation applies"
L="$ROOT/l16cn"; hook16 "$M" "$L" "garbage"$'\n'; eq "16 control: REFS skipping a malformed line says none" 1 "$(logged16 "$L" 'REFS .* -- none$')"
SKIPLINE='if [ "$_pp_wip" = 0 ]; then'
M="$ROOT/m16nr"; mut16 "$M" "$SKIPLINE" 'if false; then' || fail "16 control: the no-ref mutation applies"
L="$ROOT/l16cc"; push16 "$M" "$L" --force-with-lease="$W16:$B16" "$B16:$W16"; eq "16 control: without the no-ref skip, the up to date wip push IS gated" gated "$(gated16 "$L")"
M="$ROOT/m16mix"; mut16 "$M" '*) _pp_wip=2; break ;; esac' '*) _pp_wip=1 ;; esac' || fail "16 control: the mixed mutation applies"
L="$ROOT/l16ce"; push16 "$M" "$L" "$A16:refs/heads/lane16b" "$A16:refs/heads/wip/c-999-z"; eq "16 control: a skip that ignores the other ref leaves the mixed push ungated" no "$(gated16 "$L")"
L="$ROOT/l16cf"; push16 "$M" "$L" "$C16:refs/heads/master"; eq "16 control: ... and the master push ungated" no "$(gated16 "$L")"
M="$ROOT/m16g"; mut16 "$M" "$STDINLINE"'
while read -r _pp_lref _ _pp_rref _; do
  [ -n "${_pp_lref:-}" ] || continue' 'while read -r _pp_lref _ _pp_rref _; do
  [ -n "${_pp_rref:-}" ] || continue' || fail "16 control: the malformed mutation applies"
L="$ROOT/l16cg"; hook16 "$M" "$L" "garbage"$'\n'; eq "16 control: reading a malformed line as no refs leaves it ungated" no "$(gated16 "$L")"
M="$ROOT/m16nf"; mut16 "$M" 'elif ! git merge-base --is-ancestor "$_pp_rsha" "$_pp_lsha" 2>/dev/null; then' 'elif false; then' || fail "16 control: the non-ff mutation applies"
L="$ROOT/l16ch"; hook16 "$M" "$L" "$NF16"; eq "16 control: no ancestry check -> the non-ff push passes" 0 "$?"
M="$ROOT/m16r7"; mut16 "$M" '[ -n "$_pp_bad" ] || continue' 'continue' || fail "16 control: the R7 mutation applies"
L="$ROOT/l16ci"; hook16 "$M" "$L" "$R716" STUB_R7=1; eq "16 control: no R7 check -> the round row passes" 0 "$?"
M="$ROOT/m16oo"; mut16 "$M" 'if [ -r "$_pp_oo" ]; then' 'if false; then' || fail "16 control: the owner-order mutation applies"
L="$ROOT/l16cj"; hook16 "$M" "$L" "$OO16" STUB_OOG=1; eq "16 control: no owner-order guard -> the wip push passes" 0 "$?"

echo "-- test-pre-push-hook.sh: $fails failed"
[ "$fails" -eq 0 ]
