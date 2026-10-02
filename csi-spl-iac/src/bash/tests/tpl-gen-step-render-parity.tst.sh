#!/usr/bin/env bash
# pre-push-tier: slow -- needs the tpl-gen venv a worktree does not carry (CI runs do_setup_tpl_gen)
#------------------------------------------------------------------------------
# Purpose: the csi-rel container path (csi-spl-orc `make
#          do-generate-config-for-step`) renders EXACTLY the committed tfvars,
#          step by step, in both envs -- the same bytes the native
#          `ENV=<env> ./run -a do_tpl_gen` writes (tf-steps-render-and-
#          validate part 1). No docker: tpl-gen runs from its venv with the
#          environment the recipe hands the tpl-gen container
#          (ORG=csi APP=csi-spl ENV STEP DATA_KEY_PATH, TPL_SRC through the
#          %app% symlink, CNF_SRC = the effective config do-spl-merged-cnf
#          writes). The recipe is grepped for those settings, so the test
#          goes red when the recipe drifts from what it simulates.
#          Control: a planted value in the effective config MUST show up as a
#          diff; a comparison that misses it proves nothing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
CNF_DIR="$APP_ROOT/csi-spl-cnf/csi-spl"
MK="$APP_ROOT/csi-spl-orc/src/make/generate-config-for-step.func.mk"
fails=0

# --- 0. the recipe hands the container what this test simulates --------------
for want in '-e CNF_SRC=$(SPL_MERGED_CNF)' "-e DATA_KEY_PATH='.env.steps[\"\$(STEP)\"]'" \
  '-e TPL_SRC=$(APP_PATH)/$(APP)-iac/src/tpl/%app%/%env%/tf/$(STEP)*.tpl' '-e TGT=$(APP_PATH)/$(APP)-cnf' \
  'poetry run validate $(SPL_MERGED_CNF) $(ENV)'; do
  grep -qF -- "$want" "$MK" && pass "recipe: $want" || fail "recipe no longer carries: $want"
done
[[ "$(readlink "$PROJ_ROOT/src/tpl/%app%")" == '%org%-%app%' ]] &&
  pass "src/tpl/%app% -> %org%-%app%" || fail "src/tpl/%app% is not the symlink to %org%-%app%"

TPG=""
main_root=$(git -C "$APP_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs -r dirname)
for c in "${TPL_GEN_DIR:-}" "$APP_ROOT/tpl-gen" "${main_root:+$main_root/tpl-gen}"; do
  [[ -n "$c" && -x "$c/src/python/tpl-gen/.venv/bin/python" ]] && { TPG="$c/src/python/tpl-gen"; break; }
done
[[ -n "$TPG" ]] || { fail "no tpl-gen venv (TPL_GEN_DIR, $APP_ROOT/tpl-gen, ${main_root:-<main checkout>}/tpl-gen)"; exit 1; }
# shellcheck disable=SC1091
source "$PROJ_ROOT/lib/bash/funcs/spl-merged-cnf.func.sh"

# render <env> <step> <cnf> <tgt>: one container-shaped tpl-gen run
render() {
  ( cd "$TPG" && env -i PATH="$PATH" HOME="$HOME" ORG_APP=csi-spl ORG=csi APP=csi-spl ENV="$1" STEP="$2" \
      DATA_KEY_PATH=".env.steps[\"$2\"]" TPL_SRC="$PROJ_ROOT/src/tpl/%app%/%env%/tf/$2*.tpl" \
      CNF_SRC="$3" TGT="$4" .venv/bin/python tpl_gen/tpl_gen.py >/dev/null 2>&1 )
}
# scratch TGT exactly as deep as $APP_ROOT/csi-spl-cnf: tpl-gen maps a
# template to its output by stripping as many leading components as TGT has
# (it can pad, never shorten: a scratch deeper than that is refused, by name)
mk_tgt() {
  local t="$1"
  (( $(tr -cd / <<<"$t" | wc -c) <= $(tr -cd / <<<"$APP_ROOT/csi-spl-cnf" | wc -c) )) || {
    echo "scratch $t is deeper than $APP_ROOT/csi-spl-cnf: use a shallower TMPDIR" >&2; return 1; }
  while (( $(tr -cd / <<<"$t" | wc -c) < $(tr -cd / <<<"$APP_ROOT/csi-spl-cnf" | wc -c) )); do t="$t/d"; done
  echo "$t"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for env in dev prd; do
  cnf="$tmp/$env.cnf/$env.env.yaml"
  mkdir -p "$(dirname "$cnf")"
  do_spl_merged_cnf "$CNF_DIR" "$env" "$cnf" || { fail "$env: no effective config"; continue; }
  tgt=$(mk_tgt "$tmp/$env") || { fail "$env: SETUP: scratch too deep for a step-by-step render (TMPDIR=${TMPDIR:-/tmp})"; continue; }
  n=0 bad=""
  for d in "$PROJ_ROOT"/src/terraform/[0-9]*/; do
    step=$(basename "$d")
    render "$env" "$step" "$cnf" "$tgt" || { bad="$bad $step(render-failed)"; continue; }
    for f in "$CNF_DIR/$env/tf/$step".*.tfvars; do
      n=$((n + 1))
      cmp -s "$f" "$tgt/csi-spl/$env/tf/$(basename "$f")" || bad="$bad $(basename "$f")"
    done
  done
  [[ -z "$bad" && $n -gt 0 ]] && pass "$env: $n tfvars rendered step by step equal the committed ones" ||
    fail "$env: container-path render differs from the committed tfvars:$bad"
done

# --- control: a planted value must surface -----------------------------------
cnf="$tmp/ctl/dev.env.yaml"
mkdir -p "$tmp/ctl"
do_spl_merged_cnf "$CNF_DIR" dev "$cnf"
yq -i '.env.steps."020-gcp-relay-bucket".object_max_age_days = 2' "$cnf"
tgt=$(mk_tgt "$tmp/ctlout") || tgt="$tmp/ctlout"
render dev 020-gcp-relay-bucket "$cnf" "$tgt"
if ! cmp -s "$CNF_DIR/dev/tf/020-gcp-relay-bucket.vars.tfvars" "$tgt/csi-spl/dev/tf/020-gcp-relay-bucket.vars.tfvars" &&
  grep -qx 'object_max_age_days = 2' "$tgt/csi-spl/dev/tf/020-gcp-relay-bucket.vars.tfvars"; then
  pass "CONTROL: a planted object_max_age_days = 2 is caught"
else
  fail "CONTROL: a planted value was not caught"
fi

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
