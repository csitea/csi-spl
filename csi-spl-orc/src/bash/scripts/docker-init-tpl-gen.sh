#!/bin/bash

MODULE='tpl-gen'

test -z ${PROJ:-} && PROJ=${MODULE:-}

PROJ_PATH=$(echo $PROJ_PATH | perl -ne "s|/home/$APPUSR||g;print")
BASE_PATH=$(echo $BASE_PATH | perl -ne "s|/home/$APPUSR||g;print")

home_venv_path="$HOME_PROJ_PATH/src/python/$MODULE/.venv"
venv_path="$PROJ_PATH/src/python/$MODULE/.venv"

if [ -d "$venv_path" ]; then
  rm -r "$venv_path"
fi

cd $PROJ_PATH/src/python/$MODULE && poetry install
perl -pi -e "s|/home/$APPUSR||g" $venv_path/bin/activate

# if it points to PROJ_PATH it will always be broken
echo "source $PROJ_PATH/src/python/$MODULE/.venv/bin/activate" >>~/.bashrc
echo "source $PROJ_PATH/src/python/$MODULE/.venv/bin/activate" >>~/.profile
# cd "$PROJ_PATH/src/python/$MODULE && poetry install"

echo "cd $PROJ_PATH" >>~/.bashrc

trap : TERM INT
sleep infinity &
wait
