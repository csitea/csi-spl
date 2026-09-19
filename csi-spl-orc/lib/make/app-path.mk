# csi-spl ::: config, in place of csi-rel's APP_PATH / ORG_DIR lines in its
# committed src/docker/.env.
# APP_PATH is the tree this Makefile lives in, so the main checkout and an
# agent worktree (<base>/csi/csi-spl-wt/<ID>) each build and mount THEMSELVES.
# The file name sorts before derive-proj-paths.mk on purpose: GNU make exports
# every variable into each $(shell) it runs, so BASE_PATH ?= $(shell dirname
# $(APP_PATH)...) is expanded as soon as set-default-shell.mk calls uname, and
# APP_PATH has to exist by then.
APP_PATH := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../../..)
ORG_DIR  := $(abspath $(APP_PATH)/..)
export APP_PATH ORG_DIR
