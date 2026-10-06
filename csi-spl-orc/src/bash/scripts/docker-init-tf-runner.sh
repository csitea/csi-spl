#!/bin/bash
# Service tf-runner (docker-compose-tf-infra.yaml) runs this, then sleep infinity.
# Before the keep-alive it needs HOME_IAC_PROJ_PATH, git safe.directory on that
# tree, and poetry on PATH in ~/.bashrc. A setup failure exits; the keep-alive does not start.
set -x
set -uo pipefail

test -z ${PROJ:-} && PROJ="${ORG_APP:-csi-spl}-iac"
test -z ${APPUSR:-} && APPUSR='appusr'

# Unset or empty is a setup failure: leave before sleep infinity.
: "${HOME_IAC_PROJ_PATH:?}"
PROJ_DIR=${HOME_IAC_PROJ_PATH}

# Fix paths for mounted volumes (remove /home/$APPUSR prefix if present)
IAC_PROJ_PATH_FIXED=$(echo $IAC_PROJ_PATH | perl -ne "s|/home/$APPUSR||g;print")

cd "${PROJ_DIR}" || exit 1

# spe-2880 - otherwise the CNF_VER git hash fetch will fail ...
git config --global --add safe.directory "${PROJ_DIR}"
git config --global --add safe.directory ${IAC_PROJ_PATH_FIXED}

# Add poetry to PATH
echo 'export PATH=$PATH:$HOME/.local/bin/' >> ~/.bashrc
echo "cd ${PROJ_DIR}" >> ~/.bashrc

trap : TERM INT
sleep infinity &
wait
