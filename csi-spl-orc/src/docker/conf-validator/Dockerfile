FROM python:3.10-slim-bookworm

# START ::: vars
ARG GID
ARG UID
ARG ORG_DIR
ARG APPUSR
ARG APPGRP
ARG DOCKER_HOME
ARG APP_PATH
ARG TPG_PROJ_PATH
ARG UTL_PROJ_PATH
ARG IAC_PROJ_PATH
ARG CNF_PROJ_PATH
ARG HOME_UTL_PROJ_PATH
ARG HOME_CNF_PROJ_PATH
ARG HOME_IAC_PROJ_PATH
ARG HOME_TPG_PROJ_PATH

ENV PROJ_PATH=$UTL_PROJ_PATH
ENV HOME_PROJ_PATH=$HOME_TPL_PROJ_PATH

ARG ORG_APP
ENV MODULE='conf-validator'
ENV ORG_APP=$ORG_APP
ENV EDITOR="vim"
ENV PS1='`date "+%F %T"` \u@\h  \w \n\n  '
ENV HOME_APP_PATH=${DOCKER_HOME}${APP_PATH}
# STOP  ::: vars


# START ::: install alpine OS utils
RUN apt-get update && apt-get install -y --no-install-recommends  \
  perl jq vim wget curl sudo zip unzip make bsdmainutils tzdata
# STOP  ::: install alpine OS utils


# isntall python pip
RUN wget https://bootstrap.pypa.io/get-pip.py ; python3 get-pip.py ; sudo rm -v get-pip.py

RUN pip install --upgrade pip
RUN pip install wheel







# set the default shell as bash and not sh
SHELL ["/bin/bash", "-c"]

# STOP  ::: install-poetry

# START ::: add-os-user

# Your existing commands for groupadd and useradd
RUN GID="${GID:-1000}" ; if getent group $GID ; then groupmod -g $((GID+3333)) $(getent group $GID  | cut -d: -f1); fi

RUN set -x ; \
  UID="${UID:-1000}" ; GID="${GID:-1000}" ; \
  groupadd -g "$GID" "${APPGRP}" && \
  useradd \
  --gid "$GID" \
  --non-unique \
  --shell "/bin/bash" \
  --home-dir "${DOCKER_HOME}" \
  --uid "$UID" \
  --groups "${APPGRP}" "${APPUSR}" && exit 0 ; exit 1



# create home directory and change its ownership to ${APPUSR}:${APPGRP}
RUN mkdir -p "${DOCKER_HOME}" && chown "${APPUSR}":"${APPGRP}" "${DOCKER_HOME}"


RUN echo "${APPUSR} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
RUN echo "export PS1=\"$PS1\"" >> $DOCKER_HOME/.bashrc && \
  chown -R ${APPUSR}:${APPGRP} "${DOCKER_HOME}" && \
  chmod -R 0775 "${DOCKER_HOME}"

RUN echo 'export PATH=$PATH:${DOCKER_HOME}/.local/bin/' >> ${DOCKER_HOME}/.bashrc

ENV PATH="${PATH}:${DOCKER_HOME}/.local/bin/"

# STOP  ::: add-os-user



# csi-spl: the conf-validator .venv is a named volume (docker-compose-tf-infra.yaml).
# A new named volume copies owner and mode from the image dir it is mounted
# on; without this dir it is created root:root and the appusr init cannot
# write it (measured 2026-09-19 by CLE-3359: "destination . is not write-able").
RUN mkdir -p "${CNF_PROJ_PATH}/src/python/conf-validator/.venv" \
  && chown "$APPUSR":"$APPGRP" "${CNF_PROJ_PATH}/src/python/conf-validator/.venv"

WORKDIR $HOME_UTL_PROJ_PATH
USER ${APPUSR}

# START  ::: install-poetry
ENV POETRY_VERSION=2.3.2
RUN pip install --no-cache-dir poetry==$POETRY_VERSION
# STOP  ::: install-poetry

# Derive ORG and APP from ORG_APP at runtime
RUN echo "export ORG_APP=$ORG_APP" >> $DOCKER_HOME/.bashrc && \
    echo 'export ORG=${ORG_APP%%-*}' >> $DOCKER_HOME/.bashrc && \
    echo 'export APP=${ORG_APP##*-}' >> $DOCKER_HOME/.bashrc

# Project files are mounted via docker-compose volume — no COPY needed
# Poetry modules are installed at runtime by the init script
WORKDIR $HOME_UTL_PROJ_PATH
