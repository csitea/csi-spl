#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_wine_box_vnc_password, offline, throwaway HOME, stub ssh:
#   1. DRY_RUN (default) mints the 0600 file in a 0700 dir and calls no ssh.
#   2. The password: 8 chars, upper + lower + digit, no confusable characters; a second
#      run reuses it, WINE_BOX_VNC_ROTATE=1 mints a new one.
#   3. DRY_RUN=0: ssh through the IAP ProxyCommand with --account; the
#      password reaches ssh on stdin only, never argv or the output.
#   4. It fails when SHA_BOX differs or the handshake verdicts are missing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
export PROJ_PATH="$PROJ_ROOT"
fails=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/.ssh/.t"
unset DRY_RUN ACCOUNT GCP_ACCOUNT WINE_BOX_VNC_PASS_FILE WINE_BOX_VNC_ROTATE
export WINE_BOX_CNF_FILE="$T/dev.env.yaml"
cat >"$WINE_BOX_CNF_FILE" <<'EOF'
env:
  steps:
    061-gcp-vm-wine-box:
      gcp_project: test-proj
      vm_name: test-wine-box
      gcp_zone: europe-west2-a
      os_user: debian
      desktop_user: wine
      vnc_port: 5901
      vnc_passwd_bin: /usr/bin/vncpasswd
      ssh_public_key_file: ~/.ssh/.t/debian@test-wine-box.pub
EOF
touch "$HOME/.ssh/.t/debian@test-wine-box"
do_log() { echo "$*"; }
do_gcp_pin_account() { GCP_ACCOUNT=sa@test-proj.iam.gserviceaccount.com; export GCP_ACCOUNT; }
mkdir -p "$T/bin"
printf '#!/bin/bash\nexit 0\n' >"$T/bin/gcloud"
# The stub box: records argv and stdin, answers with the sha of what it got.
cat >"$T/bin/ssh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/ssh.argv"
cat > "$T/ssh.stdin"
[[ "\${FAKE_BOX:-ok}" == badsha ]] && { echo SHA_BOX=000000000000; echo VNC_AUTH_GOOD=accepted; echo VNC_AUTH_WRONG=rejected; exit 0; }
echo "SHA_BOX=\$(sha256sum "$T/ssh.stdin" | cut -c1-12)"
[[ "\${FAKE_BOX:-ok}" == noauth ]] && { echo VNC_AUTH_GOOD=rejected; echo VNC_AUTH_WRONG=rejected; exit 3; }
echo VNC_AUTH_GOOD=accepted
echo VNC_AUTH_WRONG=rejected
EOF
chmod +x "$T/bin/gcloud" "$T/bin/ssh"
export PATH="$T/bin:$PATH"
# shellcheck disable=SC1091
source "$PROJ_ROOT/lib/bash/funcs/wine-box.func.sh"
# shellcheck disable=SC1091
source "$PROJ_ROOT/src/bash/run/spl-wine-box-vnc-password.func.sh"

f="$HOME/.secrets/csi-spl/wine-box-vnc.test-wine-box.pass"
out=$(do_spl_wine_box_vnc_password 2>&1)
[[ -f "$f" && "$(stat -c %a "$f")" == 600 && "$(stat -c %a "$(dirname "$f")")" == 700 ]] \
  && pass "DRY_RUN mints the file 0600 in a 0700 dir" || fail "file or dir mode wrong: $out"
[[ ! -e "$T/ssh.argv" ]] && pass "DRY_RUN calls no ssh" || fail "DRY_RUN called ssh"
pw=$(head -n1 "$f")
[[ ${#pw} == 8 && "$pw" =~ [A-Z] && "$pw" =~ [a-z] && "$pw" =~ [0-9] && ! "$pw" =~ [0O1lI] && "$pw" =~ ^[A-Za-z0-9]+$ ]] \
  && pass "8 characters, upper + lower + digit, no confusable characters" || fail "weak or malformed password"
grep -qF -- "$pw" <<<"$out" && fail "DRY_RUN printed the password" || pass "DRY_RUN never prints the password"
grep -q "SHA_LOCAL=$(sha256sum "$f" | cut -c1-12)" <<<"$out" && pass "prints the sha prefix" || fail "no SHA_LOCAL: $out"
( do_spl_wine_box_vnc_password ) >/dev/null 2>&1
[[ "$(head -n1 "$f")" == "$pw" ]] && pass "a second run reuses the password" || fail "a second run re-minted it"
( WINE_BOX_VNC_ROTATE=1 do_spl_wine_box_vnc_password ) >/dev/null 2>&1
[[ "$(head -n1 "$f")" != "$pw" && "$(stat -c %a "$f")" == 600 ]] && pass "ROTATE=1 mints a new one, 0600" || fail "ROTATE=1 did not rotate"
pw=$(head -n1 "$f")

out=$(DRY_RUN=0 do_spl_wine_box_vnc_password 2>&1); rc=$?
(( rc == 0 )) && grep -q '^OK test-wine-box' <<<"$out" && pass "DRY_RUN=0 sets and proves" || fail "DRY_RUN=0 rc=$rc: $out"
grep -q 'ProxyCommand=gcloud compute start-iap-tunnel test-wine-box 22 --listen-on-stdin' "$T/ssh.argv" \
  && grep -q -- '--account=sa@test-proj.iam.gserviceaccount.com' "$T/ssh.argv" && grep -q 'debian@test-wine-box' "$T/ssh.argv" \
  && pass "ssh through the IAP tunnel with the pinned account" || fail "ssh argv: $(cat "$T/ssh.argv")"
[[ "$(head -n1 "$T/ssh.stdin")" == "$pw" ]] && pass "the password goes on ssh stdin" || fail "stdin did not carry the password"
grep -qF -- "$pw" "$T/ssh.argv" && fail "the password is in the ssh argv" || pass "the password is not in argv"
grep -qF -- "$pw" <<<"$out" && fail "DRY_RUN=0 printed the password" || pass "DRY_RUN=0 never prints the password"
grep -q 'DUSER=wine PORT=5901 PWBIN=/usr/bin/vncpasswd' "$T/ssh.argv" && pass "the box gets user, port and vncpasswd from cnf" || fail "remote env missing"

if ( FAKE_BOX=badsha DRY_RUN=0 do_spl_wine_box_vnc_password ) >/dev/null 2>&1; then fail "accepted a SHA_BOX mismatch"; else pass "a SHA_BOX mismatch fails"; fi
if ( FAKE_BOX=noauth DRY_RUN=0 do_spl_wine_box_vnc_password ) >/dev/null 2>&1; then fail "accepted a refused handshake"; else pass "a refused handshake fails"; fi
printf 'short\n' >"$f"
if ( do_spl_wine_box_vnc_password ) >/dev/null 2>&1; then fail "reused a short password"; else pass "refuses a file that is not 8 characters"; fi

# The remote script parses, and its prover is valid python.
bash -n <(_wine_box_vnc_remote_script) && pass "the remote script parses" || fail "the remote script has a syntax error"
_wine_box_vnc_remote_script | sed -n "/^python3 - /,/^PY$/p" | sed '1d;$d' >"$T/prover.py"
python3 -m py_compile "$T/prover.py" && pass "the prover compiles" || fail "the prover does not compile"

declare -f do_spl_wine_box_vnc_password >/dev/null && pass "registered do_spl_wine_box_vnc_password" || fail "not registered"

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
