#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: no NEW literal box path in the cnf or in an action (SPL-5527, spec
# 011; owner HUM-10, t1 #refactoring: "nothing should be hard-coded. There
# should be no paths in the configuration files"). Paths come from run.sh at
# start and from spl_run_paths (csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh);
# a cnf value carries ${SPL_ORG_DIR} / ${SPL_VAR_APP_DIR} instead.
#   Scanned: every git-tracked csi-spl-cnf/**/*.yaml and **/*.func.sh.
#   Banned: /opt/<org> and /var/<org> (<org> = the prefix of the app name of
#   the <app>-orc dir, csi), comment lines included (a comment is copied).
#   Ratchet: no-literal-paths.baseline holds "<lines> <file>" for today's
#   files; a file not in it, or with more lines than it says, FAILs; a file
#   with fewer lines than it says FAILs too (lower the number: the list only
#   shrinks). Round 2 removes the rest (/var/spool-hub, the spool root, is an
#   owner decision and not scanned).
#   Red controls on a fixture git tree: a new file with a literal, a listed
#   file that grew, a stale (too high) entry each FAIL; the ${SPL_*} token
#   form and /opt/<other> paths pass.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
BASELINE="$TEST_DIR/no-literal-paths.baseline"

# nlp_org <root> -> the org tag: <org>-<name>-orc -> <org>
nlp_org() {
  local d
  for d in "$1"/*-orc; do [[ -d "$d" ]] && { d="${d##*/}"; printf '%s\n' "${d%%-*}"; return 0; }; done
  return 1
}

# nlp_counts <root> <org> -> "<lines> <file>" per tracked file with a literal
nlp_counts() {
  local root="$1" org="$2"
  git -C "$root" ls-files -z -- 'csi-spl-cnf/*.yaml' '*.func.sh' |
    (cd "$root" && xargs -0 -r grep -cE "/(opt|var)/${org}(\$|[^A-Za-z0-9_-])" 2>/dev/null) |
    awk -F: '$NF > 0 { n = $NF; sub(/:[0-9]+$/, ""); print n " " $0 }' | sort -k2
}

# nlp_check <root> <baseline> -> one line per violation, rc 1 if any
nlp_check() {
  local root="$1" base="$2" org
  org="$(nlp_org "$root")" || { echo "no <app>-orc dir under $root"; return 1; }
  nlp_counts "$root" "$org" | awk -v base="$base" '
    BEGIN { while ((getline l < base) > 0) { if (l ~ /^#/ || l == "") continue; split(l, a, " "); want[a[2]] = a[1] } }
    { seen[$2] = 1
      if (!($2 in want)) { print "NEW literal path: " $2 " (" $1 " lines): derive it (spl_run_paths, run.sh)"; bad = 1 }
      else if ($1 > want[$2]) { print "MORE literal paths: " $2 " has " $1 ", baseline " want[$2]; bad = 1 }
      else if ($1 < want[$2]) { print "STALE baseline: " $2 " has " $1 ", baseline " want[$2] ": lower it"; bad = 1 } }
    END { for (f in want) if (!(f in seen)) { print "STALE baseline: " f " has none: drop its line"; bad = 1 }
      exit bad }'
}

# --- red controls on a fixture tree ------------------------------------------
F="$T/fx"; mkdir -p "$F/acme-app-orc/src/bash/run" "$F/csi-spl-cnf/acme-app"
git -C "$F" init -q
printf 'a() { echo /opt/acme/acme-app; }\n# /var/acme/acme-app/log\n' >"$F/acme-app-orc/src/bash/run/old.func.sh"
printf 'b() { echo "${SPL_ORG_DIR}/x" /opt/tf/bin /opt/acmex/y; }\n' >"$F/acme-app-orc/src/bash/run/ok.func.sh"
printf 'env:\n  src_dir: ${SPL_ORG_DIR}/repo\n' >"$F/csi-spl-cnf/acme-app/all.env.yaml"
git -C "$F" add -A
printf '# lines file\n2 acme-app-orc/src/bash/run/old.func.sh\n' >"$T/base"
out="$(nlp_check "$F" "$T/base")" && pass "fixture: baseline file, token form and /opt/<other> pass" || fail "fixture clean: $out"
printf 'c() { cd /opt/acme/acme-app-wt; }\n' >"$F/acme-app-orc/src/bash/run/new.func.sh"; git -C "$F" add -A
out="$(nlp_check "$F" "$T/base")"
[[ $? -ne 0 && "$out" == *"NEW literal path: acme-app-orc/src/bash/run/new.func.sh"* ]] && pass "red control: a new file with /opt/<org>/ FAILs" || fail "red control new: $out"
git -C "$F" rm -q --cached acme-app-orc/src/bash/run/new.func.sh
printf 'src_dir: /opt/acme/repo\n' >>"$F/csi-spl-cnf/acme-app/all.env.yaml"; git -C "$F" add -A
out="$(nlp_check "$F" "$T/base")"
[[ $? -ne 0 && "$out" == *"NEW literal path: csi-spl-cnf/acme-app/all.env.yaml"* ]] && pass "red control: a literal path value in the cnf FAILs" || fail "red control cnf: $out"
git -C "$F" checkout -q -- . 2>/dev/null; printf 'env:\n  src_dir: ${SPL_ORG_DIR}/repo\n' >"$F/csi-spl-cnf/acme-app/all.env.yaml"; git -C "$F" add -A
printf 'd() { echo /var/acme/x; }\n' >>"$F/acme-app-orc/src/bash/run/old.func.sh"; git -C "$F" add -A
out="$(nlp_check "$F" "$T/base")"
[[ $? -ne 0 && "$out" == *"MORE literal paths: acme-app-orc/src/bash/run/old.func.sh has 3, baseline 2"* ]] && pass "red control: a listed file that grew FAILs" || fail "red control grew: $out"
printf 'a() { :; }\n' >"$F/acme-app-orc/src/bash/run/old.func.sh"; git -C "$F" add -A
out="$(nlp_check "$F" "$T/base")"
[[ $? -ne 0 && "$out" == *"STALE baseline: acme-app-orc/src/bash/run/old.func.sh has none"* ]] && pass "red control: a stale baseline entry FAILs (the list only shrinks)" || fail "red control stale: $out"

# --- the tree ----------------------------------------------------------------
[[ -s "$BASELINE" ]] || fail "no baseline $BASELINE"
if out="$(nlp_check "$APP_ROOT" "$BASELINE")"; then
  pass "tree: no literal /opt/<org> or /var/<org> path beyond the baseline ($(grep -vc '^#' "$BASELINE") files left)"
else
  fail "tree: $out"
fi
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
