#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the private overlay library (SPL-1874,
#          csi-spl-iac/lib/bash/funcs/spl-private-cnf.func.sh) over a
#          SYNTHETIC overlay (no real hidden name is in this file):
#   1. resolve: every placeholder becomes its slug, a public word is kept,
#      a placeholder that is a prefix of another (01 / 011) is not mixed up
#   2. a missing overlay FAILS FAST and names the file; nothing is written
#   3. a placeholder the overlay does not map fails; nothing is written
#   4. a malformed or duplicate overlay line fails (never a partial map)
#   5. token / add: a hidden slug -> its placeholder, a public one -> itself;
#      add appends the next placeholder, once
#   6. gate patterns: a word slug matches as a word only; a forms_only slug
#      matches as a workspace-list entry, a DNS record name and a tenant host,
#      never as the plain word
#   7. the tracked cnf of this repo: every placeholder it names is a token
#      shape the resolver knows (no stray ws-hidden-x form)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
LIB="$PROJ_ROOT/lib/bash/funcs/spl-private-cnf.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
# shellcheck source=/dev/null
source "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }

export SPL_PRIVATE_CNF="$T/overlay.yaml"
cat >"$SPL_PRIVATE_CNF" <<'EOF'
# synthetic
workspaces:
  ws-hidden-01: zz-alpha
  ws-hidden-02: zz-beta   # a comment
  ws-hidden-11: zz-gamma
forms_only:
  - zz-beta
orgs:
  - zz-org
deny:
  - '(?i)zz-delta'
EOF

# --- 1. resolve ---------------------------------------------------------------
printf 'workspaces = ["t1", "ws-hidden-01", "ws-hidden-11"]\nhost = "ws-hidden-02.example.test"\nkeep = "csitea"\nenv = "t1,ws-hidden-01,ws-hidden-02"\n' >"$T/in.tfvars"
spl_private_resolve "$T/in.tfvars" "$T/out.tfvars"; rc=$?
[[ $rc -eq 0 ]] && grep -qxF 'workspaces = ["t1", "zz-alpha", "zz-gamma"]' "$T/out.tfvars" &&
  grep -qxF 'host = "zz-beta.example.test"' "$T/out.tfvars" && grep -qxF 'keep = "csitea"' "$T/out.tfvars" &&
  grep -qxF 'env = "t1,zz-alpha,zz-beta"' "$T/out.tfvars" &&
  pass "1. every placeholder resolves (adjacent ones too), 01 and 11 stay apart, a public slug is kept" ||
  fail "1. resolve rc=$rc: $(cat "$T/out.tfvars" 2>/dev/null)"
[[ "$(stat -c %a "$T/out.tfvars")" == 600 ]] && pass "1. the resolved file is mode 600" || fail "1. mode $(stat -c %a "$T/out.tfvars")"
spl_private_has_tokens "$T/in.tfvars" && ! spl_private_has_tokens "$T/out.tfvars" &&
  pass "1. has_tokens: the public file has them, the resolved one none" || fail "1. has_tokens"

# --- 2. missing overlay -------------------------------------------------------
out=$(SPL_PRIVATE_CNF="$T/nope.yaml" spl_private_resolve "$T/in.tfvars" "$T/out2.tfvars" 2>&1); rc=$?
[[ $rc -ne 0 && ! -e "$T/out2.tfvars" && "$out" == *"FATAL the private overlay is missing: $T/nope.yaml"* ]] &&
  pass "2. a missing overlay fails fast, names the file, writes nothing" || fail "2. rc=$rc out=$out"

# --- 3. an unmapped placeholder -----------------------------------------------
printf 'w = ["ws-hidden-01", "ws-hidden-07"]\n' >"$T/in3.tfvars"
out=$(spl_private_resolve "$T/in3.tfvars" "$T/out3.tfvars" 2>&1); rc=$?
[[ $rc -ne 0 && ! -e "$T/out3.tfvars" && "$out" == *"ws-hidden-07"* ]] &&
  pass "3. an unmapped placeholder fails, named, nothing written" || fail "3. rc=$rc out=$out"

# --- 4. malformed / duplicate overlay lines -----------------------------------
for bad in '  ws-hidden-03 zz-x' '  ws-hidden-01: zz-other' '  ws-hidden-04: zz-alpha' '  wsx-1: zz-y'; do
  { cat "$SPL_PRIVATE_CNF"; } | awk -v b="$bad" '{print} /^workspaces:/{print b}' >"$T/bad.yaml"
  if SPL_PRIVATE_CNF="$T/bad.yaml" spl_private_map >/dev/null 2>&1; then fail "4. accepted: '$bad'"; else pass "4. refused: '$bad'"; fi
done

# --- 5. token / add -------------------------------------------------------------
[[ "$(spl_private_token zz-gamma)" == ws-hidden-11 && "$(spl_private_token csitea)" == csitea ]] &&
  pass "5. token: hidden -> placeholder, public -> itself" || fail "5. token"
cp "$SPL_PRIVATE_CNF" "$T/keep.yaml"
t1=$(spl_private_add zz-new); t2=$(spl_private_add zz-new)
[[ "$t1" == ws-hidden-12 && "$t2" == ws-hidden-12 && "$(grep -c 'zz-new' "$SPL_PRIVATE_CNF")" == 1 ]] &&
  [[ "$(spl_private_list forms_only)" == zz-beta ]] && [[ "$(stat -c %a "$SPL_PRIVATE_CNF")" == 600 ]] &&
  pass "5. add: the next placeholder, once, inside workspaces:, file kept 600" || fail "5. add $t1 $t2: $(cat "$SPL_PRIVATE_CNF")"
cp "$T/keep.yaml" "$SPL_PRIVATE_CNF"

# --- 6. gate patterns -----------------------------------------------------------
pats=$(spl_private_gate_patterns example.test); rc=$?
alt=$(paste -sd'|' <<<"$pats")
hit() { grep -qP "$alt" <<<"$1"; }
[[ $rc -eq 0 ]] && hit 'owner zz-alpha said' && hit 'zz-gamma-utl' && hit 'a zz-delta line' && hit 'Zz-Alpha' &&
  pass "6. a word slug and a deny entry match, any case" || fail "6. word: $pats"
! hit 'zz-alphabet' && ! hit 'xzz-alpha' && pass "6. a word slug only as a word" || fail "6. word boundary"
hit '    workspaces: [t1, zz-beta, e2e]' && hit 'additional_fqdns = ["zz-beta.example.test"]' &&
  hit '{"name": "zz-beta", "type": "A"}' && hit 'mapped_tenants: [zz-beta]' &&
  pass "6. a forms_only slug matches as a list entry, a DNS name, a tenant host" || fail "6. forms"
! hit 'the zz-beta binary' && ! hit 'filepath.Join(root, "zz-beta", "pins")' && ! hit 'Runtimes["zz-beta"]' &&
  pass "6. a forms_only slug is never matched as the plain word" || fail "6. forms too wide"

# --- 7. the tracked cnf ---------------------------------------------------------
stray=$(grep -rhoE '\bws-hidden-[a-z0-9-]*' "$APP_ROOT/csi-spl-cnf/csi-spl" | grep -vxE "$SPL_PRIVATE_TOKEN_RE" | sort -u)
[[ -z "$stray" ]] && pass "7. every placeholder in the tracked cnf has the resolver's shape" || fail "7. stray: $stray"

if [[ $fails -eq 0 ]]; then
  echo "PASS: all spl-private-cnf.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in spl-private-cnf.tst.sh"
fi
[[ $fails -eq 0 ]]
