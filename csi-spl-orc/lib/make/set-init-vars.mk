# csi-spl ::: from csi-rel-orc lib/make/set-init-vars.mk, config only.
#
# APP_PATH / ORG_DIR: lib/make/app-path.mk (it must sort before derive-proj-paths.mk).

# ORG and APP from ORG_APP (src/docker/tf-infra.env). csi-rel splits csi-rel
# into ORG=csi APP=rel here, but every consumer on the make side (derive-
# proj-paths.mk: $(APP)-orc, the compose dockerfile path ./${APP}-orc, the
# con-<org>-<app> container names do_resolve_oap yields in tf-tasks) needs the
# <ORG>-<APP> dir name, so csi-spl sets APP to it. tf-tasks still hands the
# iac run the short form (-e APP=$${APP#*-} -> spl).
ORG := $(firstword $(subst -, ,$(ORG_APP)))
APP := $(ORG_APP)

# Container + compose names. csi-rel's slot scheme (resolve-slot.func.sh) is
# not ported: there is ONE csi-spl tf infra stack per box, con-csi-csi-spl-*,
# mounting the tree that last ran do-setup-app-inf. A named compose project
# keeps `down --rmi all` from reaching another app's containers (the default
# project name is the compose dir, "docker", for every app on the box).
CON_PREFIX         := con-$(ORG)-$(APP)
export CON_PREFIX
COMPOSE_PROJECT_NAME := $(CON_PREFIX)-tf-infra
export COMPOSE_PROJECT_NAME

CON_TF_RUNNER      := $(CON_PREFIX)-tf-runner
CON_TPL_GEN        := $(CON_PREFIX)-tpl-gen
CON_CONF_VALIDATOR := $(CON_PREFIX)-conf-validator
