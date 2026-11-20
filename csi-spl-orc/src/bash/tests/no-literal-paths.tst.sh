#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: no NEW literal box path in the cnf or in an action (SPL-5527, spec
# 011; owner HUM-10, t1 #refactoring: "nothing should be hard-coded. There
# should be no paths in the configuration files"). Paths come from run.sh at
# start and from spl_run_paths (csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh);
# a cnf value carries ${SPL_ORG_DIR} / ${SPL_VAR_APP_DIR} instead.
#   Scanned: every git-tracked csi-spl-cnf/**/*.{yaml,yml,json}, **/*.func.sh
#   and every other **/*.sh outside a tests/ dir (cron wrappers, scripts;
#   SPL-5948, r64-02); test fixtures stay out.
#   Banned: /opt/<org> and /var/<org> (<org> = the prefix of the app name of
#   the <app>-orc dir, csi), comment lines included (a comment is copied).
#   Ratchet: no-literal-paths.baseline holds "<lines> <file>" for today's
#   files; a file not in it, or with more lines than it says, FAILs; a file
#   with fewer lines than it says FAILs too (lower the number: the list only
#   shrinks). Round 2 removes the rest (/var/spool-hub, the spool root, is an
#   owner decision and not scanned).
#   Red controls on a fixture git tree: a new file with a literal, a new
#   scripts/*.sh with one, a listed file that grew, a stale (too high) entry
#   each FAIL; the ${SPL_*} token form, /opt/<other> paths and a literal in a
#   tests/ dir pass.
#   Second ratchet (SPL-6092, r77-01): the same var dir spelled by hand from a
#   variable (/var/${X%%-*}/$X/<sub>, /opt/$org/$app), which the literal check
#   cannot see; derive it with spl_var_app_subdir. Same files, same NEW / MORE
#   / STALE rules, its own baseline no-literal-paths-spelled.baseline, which
#   also only shrinks. A root after a letter, digit, _ or } is not counted
#   (the helper's own ${base%/*}/var/...).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
BASELINE="$TEST_DIR/no-literal-paths.baseline"
SPELLED_BASELINE="$TEST_DIR/no-literal-paths-spelled.baseline"
NLP_SPELLED_RX='(^|[^A-Za-z0-9_}])/(opt|var)/\$\{?[A-Za-z_][A-Za-z0-9_]*(%%-\*)?\}?/'

# nlp_org <root> -> the org tag: <org>-<name>-orc -> <org>
nlp_org() {
  local d
  for d in "$1"/*-orc; do [[ -d "$d" ]] && { d="${d##*/}"; printf '%s\n' "${d%%-*}"; return 0; }; done
  return 1
}

# nlp_counts <root> <rx> -> "<lines> <file>" per tracked file with a line
# matching <rx> (the cnf, every *.func.sh, and every *.sh outside a tests/ dir)
nlp_counts() {
  local root="$1" rx="$2"
  { git -C "$root" ls-files -z -- 'csi-spl-cnf/*.yaml' 'csi-spl-cnf/*.yml' 'csi-spl-cnf/*.json' '*.func.sh'
    git -C "$root" ls-files -z -- '*.sh' ':!:*/tests/*' ':!:tests/*'; } | sort -zu |
    (cd "$root" && xargs -0 -r grep -cE "$rx" 2>/dev/null) |
    awk -F: '$NF > 0 { n = $NF; sub(/:[0-9]+$/, ""); print n " " $0 }' | sort -k2
}

# nlp_check <root> <baseline> [spelled] -> one line per violation, rc 1 if any;
# the literal /opt/<org>, /var/<org> check, or with "spelled" the var dir
# spelled from a variable
nlp_check() {
  local root="$1" base="$2" org rx what="literal path" whats="literal paths" fix="spl_run_paths, run.sh"
  org="$(nlp_org "$root")" || { echo "no <app>-orc dir under $root"; return 1; }
  rx="/(opt|var)/${org}(\$|[^A-Za-z0-9_-])"
  [[ "${3:-}" == spelled ]] && { rx="$NLP_SPELLED_RX"; what="spelled var dir"; whats="spelled var dirs"; fix="spl_var_app_subdir"; }
  nlp_counts "$root" "$rx" | awk -v base="$base" -v what="$what" -v whats="$whats" -v fix="$fix" '
    BEGIN { while ((getline l < base) > 0) { if (l ~ /^#/ || l == "") continue; split(l, a, " "); want[a[2]] = a[1] } }
    { seen[$2] = 1
      if (!($2 in want)) { print "NEW " what ": " $2 " (" $1 " lines): derive it (" fix ")"; bad = 1 }
      else if ($1 > want[$2]) { print "MORE " whats ": " $2 " has " $1 ", baseline " want[$2]; bad = 1 }
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
rm -f "$F/acme-app-orc/src/bash/run/new.func.sh"
printf 'a() { echo /opt/acme/acme-app; }\n# /var/acme/acme-app/log\n' >"$F/acme-app-orc/src/bash/run/old.func.sh"; git -C "$F" add -A
mkdir -p "$F/acme-app-orc/src/bash/scripts" "$F/acme-app-orc/src/bash/tests"
printf 'cd /opt/acme/acme-app/x\n' >"$F/acme-app-orc/src/bash/scripts/x.sh"; git -C "$F" add -A
out="$(nlp_check "$F" "$T/base")"
[[ $? -ne 0 && "$out" == *"NEW literal path: acme-app-orc/src/bash/scripts/x.sh"* ]] && pass "red control: a new script (*.sh, not *.func.sh) with /opt/<org>/ FAILs" || fail "red control script: $out"
git -C "$F" rm -q -f acme-app-orc/src/bash/scripts/x.sh
printf 'd=/var/acme/acme-app/fx\n' >"$F/acme-app-orc/src/bash/tests/x.tst.sh"; git -C "$F" add -A
out="$(nlp_check "$F" "$T/base")" && pass "fixture: a literal under a tests/ dir passes (fixtures stay out)" || fail "fixture tests dir: $out"

# --- red controls of the spelled ratchet on a second fixture tree ------------
S="$T/fs"; R="acme-app-orc/src/bash/run"; mkdir -p "$S/$R" "$S/acme-app-orc/src/bash/tests"
git -C "$S" init -q
printf 'a() { echo "/var/${oa%%%%-*}/$oa/log"; }\n# /opt/${org}/x\n' >"$S/$R/old.func.sh"
printf 'b() { echo "$SPL_VAR_APP_DIR/x" "${base%%/*}/var/${org##*/}/x" /var/log/x /opt/tf/bin; }\n' >"$S/$R/ok.func.sh"
printf 'd="/var/${oa%%%%-*}/$oa/fx"\n' >"$S/acme-app-orc/src/bash/tests/x.tst.sh"
git -C "$S" add -A
printf '# lines file\n2 %s/old.func.sh\n' "$R" >"$T/sbase"
out="$(nlp_check "$S" "$T/sbase" spelled)" && pass "spelled fixture: baseline file, \$SPL_VAR_APP_DIR, the helper's form, /var/log, /opt/tf and a tests/ dir pass" || fail "spelled fixture clean: $out"
nlp_spelled_red() { # <file> <text> <label>: a new file with <text> FAILs as NEW
  mkdir -p "$S/${1%/*}"; printf '%s\n' "$2" >"$S/$1"; git -C "$S" add -A
  out="$(nlp_check "$S" "$T/sbase" spelled)"
  [[ $? -ne 0 && "$out" == *"NEW spelled var dir: $1"* ]] && pass "spelled red control: $3 FAILs" || fail "spelled red control $3: $out"
  git -C "$S" rm -q -f "$1"
}
nlp_spelled_red "$R/new.func.sh" 'c() { cd "/var/${oa%%-*}/$oa/x"; }' 'a new run/*.func.sh with /var/${oa%%-*}/$oa/x'
nlp_spelled_red acme-app-orc/src/bash/scripts/y.sh 'cd /opt/$org/$app' 'a new scripts/*.sh with /opt/$org/$app'
nlp_spelled_red acme-app-orc/src/bash/features/bs/scripts/z.sh 'd="${D:-/var/${oa%%-*}/$oa/bs}"' 'a new features/*/scripts/*.sh with one'
printf 'e() { ls /opt/$org/$app/y; }\n' >>"$S/$R/old.func.sh"; git -C "$S" add -A
out="$(nlp_check "$S" "$T/sbase" spelled)"
[[ $? -ne 0 && "$out" == *"MORE spelled var dirs: $R/old.func.sh has 3, baseline 2"* ]] && pass "spelled red control: a listed file that grew FAILs" || fail "spelled red control grew: $out"
printf 'a() { :; }\n# /opt/${org}/x\n' >"$S/$R/old.func.sh"; git -C "$S" add -A
out="$(nlp_check "$S" "$T/sbase" spelled)"
[[ $? -ne 0 && "$out" == *"STALE baseline: $R/old.func.sh has 1, baseline 2: lower it"* ]] && pass "spelled red control: a stale (too high) entry FAILs (the list only shrinks)" || fail "spelled red control stale: $out"

# --- the tree ----------------------------------------------------------------
[[ -s "$BASELINE" ]] || fail "no baseline $BASELINE"
if out="$(nlp_check "$APP_ROOT" "$BASELINE")"; then
  pass "tree: no literal /opt/<org> or /var/<org> path beyond the baseline ($(grep -vc '^#' "$BASELINE") files left)"
else
  fail "tree: $out"
fi
[[ -s "$SPELLED_BASELINE" ]] || fail "no baseline $SPELLED_BASELINE"
if out="$(nlp_check "$APP_ROOT" "$SPELLED_BASELINE" spelled)"; then
  pass "tree: no var dir spelled from a variable beyond the baseline ($(grep -vc '^#' "$SPELLED_BASELINE") files left)"
else
  fail "tree: $out"
fi
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
