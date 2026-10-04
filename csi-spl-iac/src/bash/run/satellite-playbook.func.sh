#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057, owner topic 6f10f92b: run the satellite's Ansible
# @description setup (step 060's box-playbook.yaml) the way the owner asked,
# @description "via the docker": the run-ansible script terraform 060 writes
# @description (07-ansible.tf, the eli-vta pattern), executed INSIDE the
# @description tf-runner container, exactly as do_tf_apply runs it after a
# @description 060 apply. This is the ad-hoc path of eli-vta's comment
# @description (`docker exec -it con-...-tf-runner bash <script>`) as a named
# @description action. The container supplies the SA keys (~/.gcp, mounted)
# @description and the GitHub token (its GITHUB_TOKEN); nothing secret is on
# @description this command line. Idempotent: re-run it any time.
# @description No script yet = no 060 apply from the mounted tree yet: run
# @description `make do-provision ENV=prd STEP=060-gcp-vm-satellite` (owner go).
# @param SATELLITE_PLAYBOOK_ARGS (optional) - passed to ansible-playbook,
# @param        e.g. "--tags 05_users" or "--check --diff"
# @param TF_RUNNER (optional) - default con-<org>-<org>-<app>-tf-runner
# @example ./run -a do_satellite_playbook
# @example SATELLITE_PLAYBOOK_ARGS="--tags 05_users,06_secrets" ./run -a do_satellite_playbook
#------------------------------------------------------------------------------
do_satellite_playbook() {
  local org app env=prd step=060-gcp-vm-satellite con script inner
  do_resolve_oap ORG; do_resolve_oap APP
  org="${ORG:?}" app="${APP:?}"
  con="${TF_RUNNER:-con-${org}-${org}-${app}-tf-runner}"
  command -v docker >/dev/null 2>&1 || { do_log "FATAL docker is not installed"; return 1; }
  docker inspect -f '{{.State.Running}}' "$con" 2>/dev/null | grep -x true >/dev/null \
    || { do_log "FATAL the tf-runner $con is not running (cd ${org}-${app}-orc && make do-setup-app-inf, from the main checkout)"; return 1; }
  # the container mounts the main checkout at APP_PATH; the script lives in its csi-spl-iac
  inner=$(docker exec "$con" bash -c 'printf %s "$APP_PATH"') || return 1
  script="${inner}/${org}-${app}-iac/src/bash/scripts/run-ansible-${org}-${app}-${env}-${step}.sh"
  docker exec "$con" test -x "$script" \
    || { do_log "FATAL no $script in $con: apply 060 first (cd ${org}-${app}-orc && ENV=prd STEP=${step} make do-provision, owner go) - it writes the script"; return 1; }
  do_log "INFO docker exec $con bash $script ${SATELLITE_PLAYBOOK_ARGS:-}"
  # shellcheck disable=SC2086
  docker exec -i "$con" bash "$script" ${SATELLITE_PLAYBOOK_ARGS:-} \
    || { do_log "FATAL the playbook failed (the recap above; log ${inner}/${org}-${app}-iac/dat/log/ansible.${step}.${org}-${app}-${env}.log)"; return 1; }
  do_log "OK the satellite is provisioned by Ansible: ./run -a do_satellite_verify"
}
