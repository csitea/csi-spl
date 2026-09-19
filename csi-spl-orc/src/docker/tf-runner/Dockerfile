FROM --platform=amd64 python:slim-bookworm

# START ::: vars
ARG GID
ARG UID
ARG ORG_DIR
ARG UTL_PROJ_PATH
ARG APPUSR
ARG APPGRP
ARG DOCKER_HOME
ARG APP_PATH
ARG TF_VERSION
ARG TF_SWITCH_VERSION

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

ENV PROJ_PATH=$IAC_PROJ_PATH
ENV HOME_PROJ_PATH=$HOME_IAC_PROJ_PATH

ARG ORG_APP
ENV MODULE='tf-runner'
ENV ORG_APP=$ORG_APP
ENV ORG_DIR=$ORG_DIR

ENV EDITOR="vim"
ENV APPUSR=$APPUSR
ENV APPGRP=$APPGRP
ENV PS1='`date "+%F %T"` \u@\h  \w \n\n  '
ENV HOME_UTL_PROJ_PATH=$HOME_UTL_PROJ_PATH

ENV DOCKER_HOME=$DOCKER_HOME
ENV HOME_APP_PATH=/home/$APPUSR/$APP_PATH
ENV TF_VERSION=$TF_VERSION
ENV TF_SWITCH_VERSION=$TF_SWITCH_VERSION
# STOP  ::: vars

# START ::: install OS utils
RUN apt-get update && apt-get install -y --no-install-recommends  \
  perl jq vim wget curl sudo zip unzip make bsdmainutils tzdata git openssh-server openssh-client rsync dnsutils
# STOP  ::: install  OS utils

# START ::: install alpine OS utils

RUN apt-get update && apt-get install -y --no-install-recommends  \
  apt-utils perl-base jq vim wget curl sudo zip unzip make bsdmainutils tzdata \
  git openssh-server ansible gnupg
# STOP  ::: install alpine OS utils

# # START ::: install yq
RUN sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
  && sudo chmod a+x /usr/local/bin/yq
# STOP  ::: install yq


# # START ::: python build utils
# RUN RUN apt-get update && apt-get install -y  \
#     build-base gcc openssl-dev python3-dev libmagic  \
#     python3-dev jpeg-dev zlib-dev coreutils libffi-dev util-linux

# # STOP  ::: python build utils


# # START ::: install aws cli
# RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
#   && unzip awscliv2.zip \
#   && sudo ./aws/install \
#   && rm -rf ./aws awscliv2.zip
# # STOP  ::: install aws cli

# START ::: install gcloud cli
RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
RUN sudo apt-get update && sudo apt-get install -y google-cloud-cli
# STOP ::: install gcloud cli

# START ::: install gh cli
# csi-spl: tf step 120-github-general-secrets publishes the project SA key with
# a local-exec `gh secret set` (GITHUB_TOKEN comes in via the compose env).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list \
  && sudo apt-get update && sudo apt-get install -y gh
# STOP  ::: install gh cli

# START ::: install terraform and tfswitch
# install tfswitch to handle multiple terraform versions
# RUN set -eux; \
#   curl -L https://raw.githubusercontent.com/warrensbox/terraform-switcher/release/install.sh | bash

# RUN curl -L https://raw.githubusercontent.com/warrensbox/terraform-switcher/release/install.sh -o /opt/install.sh
# RUN chmod 777 /opt/install.sh
# RUN /opt/install.sh | bash
# RUN rm -v /opt/install.sh

# Download and install terraform-switcher
RUN curl -L "https://github.com/warrensbox/terraform-switcher/releases/download/$TF_SWITCH_VERSION/terraform-switcher_${TF_SWITCH_VERSION}_linux_amd64.tar.gz" -o tfswitch.tar.gz \
    && tar -xzf tfswitch.tar.gz -C /usr/local/bin \
    && rm tfswitch.tar.gz

# Verify the installation
RUN tfswitch --version

# RUN curl -L https://raw.githubusercontent.com/warrensbox/terraform-switcher/0.13.1308/install.sh | bash
# STOP  ::: install terraform and tfswitch

# START ::: install Node.js 20 + firebase-tools (for csi-spl-orc deploy actions)
# Used by `do_deploy_static_site` in csi-spl-orc — runs `firebase deploy` against
# the env's Firebase Hosting site. Container runs in GitHub Actions for CI deploys.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*
RUN npm install -g firebase-tools@latest \
  && firebase --version
# STOP  ::: install Node.js 20 + firebase-tools


# START ::: Enable host to container edit of proj code on ubuntu and mac.
RUN test -z $(getent group $GID | cut -d: -f1) || \
  groupmod -g $((GID+1000)) $(getent group $GID | cut -d: -f1)

# isntall python pip
RUN wget https://bootstrap.pypa.io/get-pip.py ; sudo python3 get-pip.py ; sudo rm -v get-pip.py

RUN pip3 install --upgrade pip wheel



# START ::: add-os-user

# START ::: Enable host to container edit of proj code on ubuntu and mac.
RUN test -z $(getent group $GID | cut -d: -f1) || \
  groupmod -g $((GID+1000)) $(getent group $GID | cut -d: -f1)
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
RUN mkdir -p "/home/$APPUSR" && chown "$APPUSR":"$APPGRP" "/home/$APPUSR"


RUN echo "$APPUSR ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
RUN echo "export PS1=\"$PS1\"" >> $DOCKER_HOME/.bashrc && \
  echo "export EDITOR=\"$EDITOR\"" >> $DOCKER_HOME/.bashrc && \
  echo "cd ${IAC_PROJ_PATH}" >> $DOCKER_HOME/.bashrc && \
  echo "export PATH=$DOCKER_HOME/bin:\$PATH" >>$DOCKER_HOME/.bashrc && \
  chown -R $APPUSR:$APPGRP $DOCKER_HOME && \
  chmod -R 0775 $DOCKER_HOME

# set the default shell as bash and not sh
SHELL ["/bin/bash", "-c"]

USER $APPUSR

# STOP  ::: add-os-user

# START  ::: install-poetry
ENV POETRY_VERSION=2.3.2
RUN pip install --no-cache-dir poetry==$POETRY_VERSION
RUN echo 'export PATH=$PATH:$HOME/.local/bin/' >> $HOME/.bashrc
ENV PATH="${PATH}:/home/${APPUSR}/.local/bin/"
# STOP  ::: install-poetry

#install anbible plugin
RUN ansible-galaxy collection install cloud.terraform


# Derive ORG and APP from ORG_APP at runtime
RUN echo "export ORG_APP=$ORG_APP" >> $DOCKER_HOME/.bashrc && \
    echo 'export ORG=${ORG_APP%%-*}' >> $DOCKER_HOME/.bashrc && \
    echo 'export APP=${ORG_APP##*-}' >> $DOCKER_HOME/.bashrc

# Project files are mounted via docker-compose volume — no COPY needed
# Poetry modules are installed at runtime by the init script
WORKDIR $PROJ_PATH
ENV PATH=/home/$APPUSR/bin:$PATH
