#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_oss_export + do_oss_gate (spec 044 T002-T004). On a throwaway git
#          repo carrying the REAL workflows, .gitleaks.toml and LICENSE:
#          - a clean allow-listed export passes (exit 0), carries no .git, no
#            non-listed path, and the report sits beside the tree, not in it
#          - CONTROLS, each must turn the gate red (exit 1) in its own class:
#            a planted fake cloud key (secret), a planted owner surname
#            (hygiene), a planted banned literal, a CLAUDE.md inside an
#            allowed dir (forbidden-file), an unlicensed image, a missing
#            LICENSE, a dependency under a non-free licence
#          - the report names file:line and never the planted value
#          - refusals (exit 2): non-empty OUT_DIR, OUT_DIR inside the repo, a
#            missing required entry, an unsafe entry, a CI gitleaks pin that
#            drifted from the gate's, a skipped dependency class
#          - the real allow-list names no private dir (T004, static)
#          Needs gitleaks 8.30.1: GITLEAKS_BIN, the user cache, or a download.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
REPO_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fails=$((fails + 1)); }
check() { if [[ "$1" == "$2" ]]; then ok "$3"; else no "$3 (got rc=$1, want $2)"; fi; }
for f in oss-export oss-gate; do bash -n "$PROJ_ROOT/src/bash/run/$f.func.sh" || { echo "FAIL: bash -n $f"; exit 1; }; done
python3 -m py_compile "$PROJ_ROOT/src/bash/scripts/oss-gate.py" || { echo "FAIL: py_compile"; exit 1; }
for b in git yq jq python3 curl; do command -v "$b" >/dev/null || { echo "SKIP: $b not installed"; exit 0; }; done

tmp=$(mktemp -d)
[[ -n "${KEEP_TMP:-}" ]] && echo "tmp: $tmp" || trap 'rm -rf "$tmp"' EXIT
LOGF="$tmp/log"
do_log() { printf '%s\n' "$*" >>"$LOGF"; }
do_require_bin() { :; }
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/oss-gate.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/oss-export.func.sh"
GITLEAKS_BIN=$(oss_gitleaks_bin) || { echo "FAIL: no gitleaks $OSS_GITLEAKS_VERSION (offline?)"; exit 1; }
export GITLEAKS_BIN

# ---- the fixture repo --------------------------------------------------------
R="$tmp/repo"
mkdir -p "$R/.github/workflows" "$R/prod" "$R/private"
cp "$REPO_ROOT/.github/workflows/10_ci-quality.yml" "$REPO_ROOT/.github/workflows/15_sec-deps-secrets.yml" "$R/.github/workflows/"
cp "$REPO_ROOT/.gitleaks.toml" "$REPO_ROOT/LICENSE" "$R/"
echo "notices" >"$R/THIRD-PARTY-NOTICES.md"
printf 'package main\n\nfunc main() {}\n' >"$R/prod/main.txt"
echo "instructions" >"$R/CLAUDE.md"
echo "a private note on example-private.test" >"$R/private/ops.txt"
git -C "$R" init -q && git -C "$R" add -A \
  && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm init || { echo "FAIL: fixture repo"; exit 1; }
printf '%s\n' prod LICENSE THIRD-PARTY-NOTICES.md '?not-yet.md' >"$tmp/allow.txt"
printf 'private-host\ta private test host\t(?i)example-private\\.test\n' >"$tmp/rules.tsv"
: >"$tmp/assets.txt"
mkdir -p "$tmp/nm/.pnpm/good@1.0.0/node_modules/good" "$tmp/nm/.pnpm/@s+scoped@2.0.0/node_modules/@s/scoped"
echo '{"name":"good","version":"1.0.0","license":"MIT"}' >"$tmp/nm/.pnpm/good@1.0.0/node_modules/good/package.json"
echo '{"name":"@s/scoped","version":"2.0.0","license":"(BSD-3-Clause OR GPL-2.0)"}' >"$tmp/nm/.pnpm/@s+scoped@2.0.0/node_modules/@s/scoped/package.json"

export APP_PATH="$R" PROJ_PATH="$PROJ_ROOT" OSS_ALLOW_LIST="$tmp/allow.txt" \
  OSS_GATE_RULES="$tmp/rules.tsv" OSS_GATE_ASSETS="$tmp/assets.txt" OSS_GATE_NODE_MODULES="$tmp/nm"
n=0
# commit <path> <content> - change the fixture repo and commit (the export reads a ref)
commit() {
  mkdir -p "$(dirname "$R/$1")"; printf '%s\n' "$2" >"$R/$1"
  git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm "$1"
}
# run_export - export HEAD into a fresh dir; sets $out, $rep, $rc
run_export() {
  n=$((n + 1)); out="$tmp/out$n"; rep="$out.oss-gate-report.tsv"
  OUT_DIR="$out" do_oss_export >"$tmp/stdout$n" 2>&1; rc=$?
}
count() { grep -v '^#' "$rep" 2>/dev/null | awk -F'\t' -v c="$1" '$1 == c' | wc -l; }

# ---- 1. clean export ---------------------------------------------------------
run_export
check "$rc" 0 "clean allow-listed export -> the gate passes"
[[ -f "$out/prod/main.txt" && -f "$out/LICENSE" ]] && ok "allow-listed paths exported" || no "allow-listed paths missing"
[[ ! -e "$out/CLAUDE.md" && ! -e "$out/private" && ! -e "$out/.github" ]] && ok "non-listed paths not exported" || no "a non-listed path leaked"
[[ ! -e "$out/.git" ]] && ok "no .git (no history)" || no "a .git reached the export"
[[ -f "$rep" && "$rep" != "$out"/* ]] && ok "report written beside the tree" || no "report missing or inside the tree"
grep -qP '^secret\t0$' "$tmp/stdout$n" && grep -qP '^dep-licence\t0$' "$tmp/stdout$n" && grep -qP '^TOTAL\t0$' "$tmp/stdout$n" \
  && ok "per-class counts printed, zeros included" || no "per-class counts missing"
grep -q "not-yet.md" "$tmp/stdout$n" && ok "an optional absent entry is named, not fatal" || no "optional entry not reported"

# ---- 2. control: a planted fake cloud key ------------------------------------
# AKIA + 16 base32 chars ([A-Z2-7]); assembled so this file never holds it
key="AKIA""QX7W""3ZRT""5MYB""L2PN"
commit prod/config.txt "aws_access_key_id = $key"
run_export
check "$rc" 1 "CONTROL planted fake key -> the gate fails"
[[ $(count secret) -ge 1 ]] && ok "the key is a 'secret' row" || no "no secret row"
grep -qP '^secret\tprod/config\.txt\t1\t' "$rep" && ok "secret row names file:line" || no "secret row lacks file:line"
grep -rqF "$key" "$rep" "$tmp/stdout$n" && no "the key VALUE reached the report/stdout" || ok "the key value is in neither report nor stdout"
git -C "$R" rm -q prod/config.txt && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm rm

# ---- 3. control: a planted banned name (the 10 ci Sweep) ---------------------
surname="Geor""giev"
commit prod/credits.txt "written by $surname"
run_export
check "$rc" 1 "CONTROL planted banned name -> the gate fails"
grep -qP '^hygiene\tprod/credits\.txt\t1\tpersonal name$' "$rep" && ok "hygiene row names file:line and the Sweep label" || no "no hygiene row"
grep -qiF "$surname" "$rep" && no "the banned name reached the report" || ok "the name is not in the report"
git -C "$R" rm -q prod/credits.txt && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm rm

# ---- 4. control: a banned literal from the private rules file ----------------
commit prod/url.txt "see https://api.example-private.test/x"
run_export
check "$rc" 1 "CONTROL banned literal -> the gate fails"
grep -qP '^private-host\tprod/url\.txt\t1\ta private test host$' "$rep" && ok "literal row names file:line + rule label" || no "no literal row"
grep -qF "example-private" "$rep" && no "the literal reached the report" || ok "the literal is not in the report"
git -C "$R" rm -q prod/url.txt && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm rm

# ---- 5. controls: forbidden file, image, licence, dependency -----------------
commit prod/sub/CLAUDE.md "x"
commit prod/logo.png "not really a png"
run_export
check "$rc" 1 "CONTROL CLAUDE.md in an allowed dir + an image -> the gate fails"
[[ $(count forbidden-file) == 1 ]] && ok "forbidden-file counted" || no "forbidden-file not counted"
[[ $(count image-unlicensed) == 1 ]] && ok "unlicensed image counted" || no "image not counted"
echo 'prod/*.png' >"$tmp/assets.txt"
git -C "$R" rm -q prod/sub/CLAUDE.md && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm rm
run_export
check "$rc" 0 "a globbed (licensed) image passes"
: >"$tmp/assets.txt"
git -C "$R" rm -q prod/logo.png LICENSE && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm rm
sed -i '/^LICENSE$/d' "$tmp/allow.txt"
run_export
check "$rc" 1 "CONTROL no LICENSE -> the gate fails"
grep -qP '^licence\tLICENSE\t' "$rep" && ok "licence row for LICENSE" || no "no licence row"
cp "$REPO_ROOT/LICENSE" "$R/" && git -C "$R" add LICENSE && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm lic
echo LICENSE >>"$tmp/allow.txt"
mkdir -p "$tmp/nm/.pnpm/bad@3.0.0/node_modules/bad"
echo '{"name":"bad","version":"3.0.0","license":"SSPL-1.0"}' >"$tmp/nm/.pnpm/bad@3.0.0/node_modules/bad/package.json"
run_export
check "$rc" 1 "CONTROL a non-free dependency -> the gate fails"
grep -qP '^dep-licence\tnpm:bad@3\.0\.0\t0\tSSPL-1\.0$' "$rep" && ok "dep row names the package + licence" || no "no dep row"
[[ $(count dep-licence) == 1 ]] && ok "an OR expression with one allowed licence passes" || no "the OR expression was counted"
rm -rf "$tmp/nm/.pnpm/bad@3.0.0"

# ---- 6. refusals (exit 2) ----------------------------------------------------
mkdir -p "$tmp/full" && touch "$tmp/full/x"
OUT_DIR="$tmp/full" do_oss_export >/dev/null 2>&1; check $? 2 "non-empty OUT_DIR refused"
OUT_DIR="$R/inside" do_oss_export >/dev/null 2>&1; check $? 2 "OUT_DIR inside the repo refused"
cp "$tmp/allow.txt" "$tmp/allow.bak"
echo required-missing >>"$tmp/allow.txt"; run_export; check "$rc" 2 "a missing required entry refused"
cp "$tmp/allow.bak" "$tmp/allow.txt"; echo '../outside' >>"$tmp/allow.txt"; run_export; check "$rc" 2 "an unsafe entry refused"
cp "$tmp/allow.bak" "$tmp/allow.txt"
sed -i "s/v${OSS_GITLEAKS_VERSION}/v9.9.9/g" "$R/.github/workflows/15_sec-deps-secrets.yml"
run_export; check "$rc" 2 "a CI gitleaks pin that drifted from the gate's refused"
git -C "$R" checkout -q -- .github
OSS_GATE_SKIP_DEPS=1 run_export; check "$rc" 2 "a skipped dependency class is never a pass"
OSS_GATE_NODE_MODULES="$tmp/none" run_export; check "$rc" 2 "an unreadable npm store is never a pass"

# ---- 7. the real allow-list names no private path (T004) ---------------------
real="$PROJ_ROOT/cnf/oss/export-allow-list.txt"
bad=$(grep -vE '^\s*(#|$)' "$real" | sed 's/^?//' | grep -E '^(csi-spl-(cnf|iac|orc|doc|dat|utl)|\.github|CLAUDE\.md|AGENTS\.md|GEMINI\.md|README\.md)(/|$)')
[[ -z "$bad" ]] && ok "the real allow-list names no private path" || no "the real allow-list names: $bad"
[[ $(grep -vcE '^\s*(#|$)' "$PROJ_ROOT/cnf/oss/banned-literals.tsv") -ge 10 ]] && ok "the real rules file carries its classes" || no "the real rules file is thin"
OSS_GATE_RULES="$PROJ_ROOT/cnf/oss/banned-literals.tsv" python3 - "$PROJ_ROOT/cnf/oss/banned-literals.tsv" <<'EOF' && ok "every real rule compiles" || no "a real rule does not compile"
import re, sys
for l in open(sys.argv[1]):
    if l.strip() and not l.startswith('#'):
        c, lab, rx = l.rstrip('\n').split('\t'); re.compile(rx)
EOF

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
