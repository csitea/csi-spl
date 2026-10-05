#!/bin/bash
# Service tpl-gen (docker-compose-tf-infra.yaml) runs this, then sleep infinity.
# Before the keep-alive it needs PROJ_PATH and a poetry venv at
# src/python/tpl-gen/.venv sourced from ~/.bashrc. poetry install failure exits first.
set -uo pipefail

MODULE='tpl-gen'

test -z ${PROJ:-} && PROJ=${MODULE:-}

# BASE_PATH is not in this service's environment. An empty default keeps the
# old unset behaviour: the echo used to print nothing, and nounset would exit
# here on a container that is otherwise ready.
: "${BASE_PATH:=}"
PROJ_PATH=$(echo $PROJ_PATH | perl -ne "s|/home/$APPUSR||g;print")
BASE_PATH=$(echo $BASE_PATH | perl -ne "s|/home/$APPUSR||g;print")

# home_venv_path (HOME_PROJ_PATH/.../.venv) was assigned and never read.
# tpl-gen differs from tf-runner, whose comment forbids rm -r on a venv
# because copying a venv onto the same mounted directory nested .venv forever.
# Here the named volume tpl-gen-venv is mounted on this in-project .venv, so
# rm -r clears that volume and poetry install rebuilds it. Nothing copies a
# home venv onto it.
venv_path="$PROJ_PATH/src/python/$MODULE/.venv"

if [ -d "$venv_path" ]; then
  rm -r "$venv_path"
fi

cd "$PROJ_PATH/src/python/$MODULE" && poetry install || { echo "FATAL poetry install"; exit 1; }
perl -pi -e "s|/home/$APPUSR||g" "$venv_path/bin/activate"

# if it points to PROJ_PATH it will always be broken
echo "source $PROJ_PATH/src/python/$MODULE/.venv/bin/activate" >>~/.bashrc
echo "source $PROJ_PATH/src/python/$MODULE/.venv/bin/activate" >>~/.profile
# cd "$PROJ_PATH/src/python/$MODULE && poetry install"

echo "cd $PROJ_PATH" >>~/.bashrc

trap : TERM INT
sleep infinity &
wait
