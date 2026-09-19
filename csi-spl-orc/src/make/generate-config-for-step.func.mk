# csi-spl ::: csi-rel-orc src/make/generate-config-for-step.func.mk. The recipe
# is csi-rel's; the config differences, all of them:
#   - the conf-validator and tpl-gen read $(SPL_MERGED_CNF), the EFFECTIVE
#     config (all.env.yaml deep-merged under <env>.env.yaml + env.dns.fqdn),
#     written first by do-spl-merged-cnf (src/make/spl-merged-cnf.func.mk).
#     csi-rel has no all.env.yaml; its raw <env>.env.yaml IS its config.
#   - TPL_SRC's %app% dir is the symlink csi-spl-iac/src/tpl/%app% ->
#     %org%-%app%: here APP=csi-spl (lib/make/set-init-vars.mk), the native
#     do_tpl_gen runs with ORG=csi APP=spl.
#   - do-generate-docs-for-step is not ported: csi-spl has no doc/md templates.
.PHONY: do-generate-config-for-step ## @-> 02.01 generate the conf for the steps
do-generate-config-for-step: demand_var-ENV  demand_var-ORG demand_var-APP demand_var-STEP do-spl-merged-cnf
	docker exec con-$(ORG)-$(APP)-conf-validator /bin/bash -c 'set -e; cd $(APP_PATH)/$(APP)-cnf/src/python/conf-validator && poetry run validate $(SPL_MERGED_CNF) $(ENV)' || { echo "conf-validator refused (rc 1 = the config is invalid, rc 2 = it could not be checked at all: unknown ENV, or the yaml is not where APP_PATH says). Stopping."; exit 1; }
	docker exec -e ORG=$(ORG) -e APP=$(APP) -e ENV=$(ENV) -e STEP=$(STEP) -e DATA_KEY_PATH='.env.steps["$(STEP)"]' -e TPL_SRC=$(APP_PATH)/$(APP)-iac/src/tpl/%app%/%env%/tf/$(STEP)*.tpl -e CNF_SRC=$(SPL_MERGED_CNF) -e TGT=$(APP_PATH)/$(APP)-cnf con-$(ORG)-$(APP)-tpl-gen /bin/bash -c 'cd $(ORC_PROJ_PATH) && make tpl-gen'
