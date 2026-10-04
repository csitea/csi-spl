#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 014 T022 do_spl_wui_key_seed and spec 015 T015
#          do_spl_mail_secret_seed, CALLED against a stubbed gcloud with a
#          file-backed secret store (as auth-secrets-seed.tst.sh):
#          - wui key: dry run adds nothing; DRY_RUN=0 adds ONE version that is a
#            base64 64-byte Ed25519 private key; a re-run never rotates it; the
#            private key is in no output and no gcloud argv; a missing slot is
#            refused.
#          - mail: no owner file / a non-0600 file / a placeholder cnf / a
#            non-starttls cnf are refused; a failing relay probe stores
#            nothing (CONTROL); the stored version is the file with whitespace
#            dropped; the password is in no output and no gcloud argv; every
#            gcloud call carries --account.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
mkdir -p "$T/store" "$T/home/.gcp/.csi/.spl" "$T/bin"

# stub spool: `keygen --box box-wui` writes a base64 64-byte key, prints a pubkey
cat >"$T/bin/spool" <<'SH'
#!/usr/bin/env bash
[[ "$1" == keygen && "$3" == box-wui ]] || exit 2
mkdir -p "$SPOOL_KEYS_DIR"
head -c 64 /dev/urandom | base64 -w0 >"$SPOOL_KEYS_DIR/box-box-wui.key"; echo >>"$SPOOL_KEYS_DIR/box-box-wui.key"
head -c 32 /dev/urandom | base64 -w0; echo
SH
# stub curl: the relay probe fails when PROBE_FAIL=1
cat >"$T/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$ARGV.curl"
[[ "${PROBE_FAIL:-0}" == 1 ]] && { echo "curl: (67) Login denied" >&2; exit 67; }
exit 0
SH
chmod +x "$T/bin/spool" "$T/bin/curl"

run_act() {  # <action> [VAR=value ...]
  local act="$1"; shift
  env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" SPL_STATE_DIR="$T/state" \
      STORE="$T/store" ARGV="$T/argv" SPOOL_BIN="$T/bin/spool" ENV="${ENV_:-prd}" GCP_ACCOUNT=stub-sa@example.com \
      CNF_OVERRIDE="${CNF_OVERRIDE:-}" ACT="$act" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    gcloud() {
      echo "$*" >>"$ARGV"
      case "$*" in
        "auth print-access-token"*) echo "ya29.stub_token_value_long_enough" ;;
        "secrets describe "*) [[ "${NO_SLOT:-0}" == 1 ]] && return 1; return 0 ;;
        "secrets versions list "*) local s="$4"; [[ -f "$STORE/$s" ]] && echo "projects/x/secrets/$s/versions/1"; return 0 ;;
        "secrets versions access latest --secret="*)
          local s="${5#--secret=}"; [[ -f "$STORE/$s" ]] || return 1; cat "$STORE/$s" ;;
        "secrets versions add "*)
          local s="$4" df; for a in "$@"; do [[ "$a" == --data-file=* ]] && df="${a#--data-file=}"; done
          if [[ "$df" == - ]]; then cat >"$STORE/$s"; else cat "$df" >"$STORE/$s"; fi
          echo add "$s" >>"$STORE/.adds" ;;
        *) return 0 ;;
      esac
    }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    if [[ -n "$CNF_OVERRIDE" ]]; then
      eval "$(declare -f do_spl_cloud_cnf | sed "1s/do_spl_cloud_cnf/_orig_cloud_cnf/")"
      do_spl_cloud_cnf() { _orig_cloud_cnf || return 1; yq -i "$CNF_OVERRIDE" "$SPL_CNF"; }
    fi
    "$ACT"' 2>&1
}
adds() { grep -c . "$T/store/.adds" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------- wui key ----
WK=csi-spl-hub-wui-key
out=$(run_act do_spl_wui_key_seed); rc=$?
[[ $rc -eq 0 && $(adds) -eq 0 ]] && pass "wui key: default is a dry run, nothing added" || fail "wui dry run: rc=$rc adds=$(adds) $out"
out=$(NO_SLOT=1 run_act do_spl_wui_key_seed DRY_RUN=0 NO_SLOT=1); rc=$?
[[ $rc -ne 0 && $(adds) -eq 0 ]] && pass "wui key: a missing 030 slot is refused" || fail "wui no slot: rc=$rc $out"
out=$(run_act do_spl_wui_key_seed DRY_RUN=0); rc=$?
[[ $rc -eq 0 && -f "$T/store/$WK" ]] && pass "wui key: DRY_RUN=0 adds the first version" || fail "wui real run: rc=$rc $out"
[[ "$(tr -d '\n' <"$T/store/$WK" | base64 -d 2>/dev/null | wc -c)" -eq 64 ]] && pass "wui key: the version is a base64 64-byte ed25519 private key" || fail "wui key size"
key="$(tr -d '\n' <"$T/store/$WK")"
grep -qF "$key" <<<"$out" && fail "wui key: the private key appears in the output" || pass "wui key: no private key in the output"
grep -qF "$key" "$T/argv" && fail "wui key: the private key appears in gcloud argv" || pass "wui key: no private key in gcloud argv"
grep -q '"pubkey":"' <<<"$out" && pass "wui key: prints the public key" || fail "wui key: no pubkey printed: $out"
n=$(adds); out=$(run_act do_spl_wui_key_seed DRY_RUN=0)
[[ $(adds) -eq $n && "$(tr -d '\n' <"$T/store/$WK")" == "$key" ]] && pass "wui key: a re-run keeps the key (never rotated here)" || fail "wui key rotated on re-run"

# ------------------------------------------------------------------- mail ----
MS=csi-spl-hub-mail-smtp-password
PWF="$T/home/.gcp/.csi/.spl/smtp-app-password.txt"
PW="abcd efgh ijkl m$RANDOM"
out=$(run_act do_spl_mail_secret_seed DRY_RUN=0); rc=$?
[[ $rc -ne 0 && $(adds) -eq $n ]] && pass "mail: no owner file is refused" || fail "mail no file: rc=$rc $out"
printf '%s\n' "$PW" >"$PWF"; chmod 644 "$PWF"
out=$(run_act do_spl_mail_secret_seed DRY_RUN=0); rc=$?
[[ $rc -ne 0 && $(adds) -eq $n ]] && pass "mail: a non-0600 owner file is refused" || fail "mail 0644: rc=$rc $out"
chmod 600 "$PWF"
# dev relays for real since CLE-3411 (010 FR-016), so the placeholder is set here
out=$(CNF_OVERRIDE='.env.mail.env.SPOOL_HUB_MAIL_SMTP_HOST = "PLACEHOLDER-smtp-host"' ENV_=dev run_act do_spl_mail_secret_seed DRY_RUN=0); rc=$?
[[ $rc -ne 0 && $(adds) -eq $n ]] && pass "mail: a placeholder relay cnf is refused" || fail "mail placeholder: rc=$rc $out"
out=$(CNF_OVERRIDE='.env.mail.env.SPOOL_HUB_MAIL_SMTP_TLS = "none"' run_act do_spl_mail_secret_seed DRY_RUN=0); rc=$?
[[ $rc -ne 0 && $(adds) -eq $n ]] && pass "mail: a relay cnf without starttls is refused" || fail "mail tls none: rc=$rc $out"
out=$(run_act do_spl_mail_secret_seed DRY_RUN=0 SMTP_TEST_RCPT=ops@example.com PROBE_FAIL=1); rc=$?
[[ $rc -ne 0 && $(adds) -eq $n && ! -f "$T/store/$MS" ]] && pass "mail CONTROL: a failing relay probe stores nothing" || fail "mail probe fail: rc=$rc $out"
grep -q -- '--ssl-reqd' "$T/argv.curl" && pass "mail: the probe requires STARTTLS (--ssl-reqd)" || fail "mail probe lacks --ssl-reqd"
out=$(run_act do_spl_mail_secret_seed DRY_RUN=0 SMTP_TEST_RCPT=ops@example.com); rc=$?
[[ $rc -eq 0 && "$(cat "$T/store/$MS")" == "${PW// /}" ]] && pass "mail: probe ok, the version is the password without whitespace" || fail "mail real run: rc=$rc $out"
if grep -qF "${PW// /}" <<<"$out" || grep -qF "${PW// /}" "$T/argv" "$T/argv.curl"; then fail "mail: the password appears in output or argv"; else pass "mail: no password in output, gcloud or curl argv"; fi
n=$(adds); out=$(run_act do_spl_mail_secret_seed DRY_RUN=0)
[[ $(adds) -eq $n ]] && pass "mail: a re-run with the same password adds nothing" || fail "mail re-run added"

[[ $(grep -vc -- '--account=stub-sa@example.com' "$T/argv") -eq 0 ]] && pass "every gcloud call carries --account" || fail "unpinned gcloud call: $(grep -v -- '--account=' "$T/argv" | sed -n 1,2p)"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
