# Makefile
# usage: run the "make" command in the root, than make <<cmd>>...
include $(wildcard src/docker/tf-infra.env)
export
include $(wildcard lib/make/*.mk)
include $(wildcard src/make/*.func.mk)


# set ALL of your global variables here, setting vars in functions outsite the funcs does not work
export UID := $(shell id -u)
export GID := $(shell id -g)
BUILD_NUMBER := $(if $(BUILD_NUMBER),$(BUILD_NUMBER),"0")
COMMIT_SHA := $(if $(COMMIT_SHA),$(COMMIT_SHA),$$(git rev-parse --short HEAD))
COMMIT_MESSAGE := $(if $(COMMIT_MESSAGE),$(COMMIT_MESSAGE),$$(git log -1  --pretty='%s'))
DOCKER_BUILDKIT := $(or 1,$(shell echo $$DOCKER_BUILDKIT))

SHELL = bash
PROJ := $(shell basename $$PWD)
PROJ := $(shell echo `basename $$PWD`|tr '[:upper:]' '[:lower:]')
product := $(shell echo `basename $$PWD`|tr '[:upper:]' '[:lower:]')
PROCESSOR_ARCHITECTURE := $(shell uname -m)

# Map architecture to Dockerfile suffix
# x86_64 -> x86_64, arm64/aarch64 -> arm-mac
ifeq ($(PROCESSOR_ARCHITECTURE),arm64)
    DOCKER_ARCH_SUFFIX := arm-mac
else ifeq ($(PROCESSOR_ARCHITECTURE),aarch64)
    DOCKER_ARCH_SUFFIX := arm-mac
else
    DOCKER_ARCH_SUFFIX := x86_64
endif

export DOCKER_ARCH_SUFFIX

DOCKER_COMPOSE_FILE_WUI_INF := "src/docker/docker-compose-tf-infra.yaml"
DOCKER_COMPOSE_FILE_APP := "src/docker/docker-compose-app.yaml"
DOCKER_COMPOSE_FILE_API := "src/docker/docker-compose-api.yaml"
DOCKER_COMPOSE_FILE_WUI := "src/docker/docker-compose-wui.yaml"

DOCKER_NETWORK_NAME := all_lcl_docker

# Docker compose command - use "docker compose" on Mac, "docker-compose" on Linux
# (csi-rel defines it in src/make/setup-app.func.mk, which csi-spl does not port)
DOCKER_COMPOSE_CMD ?= $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")

# csi-rel: usage (./run -a do_help_to_history, which csi-spl-orc does not have)
.DEFAULT_GOAL := print-help

.PHONY: do-create-network  ## @-> 00.01 create the shared Docker network if it does not exist
do-create-network:
	@docker network inspect $(DOCKER_NETWORK_NAME) >/dev/null 2>&1 || \
		(echo "Creating shared Docker network: $(DOCKER_NETWORK_NAME)" && \
		docker network create --driver bridge $(DOCKER_NETWORK_NAME))

# eof file: csi-spl-orc/Makefile
