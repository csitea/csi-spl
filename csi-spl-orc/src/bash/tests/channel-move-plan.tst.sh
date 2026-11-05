#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 167 row B1 - the channel move's manifest (derive + declare),
#   its read-only `plan` and the caller check of D1, on two sandbox boxes (two
#   spool roots, a stub ssh into box B, a stub tmux, a fake /proc for the
#   caller's ancestry). Cases, each with its control:
#     C1  plan on 1 seat, 1 repo, 1 data file, 1 secret: every line with size
#         and time, the secret by kind only (no path, no bytes); `find -newer`
#         over both boxes -> 0. CONTROL: a planted write after the stamp IS
#         found, so the 0 is not a blind find.
#     C14 a lane that is not the orch lease holder: (a) SPOOL_AGENT_ID set,
#         (b) under sudo with it unset, on a tty, from its pane -> refused,
#         nothing read (a bad CHANNEL is never reached). CONTROL: the orch
#         lease holder's pane passes; an env id naming the orch does not.
#     C21 no tty, no agent (cron) -> refused. CONTROL: the same chain on a
#         tty is the owner.
#     C22 DRY_RUN=0 by a tty caller with no signed directive -> refused, the
#         move hook never ran. CONTROL: with a signing key it runs.
#     C23 ack: (a) the seat the journal names -> accepted; (b) another lane,
#         (c) the named seat for another MOVE_ID, (d) clean by the named
#         seat -> refused.
#     C24 the owner drives from box-a over the hub path: move signs one
#         envelope to box-a and one to box-b in one 5-minute window it shuts;
#         each verifies on its own box and not on the other (78); resume signs
#         fresh ones (the move's nonce is spent); a window the owner opened
#         stays open.
#   Plus do_spl_channel_manifest_add: adds 0600, dedupes, refuses a path
#   outside the allowed roots, an unknown kind and a bad marker.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ME="$(id -un)"
A="$T/a"; B="$T/b"; W="$T/wt"; P="$T/proc"
mkdir -p "$A/c-901/lifetime" "$A/dispatch" "$B" "$T/stub" "$T/data" "$T/keys" "$P"
UUID=00000000-0000-4000-8000-000000000001
printf 't1\tgeneral\t%s\tdev\tc-001\tc-901@box-a\n' "$UUID" >"$A/channel-rules.tsv"
printf 't1\tgeneral\t%s\tdev\tc-001\n' "$UUID" >"$B/channel-rules.tsv"
printf 'c-901\tclaude\t%%91\t%s\t20261105T000000Z\n' "$W" >"$A/registry.tsv"
printf 'c-001\tclaude\t%%5\t-\t-\nc-777\tclaude\t%%7\t-\t-\nc-777\tclaude\t%%8\t-\t-\nc-950\tclaude\t%%9\t-\t-\n' >>"$A/registry.tsv"
printf '# Brief\nChannel: t1 #general\n' >"$A/c-901/lifetime/brief.md"
printf 'c-001@box-a 1793871709\n' >"$A/dispatch/lease.orch"

# a repo with a base both boxes have, one commit on top, uncommitted work
git init -q -b master "$T/up" && git -C "$T/up" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base
git clone -q "$T/up" "$W" 2>/dev/null
printf 'x%.0s' $(seq 1 3000) >"$W/new.txt"
git -C "$W" add new.txt && git -C "$W" -c user.name=t -c user.email=t@example.com commit -q -m work
printf 'draft\n' >"$W/untracked.txt"
head -c 2000 /dev/zero >"$T/data/report.csv"
printf 'PLANTED-KEY-BYTES\n' >"$T/keys/k.json"; chmod 0600 "$T/keys/k.json"

# stubs: ssh into box B (runs the command with B's spool root), tmux panes
printf '#!/bin/bash\necho "$*" >>%q\nshift\nexec env SPOOL_ROOT=%q bash -c "$*"\n' "$T/ssh-argv.log" "$B" >"$T/stub/ssh-b"
cat >"$T/stub/tmux" <<EOF
#!/bin/bash
case " \$* " in *" list-panes "*) cat "$T/panes.tsv" 2>/dev/null ;; *" list-windows "*) printf 'c-001\nc-002\n' ;; esac
EOF
chmod +x "$T/stub/ssh-b" "$T/stub/tmux"
printf '602\t%%5\tc-001\n703\t%%7\tc-777\n803\t%%8\tc-777\n953\t%%9\tc-950\n723\t%%22\tc-001\n' >"$T/panes.tsv"

# fake /proc: proc PID COMM PPID [ENV...]
proc() {
  local pid="$1" comm="$2" pp="$3"; shift 3
  mkdir -p "$P/$pid"; echo "$comm" >"$P/$pid/comm"; printf 'Name:\t%s\nPPid:\t%s\n' "$comm" "$pp" >"$P/$pid/status"
  if [ $# -gt 0 ]; then printf '%s\0' "$@" >"$P/$pid/environ"; else : >"$P/$pid/environ"; fi
}
proc 10 "tmux: server" 1
proc 500 bash 499; proc 499 sh 10                                    # owner shell, no pane
proc 600 bash 601; proc 601 claude 602; proc 602 sh 10               # orch c-001 in pane %5
proc 700 bash 701 SPOOL_AGENT_ID=c-777; proc 701 claude 703; proc 703 sh 10
proc 800 bash 801; proc 801 sudo 802; proc 802 claude 803; proc 803 sh 10   # lane under sudo, env gone
proc 810 bash 803                                                    # lane pane, no CLI, no env
proc 900 bash 901; proc 901 cron 1                                   # cron
proc 950 bash 951; proc 951 claude 953; proc 953 sh 10               # new seat c-950 in pane %9
proc 720 bash 721; proc 721 claude 723; proc 723 sh 10               # a pane no registry row names

cat >"$T/runner.sh" <<'EOF'
set -uo pipefail
do_log() { echo "$*"; }
source "$PROJ_PATH/lib/bash/funcs/spl-box-state-mounts.func.sh"
source "$PROJ_PATH/src/bash/run/spl-channel-move.func.sh"
source "$PROJ_PATH/src/bash/run/spl-channel-manifest-add.func.sh"
cm_cmd_move()  { echo "HOOK move ran MOVE_ID=$MOVE_ID"; touch "$HOOK_MARK"; [ -n "${CM_ENVELOPES:-}" ] && cp "$CM_ENVELOPES"/* "$HOOK_OUT"/; }
cm_cmd_resume() { cm_cmd_move; }
cm_cmd_ack()   { echo "HOOK ack ran by ${CM_CALLER}"; touch "$HOOK_MARK"; }
cm_cmd_clean() { echo "HOOK clean ran"; touch "$HOOK_MARK"; }
"$@"
EOF
mkdir -p "$T/hook-out"
base_env=(PROJ_PATH="$PROJ_ROOT" PATH="$T/stub:$PATH" SPOOL_TEST=1 SPOOL_ROOT="$A" SPOOL_BOX_TAG=box-a
  SPOOL_BOX_USER="$ME" SPOOL_AGENT_USER="$ME" SPOOL_TMUX_SOCKET="$T/tmux.sock" MOVE_CALLER_PROC="$P"
  MOVE_SSH="$T/stub/ssh-b" MOVE_UPLINK_KBPS=75 CHANNEL=t1/general TO=box-b HOOK_MARK="$T/hook-ran" HOOK_OUT="$T/hook-out")
# run PID [VAR=v]... -- no tty; ontty PID [VAR=v]... -- under a pty (script)
run() { local pid="$1"; shift; env -u SPOOL_AGENT_ID -u SUDO_USER "${base_env[@]}" MOVE_CALLER_PID="$pid" "$@" bash "$T/runner.sh" do_spl_channel_move </dev/null 2>&1; }
ontty() {
  local pid="$1" a q=""; shift
  for a in "${base_env[@]}" MOVE_CALLER_PID="$pid" "$@"; do q+=" $(printf '%q' "$a")"; done
  script -qec "env -u SPOOL_AGENT_ID -u SUDO_USER $q bash $(printf '%q' "$T/runner.sh") do_spl_channel_move; echo RC=\$?" /dev/null 2>&1 | tr -d '\r'
}
add() { env "${base_env[@]}" "$@" bash "$T/runner.sh" do_spl_channel_manifest_add 2>&1; }

# ---- do_spl_channel_manifest_add -----------------------------------------------------------
out="$(add MANIFEST_KIND=data MANIFEST_VALUE="$T/data/report.csv")"; rc=$?
M="$A/channel-move/t1-general.manifest"
[ "$rc" = 0 ] && [ "$(stat -c %a "$M")" = 600 ] && [ "$(stat -c %a "$A/channel-move")" = 700 ] &&
  pass "manifest-add: a data line, manifest 0600 in a 0700 dir" || fail "manifest-add data: rc $rc $out $(stat -c %a "$M" 2>&1)"
add MANIFEST_KIND=data MANIFEST_VALUE="$T/data/report.csv" >/dev/null
[ "$(grep -c report.csv "$M")" = 1 ] && pass "manifest-add: the same line is not added twice" || fail "manifest-add dedupe: $(cat "$M")"
out="$(add MANIFEST_KIND=secret MANIFEST_VALUE="$T/keys/k.json")"
grep -q 'k.json' <<<"$out" && fail "manifest-add printed the secret path: $out" || pass "manifest-add: a secret line is added, its path not printed"
add MANIFEST_KIND=tests-not-run MANIFEST_VALUE='bash src/bash/tests/run-all-tests.sh' >/dev/null
out="$(add MANIFEST_KIND=data MANIFEST_VALUE=/etc/hostname)"; rc=$?
[ "$rc" = 2 ] && grep -q 'outside the allowed roots' <<<"$out" && ! grep -q /etc/hostname "$M" &&
  pass "manifest-add: /etc/hostname refused (outside the allowed roots)" || fail "manifest-add root: rc $rc $out"
out="$(add MANIFEST_KIND=repo MANIFEST_VALUE="$T/x")"; rc=$?
[ "$rc" = 2 ] && pass "manifest-add: a derived kind (repo) cannot be declared" || fail "manifest-add kind: rc $rc $out"
out="$(add MANIFEST_KIND=marker MANIFEST_VALUE='two words')"; rc=$?
[ "$rc" = 2 ] && pass "manifest-add: a marker of two words refused" || fail "manifest-add marker: rc $rc $out"

# ---- C1: plan is read only, prints every line, a secret by kind only -------------------------
touch "$T/stamp"; sleep 1
out="$(run 600)"; rc=$?
newer="$(find "$A" "$B" "$W" "$T/data" "$T/keys" "$T/up" -newer "$T/stamp" | wc -l)"
ok=1
for want in 'caller: orch c-001' 'seat c-901' "repo $W (origin)" "uncommitted $W" "data $T/data/report.csv: 2000 B" \
            'secret #1 (a secret line; path withheld), mode 600' 'tests-not-run: bash src/bash/tests/run-all-tests.sh' \
"spool $A/c-901" 'desk in t1 on box-b: yes' "target has base $(git -C "$W" rev-parse HEAD~1 | cut -c1-12): yes" 'agent windows on box-b: 2 of 40' 'secret #1 same copy on box-b: yes' 'owner GO: not needed' \
            'kB/s (given)' 'plan: OK'; do
  grep -qF -- "$want" <<<"$out" || { ok=0; fail "C1 plan output lacks: $want"; }
done
[ "$ok" = 1 ] && [ "$rc" = 0 ] && pass "C1 plan prints every manifest line with size and time, rc 0" || fail "C1 plan rc $rc: $out"
grep -qE 'k\.json|PLANTED-KEY' <<<"$out" && fail "C1 the secret's path or bytes printed" || pass "C1 the secret is printed by kind only (no path, no bytes)"
[ "$newer" = 0 ] && [ ! -e "$A/channel-move/journal.tsv" ] && [ -z "$(find "$A/channel-move" -mindepth 1 -type d)" ] &&
  pass "C1 find -newer over both sandbox boxes, the repo and the data -> 0; no journal" || fail "C1 the plan changed $newer path(s): $(find "$A" "$B" "$W" -newer "$T/stamp")"
touch "$B/planted"
grep -q "/planted$" <<<"$(find "$A" "$B" -newer "$T/stamp")" && pass "C1 CONTROL: a write after the stamp IS found (the find is not blind)" || fail "C1 control: the find missed a planted write"
rm -f "$B/planted"
out="$(run 600 MOVE_SSH=false)"
grep -q 'no ssh path to box-b: base, desk and ceiling NOT checked' <<<"$out" && grep -q 'same copy on box-b: not checked' <<<"$out" && grep -q 'owner GO: needed for 1 secret' <<<"$out" &&
  pass "C1 without ssh the plan says which checks did not run" || fail "C1 no-ssh: $out"
printf 'data /etc/hostname\n' >>"$M"
out="$(run 600)"; rc=$?
[ "$rc" = 5 ] && grep -q 'REFUSED data: a path outside the allowed roots' <<<"$out" &&
  pass "C1 a hand-added path outside the allowed roots: plan refuses it, rc 5" || fail "C1 root refusal: rc $rc"
sed -i '/^data \/etc\/hostname$/d' "$M"
grep -qF k.json "$T/ssh-argv.log" && fail "N2 the secret's path was on the ssh argv: $(cat "$T/ssh-argv.log")" ||
  pass "N2 the secret's path never reaches the ssh command line (it goes on stdin; $(wc -l <"$T/ssh-argv.log") ssh calls logged)"
printf 'data\n' >>"$M"
out="$(run 600)"; rc=$?
[ "$rc" = 5 ] && grep -q 'REFUSED a manifest line with fewer than 2 fields' <<<"$out" &&
  pass "N3 a manifest line with fewer than 2 fields: refused, rc 5" || fail "N3: rc $rc $out"
sed -i '/^data$/d' "$M"
out="$(run 600 DRY_RUN=0 MOVE_CMD=plan)"; rc=$?
[ "$rc" = 0 ] && [ -z "$(find "$A/channel-move" -mindepth 1 -type d)" ] && pass "C1 DRY_RUN=0 MOVE_CMD=plan still writes nothing" || fail "C1 DRY_RUN=0 plan: rc $rc"

# ---- C14: a lane that is not the orch lease holder ----------------------------------------
out="$(run 700 SPOOL_AGENT_ID=c-777 CHANNEL=BAD)"; rc=$?
[ "$rc" = 3 ] && grep -q 'not the orch lease holder' <<<"$out" && ! grep -qE 'CHANNEL must|seat c-901' <<<"$out" &&
  pass "C14 (a) a lane with SPOOL_AGENT_ID set is refused before anything is read" || fail "C14 (a): rc $rc $out"
out="$(ontty 800 CHANNEL=BAD)"
grep -q 'RC=3' <<<"$out" && grep -q 'pane id c-777' <<<"$out" && ! grep -q 'CHANNEL must' <<<"$out" &&
  pass "C14 (b) the same lane under sudo, no agent id, ON A TTY: refused by its ancestry and pane" || fail "C14 (b): $out"
out="$(ontty 810)"
grep -q 'RC=3' <<<"$out" && pass "C14 (b) its pane alone (no CLI, no env in the chain) is enough to refuse" || fail "C14 pane-only: $out"
out="$(run 700 SPOOL_AGENT_ID=c-001)"; rc=$?
[ "$rc" = 3 ] && pass "C14 CONTROL: an env id naming the orch does not make a lane the orch" || fail "C14 env spoof: rc $rc $out"
printf 'c-001@box-z 1\n' >"$A/dispatch/lease.orch"
out="$(run 600)"; rc=$?
[ "$rc" = 3 ] && pass "C14 c-001 on box-a while the lease is c-001@box-z: refused" || fail "C14 other box: rc $rc"
printf 'c-001@box-a 1793871709\n' >"$A/dispatch/lease.orch"
out="$(run 600)"; rc=$?
[ "$rc" = 0 ] && pass "C14 CONTROL: the orch lease holder's own pane runs the plan" || fail "C14 orch control: rc $rc $out"
sed -i 's/^703\t%7\tc-777$/703\t%7\tc-001/' "$T/panes.tsv"
out="$(run 700)"; rc=$?
[ "$rc" = 3 ] && pass "W2 a lane whose window is renamed to c-001 (registry: c-777): refused" || fail "W2 renamed window: rc $rc $out"
sed -i 's/^703\t%7\tc-001$/703\t%7\tc-777/' "$T/panes.tsv"
out="$(run 720)"; rc=$?
[ "$rc" = 3 ] && pass "W2 a pane no registry row names, window c-001: refused" || fail "W2 unregistered pane: rc $rc $out"

# ---- C21: cron ----------------------------------------------------------------------------
out="$(run 900)"; rc=$?
[ "$rc" = 3 ] && grep -q 'no tty' <<<"$out" && pass "C21 no tty and no agent (cron): refused" || fail "C21: rc $rc $out"
out="$(ontty 900)"
grep -q 'caller: owner' <<<"$out" && grep -q 'RC=0' <<<"$out" &&
  pass "C21 CONTROL: the same chain on a tty is taken as the owner (plan only)" || fail "C21 control: $out"
out="$(ontty 900 SUDO_USER=someone-else)"
grep -q 'RC=0' <<<"$out" && fail "C21 a sudo from another user passed as the owner" || pass "C21 a tty under a sudo from another user: refused"

# ---- C22: DRY_RUN=0 by a tty caller with no signed directive ------------------------------
rm -f "$T/hook-ran"
out="$(ontty 500 DRY_RUN=0 MOVE_CMD=move DIRECTIVE_FPR= DIRECTIVE_SESSION_STATE="$T/no-sess")"
grep -q 'RC=3' <<<"$out" && [ ! -e "$T/hook-ran" ] &&
  pass "C22 DRY_RUN=0 on a tty with no signed directive: refused, the move hook never ran" || fail "C22: $out"
out="$(run 500 MOVE_CMD=move)"
grep -q 'dry run' <<<"$out" && [ ! -e "$T/hook-ran" ] && pass "C22 MOVE_CMD=move without DRY_RUN=0 prints the plan only" || fail "C22 dry: $out"

# ---- C24 (and C22's control): the owner signs, on the hub path ---------------------------
G="$T/gpg"; mkdir -p "$G"; chmod 700 "$G"
gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase p --quick-gen-key 'directive test' ed25519 sign never >/dev/null 2>&1
FPR="$(gpg --homedir "$G" --batch --with-colons --list-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
D="$T/directive"; mkdir -p "$D/scripts" "$D/lib"
cp "$PROJ_ROOT/src/bash/features/directive/scripts/directive-verify.sh" "$D/scripts/"
cp "$PROJ_ROOT/src/bash/features/directive/lib/directive-env.inc.sh" "$D/lib/"
cat >"$D/scripts/directive-session.sh" <<EOF
#!/bin/bash
echo "session \$*" >>"$T/sess.log"
case "\$1" in --status) [ -f "$T/sess.state" ] && echo '=== directive session OPEN' || echo '=== directive session CLOSED' ;;
  --minutes) echo "\$2" >"$T/sess.state" ;; --close) rm -f "$T/sess.state" ;; esac
EOF
cat >"$D/scripts/directive-sign.sh" <<EOF
#!/bin/bash
[ -f "$T/sess.state" ] || { echo 'no window' >&2; exit 2; }
echo "sign \$3" >>"$T/sess.log"
printf 'to: %s\nnonce: %s\nissued: %s\nexpires: %s\n---\n%s\n' "\$3" "\$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')" "\$(date -u +%FT%TZ)" "\$(date -u -d '+10 min' +%FT%TZ)" "\$4" |
  gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase p --local-user "$FPR" --clearsign 2>/dev/null
EOF
sig_env=(DRY_RUN=0 MOVE_DIRECTIVE_DIR="$D/scripts" DIRECTIVE_FPR="$FPR" DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_LEDGER="$T/ledger-a" MOVE_SSH=false)
verify() { DIRECTIVE_FPR="$FPR" DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_LEDGER="$2" DIRECTIVE_BOX="$1" SPOOL_BOX_ENV=/nonexistent bash "$D/scripts/directive-verify.sh" --show <"$3" >/dev/null 2>&1; echo $?; }
: >"$T/sess.log"; rm -f "$T/hook-ran" "$T/sess.state"
out="$(ontty 500 "${sig_env[@]}" MOVE_CMD=move MOVE_ID=mv-24)"
[ -e "$T/hook-ran" ] && grep -q 'RC=0' <<<"$out" && pass "C22 CONTROL: with the owner's signed directive the move hook runs" || fail "C22 control: $out"
log="$(tr '\n' '|' <"$T/sess.log")"
[ "$log" = "session --status|session --minutes 5|sign box-a|sign box-b|session --close|" ] && [ ! -e "$T/sess.state" ] &&
  pass "C24 move: one 5-minute window, signed to box-a and box-b, shut after" || fail "C24 window: $log"
cp "$T/hook-out/envelope.box-a.asc" "$T/move-a.asc"; cp "$T/hook-out/envelope.box-b.asc" "$T/move-b.asc"
[ "$(verify box-a "$T/ledger-a" "$T/move-a.asc")" = 78 ] && pass "C24 the box-a envelope was verified (nonce spent on box-a): a replay is refused" || fail "C24 box-a replay"
[ "$(verify box-a "$T/ledger-a2" "$T/move-b.asc")" = 78 ] && pass "C24 the box-b envelope verified on box-a: refused (exit 78)" || fail "C24 to: box-b on box-a"
[ "$(verify box-b "$T/ledger-b" "$T/move-b.asc")" = 0 ] && pass "C24 the box-b envelope verifies on box-b" || fail "C24 box-b verify"
: >"$T/sess.log"; rm -f "$T/hook-ran"; rm -f "$T"/hook-out/*
out="$(ontty 500 "${sig_env[@]}" MOVE_CMD=resume MOVE_ID=mv-24)"
n_move="$(sed -n 's/^nonce: //p' "$T/move-a.asc")"; n_res="$(sed -n 's/^nonce: //p' "$T/hook-out/envelope.box-a.asc" 2>/dev/null)"
[ -e "$T/hook-ran" ] && [ -n "$n_res" ] && [ "$n_res" != "$n_move" ] && [ ! -e "$T/sess.state" ] &&
  pass "C24 resume signs fresh envelopes (new nonce) and shuts its window" || fail "C24 resume: $out"
echo 60 >"$T/sess.state"; : >"$T/sess.log"; rm -f "$T/hook-ran"
out="$(ontty 500 "${sig_env[@]}" MOVE_CMD=resume MOVE_ID=mv-24)"
log="$(tr '\n' '|' <"$T/sess.log")"
[ -e "$T/hook-ran" ] && [ -e "$T/sess.state" ] && [ "$log" = "session --status|sign box-a|sign box-b|" ] &&
  pass "C24 a window the owner opened is used and left open" || fail "C24 owner window: $log $out"
rm -f "$T/sess.state"
out="$(ontty 500 "${sig_env[@]}" MOVE_CMD=move MOVE_ID=mv-25 MOVE_SSH="$T/stub/ssh-b")"
log="$(tail -n 3 "$T/sess.log" | tr '\n' '|')"
[ "$log" = "session --minutes 5|sign box-a|session --close|" ] && pass "C24 with an ssh path only the driver's envelope is signed" || fail "C24 ssh path: $log"
gpgconf --homedir "$G" --kill gpg-agent >/dev/null 2>&1

# ---- C23: ack ------------------------------------------------------------------------------
mkdir -p "$A/channel-move/mv1" "$A/channel-move/mv2"
printf 'S6:c-950@box-a\tok\t-\t-\t0\t-\n' >"$A/channel-move/mv1/journal.tsv"
printf 'S6:c-951@box-a\tok\t-\t-\t0\t-\n' >"$A/channel-move/mv2/journal.tsv"
rm -f "$T/hook-ran"
out="$(run 950 MOVE_CMD=ack MOVE_ID=mv1 SEAT=c-950)"; rc=$?
[ "$rc" = 0 ] && grep -q 'HOOK ack ran by seat c-950' <<<"$out" && pass "C23 (a) the seat the journal names acks" || fail "C23 (a): rc $rc $out"
rm -f "$T/hook-ran"
out="$(run 700 MOVE_CMD=ack MOVE_ID=mv1 SEAT=c-777)"; rc=$?
[ "$rc" = 3 ] && [ ! -e "$T/hook-ran" ] && pass "C23 (b) another lane's ack: refused" || fail "C23 (b): rc $rc $out"
out="$(run 700 MOVE_CMD=ack MOVE_ID=mv1 SEAT=c-950 SPOOL_AGENT_ID=c-950)"; rc=$?
[ "$rc" = 3 ] && [ ! -e "$T/hook-ran" ] && pass "C23 (b) another lane claiming SEAT=c-950 by env: refused (pane decides)" || fail "C23 (b) spoof: rc $rc $out"
out="$(run 950 MOVE_CMD=ack MOVE_ID=mv2 SEAT=c-950)"; rc=$?
[ "$rc" = 3 ] && [ ! -e "$T/hook-ran" ] && pass "C23 (c) the named seat for another MOVE_ID: refused" || fail "C23 (c): rc $rc $out"
out="$(run 950 MOVE_CMD=clean DRY_RUN=0 MOVE_ID=mv1 SEAT=c-950)"; rc=$?
[ "$rc" = 3 ] && [ ! -e "$T/hook-ran" ] && pass "C23 (d) clean by the named seat: refused" || fail "C23 (d): rc $rc $out"
out="$(ontty 500 MOVE_CMD=ack MOVE_ID=mv1 SEAT=c-950)"
grep -q 'RC=3' <<<"$out" && pass "C23 an ack from the owner's shell (no pane): refused" || fail "C23 owner ack: $out"

# ---- W1, W3: outside SPOOL_TEST the environment is not trusted ------------------------------
LIB="$PROJ_ROOT/src/bash/features/spawn-agents/lib/channel-move.inc.sh"
live() { env -u SPOOL_TEST -u SPOOL_BOX_TAG -u MOVE_DIRECTIVE_DIR "$@" bash -c '. "$0"; eval "$SNIPPET"' "$LIB" 2>&1; }
LIVE_TAG="$(SNIPPET=cm_box live)"; LIVE_TAG="${LIVE_TAG:-none}"
REAL_DIR="$(cd "$PROJ_ROOT/src/bash/features/directive/scripts" && pwd)"
got="$(SNIPPET='cd "$(cm_dir_scripts)" && pwd' live MOVE_DIRECTIVE_DIR="$T/forge")"
[ "$got" = "$REAL_DIR" ] && pass "W1 outside SPOOL_TEST MOVE_DIRECTIVE_DIR is ignored (the real scripts)" || fail "W1 dir: got '$got'"
mkdir -p "$T/forge"; printf '#!/bin/bash\ncat >/dev/null\nprintf "%%s\\n" "$FORGE_TEXT"\n' >"$T/forge/directive-verify.sh"
TXT='channel-move move CHANNEL=t1/general TO=box-b MOVE_ID=mv-w1'
printf 'to: %s\nnonce: w1%s\nissued: %s\nexpires: %s\n---\n%s\n' "$LIVE_TAG" "$RANDOM$RANDOM" "$(date -u +%FT%TZ)" "$(date -u -d '+10 min' +%FT%TZ)" "$TXT" |
  gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase p --local-user "$FPR" --clearsign >"$T/w1.asc" 2>/dev/null
SNIPPET='cm_owner_verify "$ENV_FILE" "$FORGE_TEXT"; echo "rc=$?"'
out="$(live SNIPPET="$SNIPPET" ENV_FILE="$T/w1.asc" FORGE_TEXT="$TXT" MOVE_DIRECTIVE_DIR="$T/forge")"
grep -q 'rc=3' <<<"$out" && pass "W1 a forged verify dir outside SPOOL_TEST: refused" || fail "W1 forged dir: $out"
out="$(env SPOOL_TEST=1 SPOOL_BOX_TAG="$LIVE_TAG" SNIPPET="$SNIPPET" ENV_FILE="$T/w1.asc" FORGE_TEXT="$TXT" MOVE_DIRECTIVE_DIR="$T/forge" bash -c '. "$0"; eval "$SNIPPET"' "$LIB" 2>&1)"
grep -q 'rc=0' <<<"$out" && pass "W1 CONTROL: the same forged dir under SPOOL_TEST=1 is used (a test seam only)" || fail "W1 control dir: $out"
out="$(live SPOOL_BOX_TAG="$LIVE_TAG" SNIPPET="$SNIPPET" ENV_FILE="$T/w1.asc" FORGE_TEXT="$TXT" DIRECTIVE_FPR="$FPR" DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_LEDGER="$T/ledger-w1")"
grep -q 'rc=3' <<<"$out" && [ ! -e "$T/ledger-w1" ] && pass "W1 a forged DIRECTIVE_FPR/GNUPGHOME/LEDGER outside SPOOL_TEST: refused, the forged ledger untouched" || fail "W1 forged FPR: $out"
out="$(env SPOOL_TEST=1 SPOOL_BOX_TAG="$LIVE_TAG" SNIPPET="$SNIPPET" ENV_FILE="$T/w1.asc" FORGE_TEXT="$TXT" DIRECTIVE_FPR="$FPR" DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_LEDGER="$T/ledger-w1" SPOOL_BOX_ENV=/nonexistent bash -c '. "$0"; eval "$SNIPPET"' "$LIB" 2>&1)"
grep -q 'rc=0' <<<"$out" && pass "W1 CONTROL: the same envelope and key verify when the env is trusted (SPOOL_TEST=1)" || fail "W1 control FPR: $out"
mkdir -p "$T/fakebin"
printf 'case "$0" in *directive-verify.sh) cat >/dev/null; printf "%%s\\n" "$FORGE_TEXT"; exit 0 ;; esac\n' >"$T/evil-bash-env.sh"
out="$(live SPOOL_BOX_TAG="$LIVE_TAG" SNIPPET="$SNIPPET" ENV_FILE="$T/w1.asc" FORGE_TEXT="$TXT" BASH_ENV="$T/evil-bash-env.sh")"
grep -q 'rc=3' <<<"$out" && pass "W1' a forged BASH_ENV outside SPOOL_TEST: refused" || fail "W1' BASH_ENV: $out"
out="$(env SPOOL_TEST=1 SPOOL_BOX_TAG="$LIVE_TAG" SNIPPET="$SNIPPET" ENV_FILE="$T/w1.asc" FORGE_TEXT="$TXT" BASH_ENV="$T/evil-bash-env.sh" bash -c '. "$0"; eval "$SNIPPET"' "$LIB" 2>&1)"
grep -q 'rc=0' <<<"$out" && pass "W1' CONTROL: the same BASH_ENV forges verify where the env is passed (SPOOL_TEST=1)" || fail "W1' BASH_ENV control: $out"
# What reaches a directive script: a probe in place of the scripts dir prints
# its own environment (this box pins no key, so the real verify stops before
# gpg and a fake gpg there would prove nothing).
mkdir -p "$T/probe"; printf '#!/bin/bash\nenv\n' >"$T/probe/directive-verify.sh"
PROBE='cm_dir_scripts() { printf %s "$PROBE_DIR"; }; cm_dir_run directive-verify.sh'
envd="$(live SPOOL_BOX_TAG="$LIVE_TAG" SNIPPET="$PROBE" PROBE_DIR="$T/probe" PATH="$T/fakebin:$PATH" BASH_ENV=/dev/null \
  LD_PRELOAD=/nonexistent.so DIRECTIVE_FPR=forged GNUPGHOME=/forged BASH_FUNC_gpg%%='() { :; }')"
[ "$(sed -n 's/^PATH=//p' <<<"$envd")" = /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ] &&
  ! grep -qE '^(BASH_ENV|LD_PRELOAD|DIRECTIVE_FPR|GNUPGHOME|BASH_FUNC_)' <<<"$envd" && grep -q "^DIRECTIVE_BOX=$LIVE_TAG\$" <<<"$envd" &&
  pass "W1' outside SPOOL_TEST the script gets the fixed PATH and no BASH_ENV, LD_PRELOAD, DIRECTIVE_FPR, GNUPGHOME or exported function" ||
  fail "W1' script env: $(grep -E '^(PATH|BASH_ENV|LD_PRELOAD|DIRECTIVE_|GNUPGHOME|BASH_FUNC_)' <<<"$envd" | tr '\n' ' ')"
envd="$(env SPOOL_TEST=1 SPOOL_BOX_TAG="$LIVE_TAG" SNIPPET="$PROBE" PROBE_DIR="$T/probe" PATH="$T/fakebin:$PATH" BASH_ENV=/dev/null \
  bash -c '. "$0"; eval "$SNIPPET"' "$LIB" 2>&1)"
grep -q "^PATH=$T/fakebin:" <<<"$envd" && grep -q '^BASH_ENV=' <<<"$envd" &&
  pass "W1' CONTROL: the same probe under SPOOL_TEST=1 sees the caller's PATH and BASH_ENV" || fail "W1' env control: $envd"
got="$(SNIPPET='cm_box; echo "|$(cm_trust_root)"' live SPOOL_BOX_TAG=box-z SPOOL_ROOT="$A")"
[ "$got" != "box-z|/var/spool-hub" ] && [ "${got#*|}" = /var/spool-hub ] && [ "${got%%|*}" != box-z ] &&
  pass "W3 outside SPOOL_TEST the box tag is the box config's ('${got%%|*}'), not env box-z; the lease is read from /var/spool-hub" || fail "W3: got '$got'"
got="$(SNIPPET='cm_box' env SPOOL_TEST=1 SPOOL_BOX_TAG=box-z bash -c '. "$0"; eval "$SNIPPET"' "$LIB")"
[ "$got" = box-z ] && pass "W3 CONTROL: under SPOOL_TEST=1 the env tag is used (a test seam only)" || fail "W3 control: '$got'"
gpgconf --homedir "$G" --kill gpg-agent >/dev/null 2>&1

# ---- W4: outside SPOOL_TEST the caller check runs no tool of the caller's PATH --------------
# A fake tmux/sudo lists every ancestor as pane %999 in window c-998, a fake awk
# names c-998 for any registry.tsv read: with the caller's PATH the pane reads
# as c-998. CHANNEL and TO are invalid, so even a pass reads nothing.
mkdir -p "$T/w4bin"; AWK_REAL="$(command -v awk)"
cat >"$T/w4bin/tmux" <<'EOF'
#!/bin/bash
p=$PPID
while [ "${p:-0}" -gt 1 ]; do printf '%s\t%%999\tc-998\n' "$p"; p="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$p/status")"; done
EOF
printf '#!/bin/bash\nwhile [ $# -gt 0 ] && [ "$1" != tmux ]; do shift; done\nexec "$@"\n' >"$T/w4bin/sudo"
printf '#!/bin/bash\ncase "${*: -1}" in *registry.tsv) echo c-998 ;; *) exec %q "$@" ;; esac\n' "$AWK_REAL" >"$T/w4bin/awk"
chmod +x "$T/w4bin/tmux" "$T/w4bin/sudo" "$T/w4bin/awk"
w4() { env -u SPOOL_TEST -u SPOOL_AGENT_ID -u SPOOL_BOX_TAG PROJ_PATH="$PROJ_ROOT" CHANNEL=bad TO=BAD "$@" bash "$T/runner.sh" do_spl_channel_move </dev/null 2>&1; }
w4t() { env -u SPOOL_AGENT_ID PROJ_PATH="$PROJ_ROOT" SPOOL_TEST=1 SPOOL_ROOT="$A" SPOOL_BOX_TAG=box-a SPOOL_BOX_USER="$ME" \
  SPOOL_TMUX_SOCKET="$T/tmux.sock" CHANNEL=bad TO=BAD "$@" bash "$T/runner.sh" do_spl_channel_move </dev/null 2>&1; }
out="$(w4 PATH="$T/w4bin:$PATH")"
! grep -q 'c-998' <<<"$out" && pass "W4 a fake tmux/sudo/awk first on PATH outside SPOOL_TEST: the pane does not read as c-998" || fail "W4 PATH: $out"
out="$(w4t PATH="$T/w4bin:$PATH")"
grep -q 'pane id c-998' <<<"$out" && pass "W4 CONTROL: the same PATH under SPOOL_TEST=1 makes the pane read as c-998 (the fakes work)" || fail "W4 PATH control: $out"
out="$(w4 'BASH_FUNC_awk%%=() { echo c-998; }')"; rc=$?
[ "$rc" = 3 ] && grep -q 'exports a function (BASH_FUNC_awk%%)' <<<"$out" && ! grep -q 'c-998' <<<"$out" &&
  pass "W4 an exported function outside SPOOL_TEST: refused (rc 3), nothing read" || fail "W4 function: rc $rc $out"
out="$(w4)"
! grep -q 'exports a function' <<<"$out" && pass "W4 CONTROL: the same call with no exported function is not refused for one" || fail "W4 function control: $out"
out="$(w4t 'BASH_FUNC_awk%%=() { echo c-998; }')"
! grep -q 'exports a function' <<<"$out" && pass "W4 CONTROL: the same function under SPOOL_TEST=1 is not refused (a test seam only)" || fail "W4 function test control: $out"
pa="$(sed -n 's/^  PATH=\([^;]*\);.*/\1/p' "$PROJ_ROOT/src/bash/run/spl-channel-move.func.sh")"
pb="$(sed -n 's/^CM_SAFE_PATH=//p' "$LIB")"
[ -n "$pa" ] && [ "$pa" = "$pb" ] && pass "W4 the action's PATH equals the lib's CM_SAFE_PATH ($pa)" || fail "W4 PATH drift: action '$pa' lib '$pb'"

# ---- unknown and unbuilt commands --------------------------------------------------------
out="$(run 600 MOVE_CMD=status)"; rc=$?
[ "$rc" = 4 ] && grep -q 'not built yet' <<<"$out" && pass "a command no row has built yet (status): exit 4, nothing done" || fail "unbuilt: rc $rc $out"
out="$(run 600 MOVE_CMD=bogus)"; rc=$?
[ "$rc" = 2 ] && pass "an unknown MOVE_CMD: exit 2" || fail "unknown cmd: rc $rc"

[ "$fails" -eq 0 ] && echo "ALL PASS channel-move-plan" || { echo "FAILED $fails"; exit 1; }
