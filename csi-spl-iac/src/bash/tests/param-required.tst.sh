#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: one way to say an action's env var is required, and it is enforced
#          (SPL-5549, developer guide 2.4.2). run.sh calls do_validate_params
#          (lib/bash/funcs/validate-params.func.sh) before an action runs; it
#          refuses an unset var only when its @param carries "(required)".
#   1. form: in every src/bash/run/**/*.func.sh of the module, an @param line
#      that says the word "required" (any case, after the var name; not
#      inside a name such as discussion_required) is exactly
#      `# @param NAME (required) - <text>`; an @param's continuation line
#      never says "required". Any other form ("- required:", "(REQUIRED)",
#      "required when ...") FAILS: say a conditional need without the word.
#      param-required-baseline.txt lists today's exceptions (files another
#      lane owned on 2026-11-15) as "<path> <NAME>"; it only shrinks: a
#      listed line that now passes FAILS.
#   2. enforced: on a fixture tree with the module's run.sh and lib, an
#      action whose `(required)` var is unset stops with exit 11 before its
#      body runs; with the var set the body runs.
# Red controls: each other form FAILS check 1, a fixed baseline line FAILS;
# the same fixture without validate-params.func.sh runs the body (check 2
# would be red without the check).
# PARAM_REQUIRED_MODULES: the modules to check (default iac); the orc and utl
# suites call this file with their own.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
APP_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
BASELINE="$TEST_DIR/param-required-baseline.txt"
MODULES="${PARAM_REQUIRED_MODULES:-iac}"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# form_violations <root> <module>: one "<rel path> <NAME> <line no>: <line>"
# per @param line (or continuation) that says required in another form.
# NAME is "-" when the @param line names no var.
form_violations() {
  local root=$1 m=$2
  [[ -d "$root/csi-spl-$m/src/bash/run" ]] || return 0
  local w='(^|[^a-z0-9_])required([^a-z0-9_]|$)'
  (cd "$root" && find "csi-spl-$m/src/bash/run" -name '*.func.sh' -print0 | sort -z | xargs -0 -r awk -v w="$w" '
    FNR == 1 { inp = 0 }
    !/^#/ { inp = 0; next }
    /^#-+[[:space:]]*$/ { inp = 0; next }
    /^#[[:space:]]*@param([[:space:]]|$)/ {
      rest = $0; sub(/^#[[:space:]]*@param[[:space:]]*/, "", rest)
      name = "-"
      if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) { name = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1) }
      inp = 1; cur = name
      if (tolower(rest) ~ w && $0 !~ /^# @param [A-Za-z_][A-Za-z0-9_]* \(required\) - [^ ]/)
        print FILENAME " " name " " FNR ": " $0
      next
    }
    /^#[[:space:]]*@[A-Za-z_]/ { inp = 0; next }
    inp && tolower($0) ~ w { print FILENAME " " cur " " FNR ": " $0 }
  ')
}

# check_form <root> <baseline> <module>: FAIL lines, then "measured <n> files".
check_form() {
  local root=$1 base=$2 m=$3 rel name rest key n
  local -A listed=() seen=()
  while read -r rel name _; do
    [[ -z "$rel" || "$rel" == \#* || "$rel" != csi-spl-$m/* ]] || listed["$rel $name"]=1
  done < <(cat "$base" 2>/dev/null)
  while read -r rel name rest; do
    [[ -n "$rel" ]] || continue
    key="$rel $name"; seen[$key]=1
    [[ -n "${listed[$key]:-}" ]] ||
      echo "FAIL: $rel:${rest%%:*} @param $name says required in another form; write \`# @param $name (required) - <text>\` when the action refuses without it, else drop the word: ${rest#*: }"
  done < <(form_violations "$root" "$m")
  for key in "${!listed[@]}"; do
    [[ -n "${seen[$key]:-}" ]] || echo "FAIL: $key is listed in the baseline but passes now (or is gone): delete its line"
  done
  n=$(find "$root/csi-spl-$m/src/bash/run" -name '*.func.sh' 2>/dev/null | wc -l)
  echo "measured $n files"
}

# fixture <dir> <module> [no-check]: a project tree with the module's run.sh,
# parse-metadata and (unless no-check) validate-params, and one action whose
# body writes $PROBE_MARK, else ran-without-mark in the project dir.
fixture() {
  local P="$1/base/org1/app1/app1-$2" src="$APP_ROOT/csi-spl-$2"
  mkdir -p "$P/src/bash/run" "$P/lib/bash/funcs"
  cp "$src/src/bash/run/run.sh" "$P/src/bash/run/run.sh" && chmod +x "$P/src/bash/run/run.sh"
  ln -s src/bash/run/run.sh "$P/run"
  printf '%s\n' 'do_detect_base_paths(){ :; }' 'do_load_config(){ :; }' \
    'do_require_bin(){ :; }' 'do_verify_symlinks(){ :; }' >"$P/lib/bash/funcs/fw.func.sh"
  cp "$src/lib/bash/funcs/parse-metadata.func.sh" "$P/lib/bash/funcs/"
  [[ "${3:-}" == no-check ]] || cp "$src/lib/bash/funcs/validate-params.func.sh" "$P/lib/bash/funcs/"
  cat >"$P/src/bash/run/probe-required.func.sh" <<'EOA'
#!/bin/bash
#------------------------------------------------------------------------------
# @description Write a marker file: proves the action body ran.
# @param PROBE_MARK (required) - the marker file to write
# @example PROBE_MARK=/tmp/x ./run -a do_probe_required
#------------------------------------------------------------------------------
do_probe_required() { : >"${PROBE_MARK:-$PWD/ran-without-mark}"; }
EOA
  echo "$P"
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# --- 1. form: red controls ---------------------------------------------------
mkdir -p "$T/f/csi-spl-iac/src/bash/run"
hdr() { printf '#!/bin/bash\n#---\n# @description d\n%s\n# @example ./run -a do_x\n#---\ndo_x() { :; }\n' "$1"; }
hdr '# @param GOOD (required) - the good one
# @param OPT_REQUIRED (optional) - a var whose name says it, 1 or 0
# @param CODE (optional) - the hub answers discussion_required' >"$T/f/csi-spl-iac/src/bash/run/good.func.sh"
: >"$T/base.txt"
out=$(check_form "$T/f" "$T/base.txt" iac)
if grep -q '^FAIL' <<<"$out"; then fail "CONTROL: the canonical form fails: $out"
else pass "CONTROL: the canonical form passes, and a word inside a name (OPT_REQUIRED, discussion_required) is not a marker"; fi
bad=('# @param X - required: dev or prd' '# @param X (REQUIRED) - dev or prd' '# @param X - required when DRY_RUN=0: the id'
  '# @param X - dev or prd (required)' '# @param X  (required) - two spaces' '# @param X (required)'
  '# @param X (required for set) - the doc' "# @param X - the id
#   (required on the first run)")
for b in "${bad[@]}"; do
  hdr "$b" >"$T/f/csi-spl-iac/src/bash/run/bad.func.sh"
  line=$(check_form "$T/f" "$T/base.txt" iac | grep -m1 '^FAIL')
  if [[ -n "$line" ]]; then pass "RED CONTROL '${b//$'\n'/ \\n }' -> FAIL"; else fail "RED CONTROL '${b//$'\n'/ \\n }' passed"; fi
done
hdr '# @param X - required: dev or prd' >"$T/f/csi-spl-iac/src/bash/run/bad.func.sh"
echo "csi-spl-iac/src/bash/run/bad.func.sh X" >"$T/base.txt"
out=$(check_form "$T/f" "$T/base.txt" iac)
if grep -q '^FAIL' <<<"$out"; then fail "CONTROL: a listed line fails: $out"; else pass "CONTROL: a listed line passes"; fi
hdr '# @param X (required) - dev or prd' >"$T/f/csi-spl-iac/src/bash/run/bad.func.sh"
line=$(check_form "$T/f" "$T/base.txt" iac | grep -m1 '^FAIL')
if [[ -n "$line" ]]; then pass "RED CONTROL a listed line fixed -> $line"; else fail "RED CONTROL a listed line fixed passed"; fi

# --- 2. enforced: control and red control ------------------------------------
for m in $MODULES; do
  P=$(fixture "$T/e-$m" "$m")
  out=$(cd "$P" && env -u PROBE_MARK ./run -a do_probe_required 2>&1); rc=$?
  if (( rc == 11 )) && [[ ! -e "$P/ran-without-mark" ]] && grep -q 'Required parameter PROBE_MARK is not set' <<<"$out"; then
    pass "$m: an unset (required) var stops the action before it runs (exit 11, body not run)"
  else fail "$m: an unset (required) var did not stop the action: rc=$rc body-ran=$([[ -e "$P/ran-without-mark" ]] && echo yes || echo no) $out"; fi
  (cd "$P" && PROBE_MARK="$T/mark-$m" ./run -a do_probe_required >/dev/null 2>&1); rc=$?
  if (( rc == 0 )) && [[ -e "$T/mark-$m" ]]; then pass "$m: with the var set the action runs"
  else fail "$m: with the var set the action did not run (rc=$rc)"; fi
  P=$(fixture "$T/n-$m" "$m" no-check)
  (cd "$P" && env -u PROBE_MARK ./run -a do_probe_required >/dev/null 2>&1)
  if [[ -e "$P/ran-without-mark" ]]; then pass "RED CONTROL $m: without validate-params.func.sh the body runs (the check is what stops it)"
  else fail "RED CONTROL $m: without validate-params.func.sh the body still did not run: the probe proves nothing"; fi
done

# --- 1. form: the real tree --------------------------------------------------
for m in $MODULES; do
  out=$(check_form "$APP_ROOT" "$BASELINE" "$m")
  grep '^FAIL' <<<"$out"
  fails=$((fails + $(grep -c '^FAIL' <<<"$out")))
  n=$(tail -1 <<<"$out" | awk '{ print $2 }')
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 10 )); then pass "$m: $(tail -1 <<<"$out")"
  else fail "$m: the walk measured only '$n' files: the walk is broken, not the code"; fi
  grep -q '^FAIL' <<<"$out" || pass "$m: every @param that says required says it as \`(required)\`"
done

(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
