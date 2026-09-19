#!/bin/bash

set -x

MODULE='gsheet-secrets-to-gcp'

test -z ${PROJ:-} && PROJ="${ORG_APP:-csi-spl}-iac"
test -z ${APPUSR:-} && APPUSR='appusr'

PROJ_DIR=${HOME_IAC_PROJ_PATH}

# Fix paths for mounted volumes (remove /home/$APPUSR prefix if present)
IAC_PROJ_PATH_FIXED=$(echo $IAC_PROJ_PATH | perl -ne "s|/home/$APPUSR||g;print")

# START ::: copy poetry venv for gsheet-secrets-to-gcp module
# The venv is built at image build time in HOME_IAC_PROJ_PATH
# At runtime, we need to copy it to the mounted IAC_PROJ_PATH and fix paths
home_venv_path="$HOME_IAC_PROJ_PATH/src/python/$MODULE/.venv"
venv_path="$IAC_PROJ_PATH_FIXED/src/python/$MODULE/.venv"

if [[ -d "$home_venv_path" ]]; then
  echo "Copying poetry venv from $home_venv_path to $venv_path"
  # Ensure target directory exists
  mkdir -p "$(dirname "$venv_path")"
  # do not use rm -r on venv_path !!! Big GOTCHA !!!
  cp -r "$home_venv_path" "$venv_path" 2>/dev/null || true
  # Fix paths in the activate script
  if [[ -f "$venv_path/bin/activate" ]]; then
    perl -pi -e "s|/home/$APPUSR||g" "$venv_path/bin/activate"
    echo "Poetry venv copied and paths fixed"
  fi
fi
# STOP  ::: copy poetry venv for gsheet-secrets-to-gcp module

cd ${PROJ_DIR} || exit 1

# spe-2880 - otherwise the CNF_VER git hash fetch will fail ...
git config --global --add safe.directory ${PROJ_DIR}
git config --global --add safe.directory ${IAC_PROJ_PATH_FIXED}

# Add poetry to PATH
echo 'export PATH=$PATH:$HOME/.local/bin/' >> ~/.bashrc
echo "cd ${PROJ_DIR}" >> ~/.bashrc

trap : TERM INT
sleep infinity &
wait
