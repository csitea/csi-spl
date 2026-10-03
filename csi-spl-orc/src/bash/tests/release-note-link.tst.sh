#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_release_note_link (spec 065 L7) prints `<sha> v<X.Y.Z> <link>`,
#          the link host read from the cnf. Against a SYNTHETIC repo that
#          carries a copy of this repo's cnf (no network, no GCP):
#   1. a tagged commit -> the FIRST v-tag that contains it, the dev WUI host
#   2. ENV=prd -> the prd WUI host, not the dev one
#   3. CONTROL: BASE_DOMAIN changed in the copied cnf -> the link follows it
#      (the host comes from the cnf, not from the code)
#   4. a commit no v-tag contains -> `unreleased`, a WARN, rc 0
#   5. an unknown sha -> FATAL, rc 1, nothing on stdout
#   6. SHA not hex / missing, ENV not dev|prd -> rc 1
#   7. no literal host in the action: the cnf's BASE_DOMAIN, read here at run
#      time, is absent from the .func.sh, and no https:// is followed by text
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ACTION="$PROJ_ROOT/src/bash/run/release-note-link.func.sh"
CNF_SRC="$APP_ROOT/csi-spl-cnf/csi-spl"
IAC_LIB="$APP_ROOT/csi-spl-iac/lib/bash/funcs"

# --- a synthetic repo shaped like this one: the cnf + the iac merge lib -------
REPO="$T/repo"
mkdir -p "$REPO/csi-spl-cnf/csi-spl" "$REPO/csi-spl-iac/lib/bash/funcs"
cp "$CNF_SRC"/all.env.yaml "$CNF_SRC"/dev.env.yaml "$CNF_SRC"/prd.env.yaml "$REPO/csi-spl-cnf/csi-spl/"
cp "$IAC_LIB"/spl-merged-cnf.func.sh "$IAC_LIB"/gcp-require-live-account.func.sh "$REPO/csi-spl-iac/lib/bash/funcs/"
git -C "$REPO" init -q -b master
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name "FirstName LastName"
commit() {  # <message> -> full sha
  echo "$1" >>"$REPO/f.txt"; git -C "$REPO" add f.txt && git -C "$REPO" commit -qm "$1" && git -C "$REPO" rev-parse HEAD
}
C1=$(commit "fix(wui): one")
C2=$(commit "feat(hub): two")
C3=$(commit "perf(hub): three")
C4=$(commit "docs: four, not deployed yet")
git -C "$REPO" tag v1.0.1 "$C2"
git -C "$REPO" tag v1.0.2 "$C3"
git -C "$REPO" tag v1.0.0-junk "$C1"   # not d.d.d: ignored

# the WUI host the cnf names for an env, through the same merge the action uses
cnf_fqdn() {  # <env> <state dir>
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$REPO" SPL_STATE_DIR="$2" ENV="$1" bash -c '
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf >/dev/null && echo "$SPL_FQDN"'
}
# act <env...> -> stdout = the action's stdout; stderr in $T/err; rc kept
act() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$REPO" SPL_STATE_DIR="$T/state" RELEASE_REMOTE=no-such-remote "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }   # to stdout, as ./run prints it: the action must redirect
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || return 1; done; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_release_note_link' 2>"$T/err"
}
LINE_RE='^[0-9a-f]{8} (v[0-9]+\.[0-9]+\.[0-9]+|unreleased) https://[^ /]+/releases/[0-9a-f]{40}$'

DEV_FQDN=$(cnf_fqdn dev "$T/s-dev"); PRD_FQDN=$(cnf_fqdn prd "$T/s-prd")
if [[ -n "$DEV_FQDN" && -n "$PRD_FQDN" && "$DEV_FQDN" != "$PRD_FQDN" ]]; then pass "cnf names a dev and a prd WUI host, and they differ"
else fail "cnf hosts: dev '$DEV_FQDN' prd '$PRD_FQDN'"; fi

# --- 1. tagged commit, dev ---------------------------------------------------------
out=$(act SHA="${C1:0:10}" ENV=dev); rc=$?
want="${C1:0:8} v1.0.1 https://$DEV_FQDN/releases/$C1"
[[ $rc == 0 && "$out" == "$want" ]] && pass "C1 -> the first v-tag containing it (v1.0.1, not v1.0.2), dev host" \
  || fail "C1 dev: rc $rc out '$out' want '$want' err '$(cat "$T/err")'"
grep -qE "$LINE_RE" <<<"$out" && [[ $(wc -l <<<"$out") == 1 ]] && pass "stdout is exactly one <sha> v<X.Y.Z> <link> line" \
  || fail "line shape: '$out'"
out=$(act SHA="$C3" ENV=dev); rc=$?
[[ $rc == 0 && "$out" == "${C3:0:8} v1.0.2 https://$DEV_FQDN/releases/$C3" ]] && pass "C3 (full sha) -> v1.0.2" \
  || fail "C3: rc $rc out '$out'"

# --- 2. prd ------------------------------------------------------------------------
out=$(act SHA="$C2" ENV=prd); rc=$?
[[ $rc == 0 && "$out" == "${C2:0:8} v1.0.1 https://$PRD_FQDN/releases/$C2" ]] && pass "ENV=prd -> the prd WUI host" \
  || fail "C2 prd: rc $rc out '$out' err '$(cat "$T/err")'"

# --- 3. CONTROL: the host follows the cnf ------------------------------------------
yq -i '.env.dns.BASE_DOMAIN = "example.net"' "$REPO/csi-spl-cnf/csi-spl/all.env.yaml"
out=$(act SHA="$C2" ENV=prd SPL_STATE_DIR="$T/state-ctl"); rc=$?
ctl=$(cnf_fqdn prd "$T/s-ctl")
if [[ $rc == 0 && "$ctl" == *example.net && "$out" == "${C2:0:8} v1.0.1 https://$ctl/releases/$C2" ]]; then
  pass "CONTROL: BASE_DOMAIN example.net in the cnf -> the link host is $ctl"
else fail "CONTROL: rc $rc out '$out' cnf '$ctl'"; fi
cp "$CNF_SRC/all.env.yaml" "$REPO/csi-spl-cnf/csi-spl/all.env.yaml"

# --- 4. not deployed yet -----------------------------------------------------------
out=$(act SHA="$C4" ENV=dev); rc=$?
[[ $rc == 0 && "$out" == "${C4:0:8} unreleased https://$DEV_FQDN/releases/$C4" ]] && grep -q 'WARN .*no v-tag' "$T/err" \
  && pass "untagged commit -> unreleased + WARN, rc 0" || fail "C4: rc $rc out '$out' err '$(cat "$T/err")'"

# --- 5. unknown sha ----------------------------------------------------------------
out=$(act SHA=0123456789abcdef0123456789abcdef01234567 ENV=dev); rc=$?
[[ $rc == 1 && -z "$out" ]] && grep -q 'FATAL not a commit' "$T/err" && pass "unknown sha -> FATAL, rc 1, empty stdout" \
  || fail "unknown sha: rc $rc out '$out' err '$(cat "$T/err")'"

# --- 6. argument validation --------------------------------------------------------
for bad in "SHA=HEAD" "SHA=" "SHA=abc12" "SHA=zzzzzzzz"; do
  out=$(act "$bad" ENV=dev); rc=$?
  [[ $rc == 1 && -z "$out" ]] && pass "$bad -> rc 1" || fail "$bad: rc $rc out '$out'"
done
out=$(act SHA="$C1" ENV=lde); rc=$?
[[ $rc == 1 && -z "$out" ]] && pass "ENV=lde -> rc 1" || fail "ENV=lde: rc $rc out '$out'"

# --- 7. no literal host in the action ----------------------------------------------
base=$(yq -r '.env.dns.BASE_DOMAIN' "$CNF_SRC/all.env.yaml")
if [[ -n "$base" && "$base" != null ]] && ! grep -qiF "$base" "$ACTION" && ! grep -qE 'https://[A-Za-z0-9]' "$ACTION"; then
  pass "no literal host in release-note-link.func.sh (BASE_DOMAIN absent, no https://<text>)"
else fail "literal host in $ACTION: $(grep -nE "https://[A-Za-z0-9]|$base" "$ACTION")"; fi

echo "release-note-link: $fails failure(s)"
((fails == 0))
