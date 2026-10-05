#!/bin/bash
# Service conf-validator (docker-compose-tf-infra.yaml) runs this, then sleep infinity.
# Before the keep-alive it needs CNF_PROJ_PATH and src/python/conf-validator/.venv
# sourced from ~/.bashrc. A poetry install failure exits before the keep-alive.
set -uo pipefail

MODULE='conf-validator'

test -z ${PROJ:-} && PROJ=${MODULE:-}

# BASE_PATH is not in this service's environment. See docker-init-tpl-gen.sh.
: "${BASE_PATH:=}"
CNF_PROJ_PATH=$(echo $CNF_PROJ_PATH | perl -ne "s|/home/$APPUSR||g;print")
BASE_PATH=$(echo $BASE_PATH | perl -ne "s|/home/$APPUSR||g;print")

venv_path="$CNF_PROJ_PATH/src/python/$MODULE/.venv"

# Only run poetry install if .venv does not yet exist.
# The two volume mounts (APP_PATH and DOCKER_HOME+APP_PATH) resolve to the
# SAME host directory, so home_venv_path == venv_path physically.
# The old "cp -r $home_venv_path $venv_path" was copying .venv into itself,
# creating .venv/.venv/.venv/... on every container restart.
# Unlike tpl-gen, this service does not rm -r the venv: a missing activate
# is the only reason to poetry-install. The named volume conf-validator-venv
# holds that .venv so the container does not share the host one.
if [[ ! -f "$venv_path/bin/activate" ]]; then
  cd "$CNF_PROJ_PATH/src/python/$MODULE" && poetry install || { echo "FATAL poetry install"; exit 1; }
  perl -pi -e "s|/home/$APPUSR||g" "$venv_path/bin/activate"
fi

# if it points to PROJ_PATH it will always be broken
echo "source $CNF_PROJ_PATH/src/python/$MODULE/.venv/bin/activate" >>~/.bashrc
echo "source $CNF_PROJ_PATH/src/python/$MODULE/.venv/bin/activate" >>~/.profile

echo "cd $CNF_PROJ_PATH" >>~/.bashrc

trap : TERM INT
sleep infinity &
wait
