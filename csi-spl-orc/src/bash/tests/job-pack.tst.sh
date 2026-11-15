#!/usr/bin/env bash
#------------------------------------------------------------------------------
# job-pack.tst.sh - do_job_pack (SPL-5555) on a synthetic vacancy, synthetic
# master CVs and a synthetic CONTENT (fixtures/job-pack; no real person or
# company). pandoc and chrome are stubs that write their -o / --print-to-pdf
# file and log the call, so the suite needs python3 only:
#   1. refusals: no OUT_DIR, no input, an OUT_DIR inside a git checkout
#      (nothing is made), a missing MASTER_CV_DIR or CONTENT (rc 1)
#   2. fetch + pick, no CONTENT: the vacancy text without its script, the
#      contact address; the base CV naming 2 of the vacancy's technologies
#      beats a newer one naming 1 (RED control: by the file name alone the
#      newer one wins); NEXT is printed and no pack is built
#   3. build: per language the 5 documents x html/pdf/docx, an index per
#      language + index.html, one zip of the same files under the pack dir;
#      pandoc 8 and chrome 5 calls per language
#   4. the documents' sections: projects per requirement (summary + one
#      section per requirement, the | escaped), requirements per project,
#      highlights, the CV (new kicker, tagline and key table, the old key
#      row gone, a dropped skill gone, a replace applied; a key table put
#      after the tagline where the base has none), the letter (recipient,
#      name), the index (links to every language)
#   5. the fit table: a key row the master backs, one whose years differ
#      (CHECK), a vacancy technology the CV lacks (CHECK); WARN on stdout
#   6. a rebuild replaces its own out/; a foreign out/ is refused (rc 2); a
#      CONTENT lacking a key (rc 2, names it); a replace text not in the base
#      CV (rc 2); an unreadable vacancy (rc 3)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v python3 >/dev/null || { echo "FAIL: python3 is required"; exit 1; }

FUNC="$PROJ_ROOT/src/bash/run/job-pack.func.sh"
FX="$TEST_DIR/fixtures/job-pack"
[[ -f "$FUNC" ]] || { echo "FAIL: no action at $FUNC"; echo "FAIL job-pack: 1 failed"; exit 1; }

# stubs: write the output file, log the call
mkdir -p "$T/bin"
cat >"$T/bin/pandoc" <<'EOF'
#!/bin/bash
o=""; while (($#)); do [[ "$1" == -o ]] && o="$2"; shift; done
echo pandoc >>"$STUB_LOG"; echo "stub docx/html" >"$o"
EOF
cat >"$T/bin/chrome" <<'EOF'
#!/bin/bash
for a in "$@"; do [[ "$a" == --print-to-pdf=* ]] && o="${a#--print-to-pdf=}"; done
echo chrome >>"$STUB_LOG"; echo "%PDF-stub" >"$o"
EOF
chmod +x "$T/bin/pandoc" "$T/bin/chrome"
export STUB_LOG="$T/calls.log"

act() { env JOB_PACK_PANDOC="$T/bin/pandoc" JOB_PACK_CHROME="$T/bin/chrome" JOB_PACK_PDFINFO=/nonexistent/pdfinfo \
  "$@" bash -c 'source "$1"; do_job_pack' _ "$FUNC" 2>&1; }

# --- 1. refusals ------------------------------------------------------------------
out="$(act OUT_DIR= CONTENT="$FX/content.py")"; rc=$?
[[ "$rc" == 1 && "$out" == *"OUT_DIR must be set"* ]] && pass "1. no OUT_DIR: rc 1" || fail "1. no OUT_DIR (rc $rc: $out)"
out="$(act OUT_DIR="$T/p0")"; rc=$?
[[ "$rc" == 1 && "$out" == *"at least one of"* ]] && pass "1. no input: rc 1" || fail "1. no input (rc $rc: $out)"
out="$(act OUT_DIR="$PROJ_ROOT/job-pack-test-never-made/x" CONTENT="$FX/content.py")"; rc=$?
[[ "$rc" == 1 && "$out" == *"inside a git checkout"* && ! -e "$PROJ_ROOT/job-pack-test-never-made" ]] &&
  pass "1. OUT_DIR inside a git checkout: rc 1, nothing made" || fail "1. git OUT_DIR (rc $rc: $out)"
out="$(act OUT_DIR="$T/p0" MASTER_CV_DIR="$T/nope")"; rc=$?
[[ "$rc" == 1 && "$out" == *"is not a dir"* ]] && pass "1. missing MASTER_CV_DIR: rc 1" || fail "1. MASTER_CV_DIR (rc $rc: $out)"
out="$(act OUT_DIR="$T/p0" CONTENT="$T/nope.py")"; rc=$?
[[ "$rc" == 1 && "$out" == *"is not a file"* ]] && pass "1. missing CONTENT: rc 1" || fail "1. CONTENT (rc $rc: $out)"

# --- 2. fetch + pick ----------------------------------------------------------------
P="$T/pack"
out="$(act OUT_DIR="$P" VACANCY_URL="file://$FX/vacancy.html" MASTER_CV_DIR="$FX/master-cvs")"; rc=$?
v="$(cat "$P/vacancy/vacancy.txt" 2>/dev/null)"
[[ "$rc" == 0 && "$v" == *"Terraform and Kafka"* && "$v" != *SCRIPT-NEVER-IN-TEXT* && "$v" == *"Source: file://"* ]] &&
  pass "2. fetch: the vacancy text, without its script" || fail "2. fetch (rc $rc: $out)"
[[ "$(cat "$P/vacancy/contacts.txt" 2>/dev/null)" == "jobs@example.com" ]] && pass "2. fetch: the contact address" ||
  fail "2. contacts: '$(cat "$P/vacancy/contacts.txt" 2>/dev/null)'"
[[ "$out" == *"OK pick en: score 2 cv-data-en-2026-01.html"* && "$out" == *"OK pick fi: score 2 cv-data-fi-2026-01.html"* ]] &&
  grep -q 'cv-data-en-2026-01.html` \*\*picked\*\* | Terraform, Kafka' "$P/internal/pick.md" &&
  grep -q '| en | 1 | `cv-web-en-2026-03.html` | Terraform |' "$P/internal/pick.md" &&
  pass "2. pick: score 2 beats the newer score-1 CV" || fail "2. pick ($out; $(cat "$P/internal/pick.md" 2>/dev/null))"
# RED control: the same candidates with no vacancy text tie at 0, and the file name decides
out="$(act OUT_DIR="$T/red" MASTER_CV_DIR="$FX/master-cvs")"
[[ "$out" == *"OK pick en: score 0 cv-web-en-2026-03.html"* ]] && pass "2. RED control: without the vacancy the newer name wins" ||
  fail "2. RED control ($out)"
[[ "$out" == *"NEXT job-pack: write the CONTENT"* && ! -d "$P/out" ]] && pass "2. no CONTENT: NEXT, no pack" || fail "2. NEXT ($out)"

# --- 3. build -------------------------------------------------------------------------
: >"$STUB_LOG"
out="$(act OUT_DIR="$P" MASTER_CV_DIR="$FX/master-cvs" CONTENT="$FX/content.py")"; rc=$?
[[ "$rc" == 0 && "$out" == *"OK build: 33 files in 2 language(s)"* ]] && pass "3. build: rc 0, 33 files" || fail "3. build (rc $rc: $out)"
n=0
for l in en "fi"; do
  for d in CV Highlights Projects-per-Requirement Requirements-per-Project Why-Letter; do
    for x in html pdf docx; do
      [[ -s "$P/out/$l/FirstName-LastName-$d-Platform-Engineer-${l^^}-2026-11-15.$x" ]] && n=$((n + 1))
    done
  done
done
[[ "$n" == 30 && -s "$P/out/index.html" && -s "$P/out/index.en.html" && -s "$P/out/index.fi.html" ]] &&
  pass "3. 2 languages x 5 documents x 3 formats + 3 index pages" || fail "3. files: $n of 30"
Z="$P/out/FirstName-LastName-Platform-Engineer-2026-11-15.zip"
zl="$(python3 -c 'import sys,zipfile; n=zipfile.ZipFile(sys.argv[1]).namelist(); print(len(n), all(x.startswith("FirstName-LastName-Platform-Engineer-2026-11-15/") for x in n), any(".job-pack" in x for x in n))' "$Z" 2>&1)"
[[ "$zl" == "33 True False" ]] && pass "3. the zip: the 33 files under the pack dir, no marker" || fail "3. zip: $zl"
[[ "$(grep -c pandoc "$STUB_LOG")" == 16 && "$(grep -c chrome "$STUB_LOG")" == 10 ]] &&
  pass "3. pandoc 8 and chrome 5 calls per language" || fail "3. calls: $(sort "$STUB_LOG" | uniq -c | tr '\n' ' ')"

# --- 4. the sections --------------------------------------------------------------------
MD="$P/internal/md"; O="$P/out/en"; B="FirstName-LastName"; S="Platform-Engineer-EN-2026-11-15"
ppr="$(cat "$MD/$B-Projects-per-Requirement-$S.md" 2>/dev/null)"
[[ "$ppr" == *"# Projects per requirement"* && "$ppr" == *"## Summary"* && "$ppr" == *"| 1.1 Terraform | 2 |"* &&
   "$ppr" == *"## 1.2 Kafka"* && "$ppr" == *'modules \| pipelines'* && "$ppr" == *"**FirstName LastName**"* ]] &&
  pass "4. projects per requirement: summary, a section per requirement, | escaped" || fail "4. ppr: $ppr"
rpp="$(cat "$MD/$B-Requirements-per-Project-$S.md" 2>/dev/null)"
[[ "$rpp" == *"| Example Corp 2020–2024 | 1.1 · 1.2 | SYNTH-HOW-ALPHA |"* && "$rpp" == *"| Example Org 2018–2020 | 1.1 | SYNTH-HOW-BETA |"* ]] &&
  pass "4. requirements per project: a row per project" || fail "4. rpp: $rpp"
hl="$(cat "$MD/$B-Highlights-$S.md" 2>/dev/null)"
[[ "$hl" == *"- **Infra as code** — SYNTH-HL-1, see [example.com](https://example.com)"* && "$hl" == *SYNTH-HL-TAIL* ]] &&
  pass "4. highlights: the points, links as markdown" || fail "4. hl: $hl"
cv="$(cat "$O/$B-CV-$S.html" 2>/dev/null)"
[[ "$cv" == *'<p class="kicker">Platform Engineer · Terraform · Kafka</p>'* && "$cv" == *SYNTH-TAGLINE-EN* &&
   "$cv" == *'<table class="key">'*SYNTH-KEY-KAFKA* && "$cv" != *OLD-KEY-ROW* && "$cv" != *Cobol* &&
   "$cv" == *"synthetic project alpha (event pipelines)"* && "$cv" == *"<title>CV FirstName LastName EN 2026-11 –"* ]] &&
  pass "4. CV: kicker, tagline, key table replaced, skill dropped, replace applied" || fail "4. cv en"
cvfi="$(cat "$P/out/fi/$B-CV-Platform-Engineer-FI-2026-11-15.html" 2>/dev/null)"
[[ "$cvfi" == *$'SYNTH-TAGLINE-FI</p>\n<h2>Keskeiset teknologiat</h2>'* ]] &&
  pass "4. CV fi: the key table put after the tagline (the base had none)" || fail "4. cv fi"
why="$(cat "$O/$B-Why-Letter-$S.html" 2>/dev/null)"
[[ "$why" == *"<b>To:</b> jobs@example.com"* && "$why" == *"Best regards<br>FirstName LastName"* &&
   "$why" == *"$B-CV-$S.pdf"* && "$why" == *'wire("copy", "msg-en", "Copy", "Copied ✓")'* ]] &&
  pass "4. letter: recipient, attachments, signature" || fail "4. letter"
idx="$(cat "$P/out/index.fi.html" 2>/dev/null)"
[[ "$idx" == *"<title>Sisältö – Platform Engineer</title>"* && "$idx" == *"en/$B-CV-$S.pdf"* &&
   "$idx" == *"fi/$B-Why-Letter-Platform-Engineer-FI-2026-11-15.docx"* ]] && pass "4. index: every language's files" || fail "4. index"

# --- 5. the fit table -----------------------------------------------------------------------
fit="$(cat "$P/internal/fit.md" 2>/dev/null)"
[[ "$fit" == *"| Terraform | yes | 5 | 5 years | backed |"* && "$fit" == *"| Kafka | yes | 3 | 4 years | CHECK: master CV says 3 |"* &&
   "$fit" == *"| Rust | yes | – | – | CHECK: the vacancy names it, the CV does not |"* && "$out" == *"WARN fit: 2 row(s) to CHECK"* ]] &&
  pass "5. fit: backed, years differ, missing technology" || fail "5. fit: $fit"
grep -q "sha256 \`[0-9a-f]\{64\}\`" "$P/internal/files.md" && pass "5. files.md: the zip sha256" || fail "5. files.md"

# --- 6. rebuild and refusals -----------------------------------------------------------------
out="$(act OUT_DIR="$P" MASTER_CV_DIR="$FX/master-cvs" CONTENT="$FX/content.py")"; rc=$?
[[ "$rc" == 0 ]] && pass "6. a rebuild replaces its own out/" || fail "6. rebuild (rc $rc: $out)"
mkdir -p "$T/foreign/out"
out="$(act OUT_DIR="$T/foreign" MASTER_CV_DIR="$FX/master-cvs" CONTENT="$FX/content.py")"; rc=$?
[[ "$rc" == 2 && "$out" == *"not written by job-pack"* && -d "$T/foreign/out" ]] && pass "6. a foreign out/: rc 2, kept" || fail "6. foreign (rc $rc: $out)"
grep -v '^HL_TAIL' "$FX/content.py" >"$T/no-tail.py"
out="$(act OUT_DIR="$T/c1" MASTER_CV_DIR="$FX/master-cvs" CONTENT="$T/no-tail.py")"; rc=$?
[[ "$rc" == 2 && "$out" == *"lacks HL_TAIL"* ]] && pass "6. CONTENT lacking a key: rc 2, named" || fail "6. lacks (rc $rc: $out)"
sed 's/("synthetic project alpha", /("NOT-IN-THE-BASE-CV", /' "$FX/content.py" >"$T/bad-replace.py"
out="$(act OUT_DIR="$T/c2" MASTER_CV_DIR="$FX/master-cvs" CONTENT="$T/bad-replace.py")"; rc=$?
[[ "$rc" == 2 && "$out" == *"occurs 0 times"* ]] && pass "6. a replace text not in the base CV: rc 2" || fail "6. replace (rc $rc: $out)"
out="$(act OUT_DIR="$T/c3" VACANCY_URL="file://$T/no-such-vacancy.html")"; rc=$?
[[ "$rc" == 3 && "$out" == *"cannot fetch the vacancy"* ]] && pass "6. an unreadable vacancy: rc 3" || fail "6. fetch (rc $rc: $out)"

[[ "$fails" == 0 ]] && echo "OK job-pack: all passed" || echo "FAIL job-pack: $fails failed"
((fails == 0))
