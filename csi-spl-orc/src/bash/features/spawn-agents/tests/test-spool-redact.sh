#!/usr/bin/env bash
# spool_redact.py: every credential class this box holds or handles is
# replaced before a mirror post or a session export leaves the box
# (specs/017 FR-SEC-032, specs/036). One row per class; the prose and
# look-alike rows are the controls that keep the pass from eating real text.
#
# Every fixture is ASSEMBLED at run time: a literal key header or a literal
# token in a tracked file trips no-key-material-in-tree.tst.sh and the
# secret scanners, which is exactly what they are for.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
REDACT="$T_FEAT/lib/spool_redact.py"

rep() { printf "${1}%.0s" $(seq 1 "$2"); }  # CHAR N
red() { printf '%s' "$1" | python3 "$REDACT" 2>"$T_TMP/counts"; }

# kind | secret part (must vanish) | text around it
BEGIN="-----BEGIN"; END="-----END"; PK="PRIVATE KEY"
B64L="$(rep A 64)"
ED="$(rep Q 86)=="
UPB64="$(printf "%s:%s" fixture-user "$(rep z 8)" | base64)"
rows=(
  "slack-token|xoxb-$(rep 1 12)|token in chat xoxb-$(rep 1 12) end"
  "github-token|ghp_$(rep a 24)|gh ghp_$(rep a 24)"
  "gitlab-token|glpat-$(rep b 20)|gl glpat-$(rep b 20)"
  "npm-token|npm_$(rep c 36)|npm npm_$(rep c 36)"
  "aws-key-id|AKIA$(rep B 16)|aws AKIA$(rep B 16)"
  "google-api-key|AIza$(rep d 33)|g AIza$(rep d 33)"
  "google-oauth-secret|GOCSPX-$(rep e 28)|client GOCSPX-$(rep e 28)"
  "google-access-token|ya29.$(rep f 40)|at ya29.$(rep f 40)"
  "google-refresh-token|1//0$(rep g 40)|rt 1//0$(rep g 40)"
  "api-key|sk-ant-api03-$(rep h 40)|anthropic sk-ant-api03-$(rep h 40)"
  "api-key|xai-$(rep i 40)|grok xai-$(rep i 40)"
  "stripe-key|sk_live_$(rep j 24)|stripe sk_live_$(rep j 24)"
  "stripe-key|rk_test_$(rep k 24)|stripe rk_test_$(rep k 24)"
  "stripe-webhook-secret|whsec_$(rep l 32)|hook whsec_$(rep l 32)"
  "private-key|$B64L|$BEGIN OPENSSH $PK-----
$B64L
$END OPENSSH $PK-----"
  "private-key|$B64L|$BEGIN PGP $PK BLOCK-----

$B64L
$END PGP $PK BLOCK-----"
  "private-key|$B64L|cut short: $BEGIN RSA $PK-----
$B64L
$B64L"
  "private-key|$(rep m 30)|{\"private$(printf '_key')\": \"$(rep m 30)\"}"
  "ed25519-private-key|$ED|cat box.key -> $ED"
  "dsn-password|hunter2x|dsn postgres://u:hunter2x@db:5432/x"
  "url-password|s3cretpass|clone https://bot:s3cretpass@git.example.com/r.git"
  "signed-url|$(rep 0 64)|get https://storage.example.com/b/o?X-Goog-Expires=900&X-Goog-Signature=$(rep 0 64)"
  "bearer|$(rep n 32)|send it as Bearer $(rep n 32) next time"
  "cookie|$(rep o 32)|Cookie: __session=$(rep o 32); path=/"
  "json-secret|$(rep p 20)|{\"client_secret\": \"$(rep p 20)\"}"
  "json-secret|$(rep q 20)|{\"access_token\":\"$(rep q 20)\"}"
  "assignment|$(rep r 20)|export AWS_SECRET_ACCESS_KEY=$(rep r 20)"
  "assignment|supersecret1|pw=supersecret1"
  "password|hunter2|password: hunter2"
  "password|abc12|Password=abc12"
  "password|hunter2|pwd: hunter2"
  "password|pass word|{\"password\": \"pass word\"}"
  "password|x1|export DB_PASSWORD='x1'"
  "authorization|$UPB64|header Authorization: Basic $UPB64"
  "authorization|abc123def|authorization: token abc123def"
  "github-token|gho_$(rep a 24)|oauth gho_$(rep a 24)"
  "github-token|github_pat_$(rep a 24)|pat github_pat_$(rep a 24)"
  "slack-token|xoxp-$(rep 2 12)|user xoxp-$(rep 2 12)"
  "slack-token|xoxa-$(rep 3 12)|app xoxa-$(rep 3 12)"
  "typed-password|Tr0ub4dor&3x|ok, the password is Tr0ub4dor&3x, log in now"
  "typed-password|Hunter2!xq|my pw for HUM-1 was 'Hunter2!xq'"
  "jwt|eyJ$(rep x 12).$(rep y 12).$(rep z 12)|jwt eyJ$(rep x 12).$(rep y 12).$(rep z 12)"
)
for row in "${rows[@]}"; do
  kind="${row%%|*}"; rest="${row#*|}"; secret="${rest%%|*}"; text="${rest#*|}"
  out="$(red "$text")"
  hasnt "${kind}: the secret is gone (${secret:0:8}…)" "$secret" "$out"
  has   "${kind}: the counts name the class" "\"${kind}\"" "$(cat "$T_TMP/counts")"
done

# ---- controls: text that looks close and must survive ---------------------
same() {  # DESC TEXT
  eq "CONTROL: $1" "$2" "$(red "$2")"
}
same "prose"                    "Ship it on Friday: the PR is green, 3 files changed."
same "a git sha"                "landed 0680458c9d3e2f1a7b6c5d4e3f2a1b0c9d8e7f6a on trunk"
same "a sha256"                 "sha256 $(rep 9 64)"
same "a uuid topic"             "topic f4ff5779-3376-48a1-85a9-62010c6ceb5c"
same "an ed25519 PUBLIC key"    "box_pubkey $(rep Q 43)="
same "a URL with no credentials" "https://api.example.com/v1/view/topics/abc?order=asc&limit=50"
# OWNER RULE (HUM-10, 2026-10-01): password: <value> is hard-redacted, marker [redacted].
eq "owner rule: password: hunter2 -> password: [redacted]" "password: [redacted]" "$(red "password: hunter2")"
eq "owner rule: PASSWORD = x (any case, =, any length)" "PASSWORD = [redacted]" "$(red "PASSWORD = x")"
same "password reset flow"      "password reset flow works"
same "a password in prose"      "the password is incorrect. Reset the password is now possible."
same "a token budget"           "token: 400 left"
same "a key header in prose"    "look for the words PRIVATE KEY in the file"
out="$(red "$BEGIN RSA $PK-----
$B64L
Then the prose after it stays.")"
has "CONTROL: a cut-short key does not swallow the next prose line" "Then the prose after it stays." "$out"
out="$(red "dsn postgres://u:hunter2x@db")"
eq "a DSN is counted once, not twice" '{"redactions": {"dsn-password": 1}}' "$(cat "$T_TMP/counts")"

t_done
