#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_auth_idp_secret_seed (spec 019 FR-L4, shared with 018) adds a
#          provider's client-secret version only when told (DRY_RUN=0) and only
#          when it differs, runs as the project SA in a throwaway
#          CLOUDSDK_CONFIG with --account on every secrets call, refuses a
#          missing / non-0600 / malformed owner file, a client_id that differs
#          from cnf, a placeholder cnf client id (naming the id to commit), an
#          unknown IDP and a Microsoft "Secret ID" GUID, and never puts the
#          value in argv or output. By CALLING it against a stubbed gcloud with
#          a file-backed secret store, HOME in a temp dir, and a copy of the cnf
#          whose dev LinkedIn/Microsoft client ids are set.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# a private APP tree: the real iac funcs, a cnf copy with test client ids
APP="$T/app"; mkdir -p "$APP/csi-spl-iac/lib/bash" "$APP/csi-spl-cnf"
ln -s "$APP_ROOT/csi-spl-iac/lib/bash/funcs" "$APP/csi-spl-iac/lib/bash/funcs"
cp -r "$APP_ROOT/csi-spl-cnf/csi-spl" "$APP/csi-spl-cnf/csi-spl"
LID="86test0linkedin" MID="00000000-1111-2222-3333-444444444444"
yq -i ".env.auth.social.env.SPOOL_HUB_AUTH_LINKEDIN_CLIENT_ID = \"$LID\" |
        .env.auth.social.env.SPOOL_HUB_AUTH_MICROSOFT_CLIENT_ID = \"$MID\"" "$APP/csi-spl-cnf/csi-spl/dev.env.yaml"
# a second tree whose dev LinkedIn client id is still the cnf placeholder
PH="$T/ph"; mkdir -p "$PH/csi-spl-iac/lib/bash" "$PH/csi-spl-cnf"
ln -s "$APP_ROOT/csi-spl-iac/lib/bash/funcs" "$PH/csi-spl-iac/lib/bash/funcs"
cp -r "$APP/csi-spl-cnf/csi-spl" "$PH/csi-spl-cnf/csi-spl"
yq -i '.env.auth.social.env.SPOOL_HUB_AUTH_LINKEDIN_CLIENT_ID = "PLACEHOLDER-linkedin-client-id"' "$PH/csi-spl-cnf/csi-spl/dev.env.yaml"

# Not provider-shaped on purpose: a WPL_AP-shaped literal here was GitHub
# secret-scanning alert #1 (linkedin_client_secret, security round 1 row 8,
# SPL-1967). The seed checks no format, so any string proves the same.
SECRET="fixture-linkedin-$RANDOM-$RANDOM.not-a-real-secret"
CD="$T/home/.gcp/.csi/.spl"; mkdir -p "$CD" "$T/store"
echo '{"type":"service_account"}' >"$T/home/.gcp/.csi/key-csi-spl-dev.json"
owner_file() {  # <idp> <client_id> <secret> [mode]
  (umask 077; printf '{"client_id":"%s","client_secret":"%s"}\n' "$2" "$3" >"$CD/$1-client-dev.json")
  chmod "${4:-600}" "$CD/$1-client-dev.json"
}
owner_file linkedin "$LID" "$SECRET"

run_seed() {  # [VAR=value ...] -> stdout+stderr of the action; gcloud argv in $T/argv
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="${APP_OVERRIDE:-$APP}" HOME="$T/home" SPL_STATE_DIR="$T/state" STORE="$T/store" \
      ARGV="$T/argv" CFGS="$T/cfgs" ENV=dev IDP=linkedin "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    gcloud() {
      echo "$*" >>"$ARGV"
      echo "${CLOUDSDK_CONFIG:-<unset>}" >>"$CFGS"
      case "$*" in
        "auth activate-service-account"*)
          [[ -z "${GC_FDS:-}" ]] || ls "/proc/$BASHPID/fd" >"$GC_FDS"
          # a process of the group that survives the Ctrl-C (SIGINT ignored)
          # and spins at 100% CPU until $GC_SPIN exists; up before the kill
          if [[ -n "${GC_SPIN:-}" ]]; then
            { trap "" INT; : >"$GC_SPIN.up"; while [[ ! -e "$GC_SPIN" ]]; do :; done; } &
            for _ in $(seq 1 600); do [[ -e "$GC_SPIN.up" ]] && break; sleep 0.1; done
          fi
          [[ -z "${GC_INTERRUPT:-}" ]] || kill -INT 0; return 0 ;;
        "auth list"*) echo "csi-spl-dev-sa@csi-spl-dev.iam.gserviceaccount.com" ;;
        "secrets versions access latest --secret="*)
          local s="${5#--secret=}"; [[ -f "$STORE/$s" ]] || return 1; cat "$STORE/$s" ;;
        "secrets versions add "*) local s="$4"; cat >"$STORE/$s"; echo add "$s" >>"$STORE/.adds" ;;
        *) return 0 ;;
      esac
    }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    [[ -z "${SEED_FUNC:-}" ]] || source "$SEED_FUNC"
    do_spl_auth_idp_secret_seed' 2>&1
}
LS=csi-spl-hub-auth-linkedin-client-secret MS=csi-spl-hub-auth-microsoft-client-secret
adds() { grep -c . "$T/store/.adds" 2>/dev/null || echo 0; }

out=$(run_seed); rc=$?
[[ $rc -eq 0 && $(adds) -eq 0 && "$out" == *"DRY_RUN would add"* ]] && pass "default is a dry run: nothing added" || fail "dry run: rc=$rc adds=$(adds) $out"

out=$(run_seed DRY_RUN=0); rc=$?
[[ $rc -eq 0 && "$(cat "$T/store/$LS" 2>/dev/null)" == "$SECRET" ]] && pass "DRY_RUN=0 adds the file's client_secret (no newline) to the linkedin slot" || fail "real run: rc=$rc $out"
if grep -qF "$SECRET" <<<"$out"; then fail "the value appears in the output"; else pass "no value in the output"; fi
if grep -qF "$SECRET" "$T/argv"; then fail "the value appears in gcloud argv"; else pass "no value in gcloud argv"; fi
[[ $(grep '^secrets ' "$T/argv" | grep -vc -- '--account=csi-spl-dev-sa@csi-spl-dev.iam.gserviceaccount.com') -eq 0 ]] \
  && pass "every secrets call carries --account=<the project SA>" || fail "unpinned secrets call"
if grep -qxE '<unset>|.*/\.config/gcloud' "$T/cfgs"; then fail "a gcloud call ran on the shared/ambient config"; else pass "every gcloud call ran in a throwaway CLOUDSDK_CONFIG"; fi
[[ ! -e "$(head -1 "$T/cfgs")" ]] && pass "the throwaway config is removed afterwards" || fail "throwaway config left behind"

# CTRL_C <cmd...>: a Ctrl-C. It runs <cmd> in its own process group with SIGINT
# at its default (a runner may start tests with it ignored), so the stub's
# `kill -INT 0` reaches the whole action and nothing else. It returns only
# once every process of that tree has exited (it is their child subreaper):
# the SIGINT can reach the action's shell before that shell waits on its
# subshell, so the shell dies at once while the orphaned subshell still runs
# its EXIT trap. Reading the temp root then raced the trap (wf10 run
# 38252452159, n=4 reds on two runner kinds).
# It is also BOUNDED (SPL-3894): a review push hung ~3 h because one
# Ctrl-C run left its setsid bash spinning at 100% CPU (state R, 52 min, c-394
# msg 7d91dc6c). This wrapper waited on it forever, and the runner's fds (fd 3
# is its tee pipe, run-all-tests.sh `3>&2`) were inherited by that session,
# so even after the hook's time budget killed the wrapper the orphan held
# the push's pipe open. Now the session gets none of the runner's fds, and
# CTRL_C_GRACE s (default 60) after the action's shell exits, or
# CTRL_C_DEADLINE s (default 300) in all, or on SIGTERM/SIGHUP, every
# process left in it is SIGKILLed: rc 124 when that was needed. The lines
# tagged FIX are what the RED CONTROL below strips.
CTRL_C_PY='
import ctypes, os, signal, sys, time
ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER
pid = os.fork()
if pid == 0:
    signal.signal(signal.SIGINT, signal.SIG_DFL); os.setsid()
    os.closerange(3, 65536)  # FIX: the session holds none of the runner fds
    os.execvp(sys.argv[1], sys.argv[1:])
def kill_all():  # FIX: the session group, then any orphan reparented here
    try: os.killpg(pid, signal.SIGKILL)  # FIX
    except ProcessLookupError: pass  # FIX
    me = os.getpid()  # FIX
    for c in open(f"/proc/{me}/task/{me}/children").read().split(): os.kill(int(c), signal.SIGKILL)  # FIX
for n in (signal.SIGTERM, signal.SIGHUP): signal.signal(n, lambda *_: (kill_all(), os._exit(143)))  # FIX
grace = float(os.environ.get("CTRL_C_GRACE", "60"))
end = time.monotonic() + float(os.environ.get("CTRL_C_DEADLINE", "300"))
st, late = 0, 0
while True:
    try: p, s = os.waitpid(-1, os.WNOHANG)
    except ChildProcessError: break
    if p == pid: st = s; end = min(end, time.monotonic() + grace)
    if p: continue
    if not late and time.monotonic() > end: late = 1; kill_all()  # FIX
    time.sleep(0.02)
sys.exit(124 if late else 128 + os.WTERMSIG(st) if os.WIFSIGNALED(st) else os.WEXITSTATUS(st))'
CTRL_C=(python3 -c "$CTRL_C_PY")
# marker: the processes of this test's Ctrl-C runs, by the SEED_MARK in their
# environment (never the box's other processes)
left() { grep -lsz "^SEED_MARK=$T/mark" /proc/[0-9]*/environ | wc -l; }
CTRL_C_PRE=()  # a command the wrapper runs under (the RED CONTROL's budget kill)
ctrl_c_seed() {  # <tmp-dir> [VAR=value ...] -> "rc=<rc> before='<ls>' after='<ls>'"
  local tmp="$1" before after rc; shift
  local -a w=("${CTRL_C[@]}"); [[ -z "${CTRL_C_RUN+x}" ]] || w=("${CTRL_C_RUN[@]}")
  mkdir -p "$tmp"; before=$(ls -A "$tmp"); : >"$T/cfgs"
  run_seed DRY_RUN=0 GC_INTERRUPT=1 TMPDIR="$tmp" SEED_MARK="$T/mark" "$@" "${CTRL_C_PRE[@]}" "${w[@]}" >/dev/null; rc=$?
  after=$(ls -A "$tmp")
  echo "rc=$rc before='$before' after='$after'"
}
# fd 7 stands for the runner's tee pipe: the session must not inherit it
got=$(ctrl_c_seed "$T/tmp" GC_FDS="$T/fds" 7>/dev/null)
[[ "$got" == "rc=130 before='' after=''" && -s "$T/cfgs" ]] \
  && pass "Ctrl-C at activate: the throwaway config is removed (temp root empty before and after)" \
  || fail "Ctrl-C: $got"
[[ "$(left)" == 0 ]] && pass "Ctrl-C: no process of its session is left" || fail "Ctrl-C left $(left) process(es)"
[[ -s "$T/fds" ]] && ! grep -qx 7 "$T/fds" && pass "Ctrl-C: the session does not hold the runner's fd 7" \
  || fail "Ctrl-C session fds: $(tr '\n' ' ' <"$T/fds")"
# A process of the group survives the Ctrl-C and spins: it is killed
# CTRL_C_GRACE s after the action's shell exits, nothing is left.
got=$(ctrl_c_seed "$T/tmp-spin" GC_SPIN="$T/stop-spin" CTRL_C_GRACE=2); touch "$T/stop-spin"
[[ "$got" == "rc=124 before='' after=''" && "$(left)" == 0 ]] \
  && pass "Ctrl-C with a spinning survivor: it is killed, nothing is left (rc 124)" \
  || fail "Ctrl-C spin: $got left=$(left)"
# RED CONTROL: the wrapper without its FIX lines, SIGKILLed once the spinner
# runs (as the hook's time budget killed it), leaves the spinner behind and
# hands it the runner's fd 7.
CTRL_C_RUN=(python3 -c "$(grep -v '# FIX' <<<"$CTRL_C_PY")")
CTRL_C_PRE=(bash -c 'w=$1; shift; "$@" & p=$!
  for _ in $(seq 1 3000); do [[ -e $w ]] && break; sleep 0.1; done; sleep 0.5; kill -KILL $p; wait $p' _ "$T/fds-nofix")
got=$(ctrl_c_seed "$T/tmp-nofix" GC_SPIN="$T/stop-nofix" GC_FDS="$T/fds-nofix" 7>/dev/null)
nofix_left=$(left)
[[ "${CTRL_C_RUN[2]}" != "$CTRL_C_PY" && "$got" == "rc=137 "* && "$nofix_left" -ge 1 && $(grep -cx 7 "$T/fds-nofix") == 1 ]] \
  && pass "RED CONTROL: without the fix the spinner outlives the wrapper ($nofix_left left) and holds fd 7" \
  || fail "RED CONTROL nofix: $got left=$nofix_left fds=$(tr '\n' ' ' <"$T/fds-nofix" 2>/dev/null)"
unset CTRL_C_RUN; CTRL_C_PRE=()
touch "$T/stop-nofix"  # the planted spinner stops itself; no kill by pid
for _ in $(seq 1 600); do [[ "$(left)" == 0 ]] && break; sleep 0.2; done
[[ "$(left)" == 0 ]] && pass "the control's spinner is gone once told to stop" || fail "control spinner still left: $(left)"
# CONTROL: the same Ctrl-C on a copy of the action without its trap leaves the
# throwaway config behind, so the check above can see a missing trap.
sed "/trap 'rm -rf \"\$cfg\"' EXIT/d" "$PROJ_ROOT/src/bash/run/spl-auth-idp-secret-seed.func.sh" >"$T/no-trap.func.sh"
got=$(ctrl_c_seed "$T/tmp-no-trap" SEED_FUNC="$T/no-trap.func.sh")
! grep -q "trap " "$T/no-trap.func.sh" && [[ "$got" == "rc=130 before='' after='tmp."* ]] \
  && pass "CONTROL: without the trap the Ctrl-C leaves the throwaway config" \
  || fail "CONTROL no-trap: $got"

n=$(adds)
out=$(run_seed DRY_RUN=0)
[[ $(adds) -eq $n && "$out" == *"nothing to add"* ]] && pass "a re-run adds nothing (idempotent)" || fail "re-run added: $(adds) vs $n"

owner_file linkedin "$LID" "$SECRET-rotated"
out=$(run_seed DRY_RUN=0)
[[ "$(cat "$T/store/$LS")" == "$SECRET-rotated" ]] && pass "a rotated secret is re-added" || fail "rotation: $out"

refused() {  # <label> <expect-substring> [VAR=value ...]
  local label="$1" want="$2"; shift 2
  local n; n=$(adds)
  out=$(run_seed DRY_RUN=0 "$@"); rc=$?
  [[ $rc -ne 0 && $(adds) -eq $n && "$out" == *"$want"* ]] && pass "refused: $label" || fail "$label: rc=$rc adds=$(adds)/$n $out"
}
owner_file linkedin "$LID" "$SECRET" 644;         refused "a group/world-readable owner file" "mode 0600"
owner_file linkedin "other-id" "$SECRET";         refused "a client_id that differs from cnf" "differs from cnf"
owner_file linkedin "$LID" "";                    refused "an empty client_secret" "no client_secret"
owner_file linkedin "$LID" " $SECRET";            refused "whitespace around the secret" "whitespace"
printf 'not json' >"$CD/linkedin-client-dev.json"; chmod 600 "$CD/linkedin-client-dev.json"
refused "a malformed owner file" "not a JSON object"
rm -f "$CD/linkedin-client-dev.json";             refused "no owner file" "no owner file"
owner_file linkedin "$LID" "$SECRET"
refused "an unknown IDP" "IDP must be" IDP=google
refused "a bad DRY_RUN" "DRY_RUN must be" DRY_RUN=yes
# cnf still at PLACEHOLDER- -> refused, naming the public id to commit
APP_OVERRIDE="$PH" refused "a placeholder cnf client id (names the id to commit)" "commit '$LID'"

# microsoft: a bare GUID is the Azure Secret ID, not the Value (request from 018)
owner_file microsoft "$MID" "1b2c3d4e-aaaa-bbbb-cccc-0123456789ab"
refused "a Microsoft Secret ID (bare GUID) instead of the Value" "Secret ID" IDP=microsoft
owner_file microsoft "$MID" "Abc8Q~valueLooksLikeThis.xyz"
out=$(run_seed DRY_RUN=0 IDP=microsoft); rc=$?
[[ $rc -eq 0 && "$(cat "$T/store/$MS" 2>/dev/null)" == "Abc8Q~valueLooksLikeThis.xyz" ]] \
  && pass "CONTROL: a Microsoft secret Value is admitted into the microsoft slot" || fail "microsoft value: rc=$rc $out"

echo
(( fails == 0 )) && echo "auth-idp-secret-seed: ALL PASS" || { echo "auth-idp-secret-seed: $fails FAIL"; exit 1; }
