# csi-spl: csi-rel pins python:3.10.11-slim-bullseye; a fresh build of it now
# 404s on bullseye-security (Debian 11 LTS ended 2026-08-31). Same python
# minor on bookworm, the base conf-validator already uses.
FROM python:3.10-slim-bookworm


# START ::: vars
ARG GID
ARG UID
ARG ORG_APP
ARG ORG_DIR
ARG UTL_PROJ_PATH
ARG APPUSR
ARG APPGRP
ARG HOME_UTL_PROJ_PATH
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

ENV UTL_PROJ_PATH=$UTL_PROJ_PATH
ENV TPG_PROJ_PATH=$TPG_PROJ_PATH
ENV CNF_PROJ_PATH=$CNF_PROJ_PATH
ENV IAC_PROJ_PATH=$IAC_PROJ_PATH
ENV HOME_UTL_PROJ_PATH=$HOME_UTL_PROJ_PATH
ENV HOME_TPG_PROJ_PATH=$HOME_TPG_PROJ_PATH
ENV HOME_CNF_PROJ_PATH=$HOME_CNF_PROJ_PATH
ENV HOME_IAC_PROJ_PATH=$HOME_IAC_PROJ_PATH

ENV MODULE='tpl-gen'
ENV EDITOR="vim"
ENV PS1='`date "+%F %T"` \u@\h  \w \n\n  '

ENV PROJ_PATH=$TPG_PROJ_PATH
ENV HOME_PROJ_PATH=$HOME_TPG_PROJ_PATH
ENV ORG_APP=$ORG_APP
ENV ORG_DIR=$ORG_DIR
ENV UTL_PROJ_PATH=$UTL_PROJ_PATH
ENV APPUSR=$APPUSR
ENV APPGRP=$APPGRP
ENV HOME_UTL_PROJ_PATH=$HOME_UTL_PROJ_PATH
ENV DOCKER_HOME=$DOCKER_HOME
ENV HOME_APP_PATH=/home/$APPUSR/$APP_PATH

# STOP  ::: vars


# START ::: install OS utils

RUN apt-get -o Acquire::Check-Valid-Until=false update && apt-get install -y --no-install-recommends  \
  perl jq vim wget curl sudo zip unzip make bsdmainutils tzdata
# STOP  ::: install  OS utils


# isntall python pip
RUN wget https://bootstrap.pypa.io/get-pip.py ; sudo python3 get-pip.py ; sudo rm -v get-pip.py

RUN pip3 install --upgrade pip
RUN pip3 install wheel


# START ::: add-os-user
RUN if getent group $GID; then groupmod -g $((GID+2000)) $(getent group $GID | cut -d: -f1); fi

# create a APPGRP and APPUSR
# START ::: add-os-user
RUN set -x ; \
  UID="${UID:-1000}" ; GID="${GID:-1000}" ; \
  groupadd -g "$GID" "$APPGRP" && \
  useradd \
  --gid "$GID" \
  --non-unique \
  --shell "$DOCKER_SHELL" \
  --home-dir "${DOCKER_HOME}" \
  --uid "$UID" \
  --groups "$APPGRP" "$APPUSR" && exit 0 ; exit 1

# create home directory and change its ownership to APPUSR:APPGRP
RUN mkdir -p "/home/$APPUSR" && chown "$APPUSR":"$APPGRP" "${DOCKER_HOME}"


RUN echo "$APPUSR ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
RUN echo "export PS1=\"$PS1\"" >> $DOCKER_HOME/.bashrc && \
  chown -R $APPUSR:$APPGRP $DOCKER_HOME && \
  chmod -R 0775 $DOCKER_HOME

# csi-spl: the tpl-gen .venv is a named volume (docker-compose-tf-infra.yaml).
# A new named volume copies owner and mode from the image dir it is mounted
# on; without this dir it is created root:root and the appusr init cannot
# write it (measured 2026-09-19 by CLE-3359: "destination . is not write-able").
RUN mkdir -p "${TPG_PROJ_PATH}/src/python/tpl-gen/.venv" \
  && chown "$APPUSR":"$APPGRP" "${TPG_PROJ_PATH}/src/python/tpl-gen/.venv"


USER $APPUSR

# STOP  ::: add-os-user



# START ::: install-poetry
ENV POETRY_VERSION=2.3.2
RUN pip install --no-cache-dir poetry==$POETRY_VERSION
RUN echo 'export PATH=$PATH:$HOME/.local/bin/' >> $HOME/.bashrc
ENV PATH="${PATH}:/home/${APPUSR}/.local/bin/"
SHELL ["/bin/bash", "-c"]
# STOP  ::: install-poetry



# Derive ORG and APP from ORG_APP at runtime
RUN echo "export ORG_APP=$ORG_APP" >> $DOCKER_HOME/.bashrc && \
    echo 'export ORG=${ORG_APP%%-*}' >> $DOCKER_HOME/.bashrc && \
    echo 'export APP=${ORG_APP##*-}' >> $DOCKER_HOME/.bashrc

# Project files are mounted via docker-compose volume — no COPY needed
# Poetry modules are installed at runtime by the init script


#RUN chmod 0775 "$HOME_PROJ_PATH/src/bash/scripts/docker-init-${MODULE}.sh"
WORKDIR $HOME_PROJ_PATH

CMD exec /bin/bash -c "$HOME_PROJ_PATH/src/bash/scripts/docker-init-${MODULE}.sh"
