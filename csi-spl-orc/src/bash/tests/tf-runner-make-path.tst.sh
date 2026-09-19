#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: terraform runs only through the csi-rel make -> tf-runner path
#          (csi-spl-doc/specs/007-spool-hub-api-infra/csi-rel-flow-map.md).
#          Static checks, no container is started:
#          1. `make -n do-tf-plan / do-provision / do-deprovision` exec into
#             con-<org>-<app>-tf-runner and run the iac ./run action there,
#             with APP handed over in its short form.
#          2. the container name tf-tasks execs into (do_resolve_oap) is the
#             one docker-compose-tf-infra.yaml creates, for this tree.
#          3. the compose project and image names are csi-spl's own, so
#             `make do-setup-app-inf` (down --rmi all) cannot reach another
#             app's stack or its img-tf-runner tag.
#          4. tpl-gen and conf-validator keep their poetry venvs in named
#             volumes, not in the host trees they mount.
#          CONTROLS: a compose config with the csi-rel image name planted, and
#          one without the venv volume, are refused by the same check.
#          Needs make + docker compose v2 (config only); FAILS without them.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

cd "$ORC" || exit 1
for pair in do-tf-plan:do_tf_plan do-provision:do_provision do-deprovision:do_divest; do
  tgt=${pair%%:*} act=${pair##*:}
  out=$(ENV=dev STEP=000-gcp-remote-bucket GITHUB_TOKEN=x make --no-print-directory -n "$tgt" 2>/dev/null)
  if grep -q 'docker exec' <<<"$out" && grep -q 'con-$ORG-$APP-tf-runner' <<<"$out" \
     && grep -q -- "./run -a $act" <<<"$out" && grep -q -- '-e APP=${APP#\*-}' <<<"$out"; then
    pass "make $tgt -> docker exec con-<org>-<app>-tf-runner ./run -a $act"
  else
    fail "make $tgt does not exec $act in the tf-runner: $(tail -4 <<<"$out" | tr '\n' ' ')"
  fi
done

want=$(APP_PATH="$(cd "$ORC/.." && pwd)" PROJ_PATH="$ORC" bash -c \
  'source lib/bash/funcs/resolve-oap.func.sh; unset ORG APP; do_resolve_oap ORG; do_resolve_oap APP; echo "con-$ORG-$APP-tf-runner"')
cfg=$(GITHUB_TOKEN=x make --no-print-directory --eval 'zz-cfg: ; @$(DOCKER_COMPOSE_CMD) -f $(DOCKER_COMPOSE_FILE_WUI_INF) config' zz-cfg 2>&1)
check_cfg() {  # <compose config> -> problems, one per line
  local c="$1" img
  grep -q "container_name: $want\$" <<<"$c" || echo "no container named $want"
  grep -q '^name: con-csi-csi-spl-tf-infra$' <<<"$c" || echo "compose project is not con-csi-csi-spl-tf-infra"
  for img in $(awk '/^    image:/{print $2}' <<<"$c"); do
    [[ "$img" == img-csi-spl-* ]] || echo "image $img is not csi-spl's own"
  done
  [[ $(grep -c '^    image:' <<<"$c") -eq 3 ]] || echo "expected 3 images (tf-runner, tpl-gen, conf-validator)"
  # the tpl-gen init rm -r's + poetry-installs its in-project .venv; on the
  # bind mount that is the HOST venv of do_tpl_gen and the iac tests
  grep -q 'source: tpl-gen-venv' <<<"$c" || echo "tpl-gen .venv is not a named volume (the container would clobber the host venv)"
  grep -q 'source: conf-validator-venv' <<<"$c" || echo "conf-validator .venv is not a named volume (the container would share the host venv)"
}
if [[ -z "$cfg" || "$cfg" != *services:* ]]; then
  fail "docker compose config did not render (make + docker compose v2 needed): $(head -2 <<<"$cfg")"
else
  probs=$(check_cfg "$cfg")
  [[ -z "$probs" ]] && pass "compose: $want, project con-csi-csi-spl-tf-infra, images img-csi-spl-*" \
    || fail "compose: $(tr '\n' ';' <<<"$probs")"
  novol=$(sed 's/source: tpl-gen-venv/source: gone/' <<<"$cfg")
  [[ "$(check_cfg "$novol")" == *"not a named volume"* ]] && pass "control: a tpl-gen without its venv volume is refused" \
    || fail "control: a tpl-gen writing the host venv passed"
  novol=$(sed 's/source: conf-validator-venv/source: gone/' <<<"$cfg")
  [[ "$(check_cfg "$novol")" == *"conf-validator .venv is not"* ]] && pass "control: a conf-validator without its venv volume is refused" \
    || fail "control: a conf-validator sharing the host venv passed"
  bad=$(sed 's/image: img-csi-spl-tf-runner/image: img-tf-runner/' <<<"$cfg")
  [[ "$(check_cfg "$bad")" == *"img-tf-runner is not"* ]] && pass "control: a shared img-tf-runner tag is refused" \
    || fail "control: a planted img-tf-runner passed"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
