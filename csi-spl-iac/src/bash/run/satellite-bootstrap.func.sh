#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057 5.4: make the satellite a fleet box, over the IAP ssh,
# @description idempotent and re-runnable:
# @description   1. waits for sshd, then runs satellite-box-setup.sh as root
# @description      (data disk, OS user, packages, ssh hardening; one ROLE
# @description      verdict line each)
# @description   2. 05_spool_harness, as the box user: clones the repo into
# @description      /opt/csi/<org>-<app> with the pushed GitHub token (needs
# @description      do_satellite_creds_push first), writes the spool env
# @description      (SPOOL_ROOT, SPOOL_BOX_TAG) into ~/.bashrc, and runs the
# @description      repo's spool-install/install.sh (agent CLIs, yq, Go, the
# @description      spool binary, hooks, skills; --no-seat: seating a desk is
# @description      its own step with the tenant admin)
# @param SATELLITE_CLIS (optional) - install.sh --cli list, default claude
# @param SATELLITE_BOX_TAG (optional) - default sat (spec 4.1 Q11)
# @param SATELLITE_SKIP_HARNESS (optional) - 1: step 1 only
# @example ./run -a do_satellite_bootstrap
#------------------------------------------------------------------------------
do_satellite_bootstrap() {
  do_satellite_ssh_opts || return 1
  local user repo tag="${SATELLITE_BOX_TAG:-sat}" i
  user=$(do_satellite_cnf os_user) || return 1
  repo=$(do_satellite_cnf gh_repo 120-github-general-secrets) || return 1

  for i in $(seq 1 20); do
    ssh "${SATELLITE_SSH[@]}" true 2>/dev/null && break
    do_log "INFO waiting for sshd on ${SATELLITE_HOST} over IAP ($i/20)"
    sleep 15
  done
  ssh "${SATELLITE_SSH[@]}" true || { do_log "FATAL cannot ssh to ${SATELLITE_HOST} over IAP"; return 1; }

  # shellcheck disable=SC2029
  ssh "${SATELLITE_SSH[@]}" "sudo BOX_USER='${user}' bash -s" <"${PROJ_PATH}/src/bash/scripts/satellite-box-setup.sh" \
    || { do_log "FATAL satellite-box-setup.sh reported a failed role (the ROLE lines above)"; return 1; }

  [[ "${SATELLITE_SKIP_HARNESS:-0}" == 1 ]] && { do_log "OK box setup done; harness skipped (SATELLITE_SKIP_HARNESS=1)"; return 0; }

  local dir="/opt/csi/${repo##*/}"
  # the remote script: the token is read ON the satellite from the file the
  # creds push wrote; it never crosses this command line
  # shellcheck disable=SC2016
  ssh "${SATELLITE_SSH[@]}" "REPO='${repo}' DIR='${dir}' TAG='${tag}' CLIS='${SATELLITE_CLIS:-claude}' bash -s" <<'REMOTE' || { do_log "FATAL 05_spool_harness failed"; return 1; }
set -uo pipefail
[[ -r "$HOME/.github/token" ]] || { echo "ROLE 05_spool_harness FAIL no ~/.github/token: run DRY_RUN=0 ./run -a do_satellite_creds_push first"; exit 1; }
helper='!f() { echo username=x-access-token; echo "password=$(cat "$HOME/.github/token")"; }; f'
if [[ ! -d "$DIR/.git" ]]; then
  git -c credential.helper= -c "credential.helper=$helper" clone -q "https://github.com/${REPO}.git" "$DIR" \
    || { echo "ROLE 05_spool_harness FAIL git clone ${REPO}"; exit 1; }
  git -C "$DIR" config credential.helper "$helper"
  echo "ROLE 05_spool_harness CHANGED cloned ${REPO} -> $DIR"
else
  git -C "$DIR" pull -q --ff-only || echo "ROLE 05_spool_harness WARN $DIR did not fast-forward (left as is)"
fi
b='# >>> csi-spl satellite spool env >>>' e='# <<< csi-spl satellite spool env <<<'
if ! grep -qxF "$b" "$HOME/.bashrc" 2>/dev/null; then
  printf '%s\nexport SPOOL_ROOT=/var/spool-hub\nexport SPOOL_BOX_TAG=%s\nexport PATH="$HOME/.local/bin:$PATH"\n%s\n' "$b" "$TAG" "$e" >>"$HOME/.bashrc"
fi
export SPOOL_ROOT=/var/spool-hub SPOOL_BOX_TAG="$TAG" PATH="$HOME/.local/bin:$PATH"
cd "$DIR" && bash csi-spl-orc/src/bash/features/spool-install/install.sh --cli "$CLIS" --no-seat \
  || { echo "ROLE 05_spool_harness FAIL spool-install/install.sh"; exit 1; }
echo "ROLE 05_spool_harness OK $DIR, SPOOL_BOX_TAG=$TAG, clis=$CLIS"
REMOTE
  do_log "OK the satellite is bootstrapped: 'ssh satellite' (after do_satellite_ssh_config), then the owner logs in to each AI CLI there"
}
