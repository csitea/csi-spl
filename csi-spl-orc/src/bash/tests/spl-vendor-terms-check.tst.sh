#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: test do_spl_vendor_terms_check (spec 159 row T9, SPL-4097):
# monthly, fetch the nine URLs of spec 159 section 4.1, compare the quoted
# sentences, open an issue when one changes or goes missing.
#
# Red control: a page fixture with one quote edited -> issue opened; the same
# fixture unchanged -> none.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# 1. Manifest and script checks
grep -qE "^vendor-terms-check +\| [^|]+ +\| src/bash/scripts/vendor-terms-check-cron.sh +\| vendor-terms-check/cron.log" \
  "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" &&
  pass "1. the box-crons manifest carries the vendor-terms-check row" ||
  fail "1. vendor-terms-check row missing in box-crons.manifest"

[[ -x "$PROJ_ROOT/src/bash/scripts/vendor-terms-check-cron.sh" ]] &&
  pass "2. vendor-terms-check-cron.sh exists and is executable" ||
  fail "2. vendor-terms-check-cron.sh missing or not executable"

[[ -f "$PROJ_ROOT/src/bash/run/spl-vendor-terms-check.func.sh" ]] &&
  pass "3. spl-vendor-terms-check.func.sh exists" ||
  fail "3. spl-vendor-terms-check.func.sh missing"

# Setup test fixtures
mkdir -p "$T/fixtures" "$T/state/dev/desk/t1/box-desk/spool/CLE-00"

cat >"$T/fixtures/claude.html" <<'EOFIX'
<!DOCTYPE html>
<html>
<body>
<p>Each end user must authenticate with their own Anthropic API key, Claude subscription plan credentials, or 3P inference provider credential</p>
<p>Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, or Max plan credentials on behalf of their users.</p>
<p>Moreover, developers may not collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must complete through Anthropic’s own flow.</p>
<p>Nor does it prevent an end user from signing in to the unmodified Claude Code binary with their own Claude subscription, including where a platform hosts Claude Code</p>
<p><strong>Customers may not pay for, resell, or intermediate Claude usage on their end users’ behalf.</strong></p>
</body>
</html>
EOFIX

cat >"$T/fixtures/grok-consumer.html" <<'EOFIX'
<html><body>You may not share your account credentials or make your account available to anyone else</body></html>
EOFIX

cat >"$T/fixtures/grok-enterprise.html" <<'EOFIX'
<html><body>Customer will ensure that each Permitted User keeps its user credentials strictly confidential and does not share them with any unauthorized person.</body></html>
EOFIX

cat >"$T/fixtures/mistral-consumer.html" <<'EOFIX'
<html><body>You may not make your account credentials available to third parties</body></html>
EOFIX

cat >"$T/fixtures/mistral-commercial.html" <<'EOFIX'
<html><body>Section 2.2: (i) integrate or combine Vibe with your own products you offer to third-parties including any other software, hardware, or other technology, nor grant any third party access to the Mistral AI Products without our prior written authorization</body></html>
EOFIX

cat >"$T/fixtures/agy-gemini-cli.html" <<'EOFIX'
<html><body>Directly accessing the services powering Gemini CLI (for example, the Gemini Code Assist service) using third-party software, tools, or services (for example, using OpenClaw with Gemini CLI OAuth) is a violation of applicable terms and policies.</body></html>
EOFIX

cat >"$T/fixtures/agy-terms.html" <<'EOFIX'
<html><body>Using third party software, tools, or services to access the Service (e.g. using OpenClaw with Antigravity OAuth) is a breach of this Agreement.</body></html>
EOFIX

cat >"$T/fixtures/agy-api.html" <<'EOFIX'
<html><body><p>You may only access the Services (or make API Clients available to users) within an <a href="/available_regions">available region</a>.</p></body></html>
EOFIX

cat >"$T/fixtures/qwen.html" <<'EOFIX'
<html><body>
<p>free tier discontinued 2026-04-15</p>
<p>When using your own API key, you are subject to the terms and privacy policies of your chosen API provider</p>
</body></html>
EOFIX

# Setup fake fetcher script
cat >"$T/fakefetch" <<'EOFIX'
#!/bin/sh
url="$1"
case "$url" in
  *code.claude.com*) cat "$FIXTURES/claude.html" ;;
  *x.ai/legal/terms-of-service-enterprise*) cat "$FIXTURES/grok-enterprise.html" ;;
  *x.ai/legal/terms-of-service*) cat "$FIXTURES/grok-consumer.html" ;;
  *mistral.ai/terms/commercial*) cat "$FIXTURES/mistral-commercial.html" ;;
  *mistral.ai/terms/row*) cat "$FIXTURES/mistral-consumer.html" ;;
  *gemini-cli*) cat "$FIXTURES/agy-gemini-cli.html" ;;
  *antigravity.google*) cat "$FIXTURES/agy-terms.html" ;;
  *ai.google.dev*) cat "$FIXTURES/agy-api.html" ;;
  *qwen-code*) cat "$FIXTURES/qwen.html" ;;
  *) echo "Unknown URL: $url" >&2; exit 1 ;;
esac
EOFIX
chmod +x "$T/fakefetch"

# Setup fake issue creator script
cat >"$T/fakeissue" <<'EOFIX'
#!/bin/sh
printf "%s|" "$@" >>"$FAKE_LOG"
echo >>"$FAKE_LOG"
echo '{"key":"SPL-9999","ok":true}'
EOFIX
chmod +x "$T/fakeissue"

base=(
  VENDOR_TERMS_FETCH_CMD="$T/fakefetch"
  VENDOR_TERMS_ISSUE_CMD="$T/fakeissue"
  VENDOR_TERMS_EPIC="SPL-2398"
  VENDOR_TERMS_DISCUSSIONS="f8f9dfcc-659a-480d-bc7f-1cffd5fb38b9"
  FIXTURES="$T/fixtures"
  FAKE_LOG="$T/issue.log"
  TENANT_ID="t1"
  DESK_AGENT="c-001"
)

# Test 4: Unchanged fixtures -> NO issue opened
: >"$T/issue.log"
out=$(SNIPPET="do_spl_vendor_terms_check" in_orc "${base[@]}" DRY_RUN=0 2>&1)
rc=$?
if [[ $rc -eq 0 && ! -s "$T/issue.log" && "$out" == *"OK"* ]]; then
  pass "4. unchanged fixtures -> 0 issues opened, clean exit"
else
  fail "4. unchanged fixtures failed (rc=$rc): $out; issue log: $(cat "$T/issue.log")"
fi

# Test 5: RED CONTROL - a page fixture with one quote edited -> issue opened
sed -i "s/You may not share/You are welcome to share/" "$T/fixtures/grok-consumer.html"

# In DRY_RUN=1: plan logged, no issue command executed
: >"$T/issue.log"
out_dry=$(SNIPPET="do_spl_vendor_terms_check" in_orc "${base[@]}" DRY_RUN=1 2>&1)
rc_dry=$?
if [[ $rc_dry -eq 1 && ! -s "$T/issue.log" && "$out_dry" == *"PLAN"* ]]; then
  pass "5. red control dry run -> plans issue, calls no issue command"
else
  fail "5. red control dry run failed (rc=$rc_dry): $out_dry; issue log: $(cat "$T/issue.log")"
fi

# In DRY_RUN=0: issue command IS executed
: >"$T/issue.log"
out_live=$(SNIPPET="do_spl_vendor_terms_check" in_orc "${base[@]}" DRY_RUN=0 2>&1)
rc_live=$?
if [[ $rc_live -eq 1 && -s "$T/issue.log" && "$out_live" == *"ISSUE"* ]]; then
  pass "6. red control live -> issue opened when quote edited"
else
  fail "6. red control live failed (rc=$rc_live): $out_live; issue log: $(cat "$T/issue.log")"
fi

# Verify the issue call details
if grep -q "SPL-2398" "$T/issue.log" &&
   grep -q "159-byo-ai-keys" "$T/issue.log" &&
   grep -q "f8f9dfcc" "$T/issue.log"; then
  pass "7. opened issue cites epic SPL-2398, spec 159, and topic"
else
  fail "7. opened issue missing required epic, spec, or topic: $(cat "$T/issue.log")"
fi

# Test 8: Missing quote (quote removed completely) -> issue opened
sed -i "/You are welcome to share/d" "$T/fixtures/grok-consumer.html"
: >"$T/issue.log"
out_missing=$(SNIPPET="do_spl_vendor_terms_check" in_orc "${base[@]}" DRY_RUN=0 2>&1)
rc_missing=$?
if [[ $rc_missing -eq 1 && -s "$T/issue.log" ]]; then
  pass "8. red control missing quote -> issue opened"
else
  fail "8. missing quote failed (rc=$rc_missing): $out_missing; issue log: $(cat "$T/issue.log")"
fi

exit "$fails"
