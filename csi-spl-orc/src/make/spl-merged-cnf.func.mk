# csi-spl ::: config, no csi-rel counterpart. csi-spl splits its config into
# all.env.yaml (shared) + <env>.env.yaml and derives env.dns.fqdn; tpl-gen and
# the conf-validator read ONE file, so this writes the effective config of
# ENV to $(SPL_MERGED_CNF) (git-ignored) with the same do_spl_merged_cnf the
# native `ENV=<env> ./run -a do_tpl_gen` uses, and refreshes the committed
# <env>.env.json from it with do_tpl_gen's own _tpl_gen_write_json: written
# only when a value changed, refused without jq (SPL-5242). Runs on the host
# (yq, jq). do_log is the run framework's; here a plain stderr line.
SPL_MERGED_CNF = $(APP_PATH)/$(APP)-cnf/$(APP)/.merged/$(ENV).env.yaml

.PHONY: do-spl-merged-cnf ## @-> 02.00 write the effective config of ENV (all.env.yaml + <env>.env.yaml)
do-spl-merged-cnf: demand_var-ENV demand_var-APP
	@mkdir -p $(dir $(SPL_MERGED_CNF)) && \
	bash -c 'set -e; iac=$(APP_PATH)/$(APP)-iac; do_log() { echo "$$*" >&2; }; \
	  source $$iac/lib/bash/funcs/spl-merged-cnf.func.sh; \
	  source $$iac/lib/bash/funcs/require-bin.func.sh; \
	  source $$iac/src/bash/run/tpl-gen.func.sh; \
	  do_spl_merged_cnf $(APP_PATH)/$(APP)-cnf/$(APP) $(ENV) $(SPL_MERGED_CNF); \
	  _tpl_gen_write_json $(SPL_MERGED_CNF) $(APP_PATH)/$(APP)-cnf/$(APP)/$(ENV).env.json' && \
	echo "effective config: $(SPL_MERGED_CNF)"
