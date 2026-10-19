.PHONY: tf-new-step ## @-> 03.00 generates framework for terraform new step
tf-new-step: demand_var-STEP
	./run -a do_tf_new_step

.PHONY: tf-remove-step ## @-> 03.00 removes framework for terraform step
tf-remove-step: demand_var-STEP
	./run -a do_tf_remove_step

.PHONY: no-plan-ref
no-plan-ref:
	@if [ -n "$(strip $(PLAN_REF))" ]; then echo "REFUSED: PLAN_REF=$(PLAN_REF) is plan-only (SPL-2602); only make do-tf-plan takes it. Unset PLAN_REF to run this target from this tree."; exit 1; fi

.PHONY: do-tf-plan ## @-> 03.01 saves a terraform plan; PLAN_REF=<branch|sha> plans that ref instead (plan only)
ifneq ($(strip $(PLAN_REF)),)
do-tf-plan: demand_var-ENV demand_var-STEP
	@env ENV='$(ENV)' STEP='$(STEP)' PLAN_REF='$(PLAN_REF)' ./run -a do_tf_plan_ref
else
do-tf-plan: demand_var-ENV demand_var-STEP
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  # 061 only, and only when set: an empty string is not a list, and other steps stay unchanged. \
	  wine_tf=(); \
	  case "$(STEP)" in \
	    061-gcp-vm-wine-box) \
	      [ -n "$${TF_VAR_iap_members:-}" ] && wine_tf+=(-e TF_VAR_iap_members); \
	      [ -n "$${TF_VAR_desktop_user_ssh_public_keys:-}" ] && wine_tf+=(-e TF_VAR_desktop_user_ssh_public_keys); \
	      ;; \
	  esac; \
	  docker exec \
		"$${wine_tf[@]}" \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		-e ACTION=provision \
		-e TF_VAR_billing_account_id="$${GCP_BILLING_ACCOUNT_ID:-}" \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_plan \
	'
endif

.PHONY: do-tf-plan-pending ## @-> 03.01b read-only: does ENV have pending changes for STEP (exit 0 clean, 2 pending, 1 error)
do-tf-plan-pending: demand_var-ENV demand_var-STEP
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$(ENV) \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		-e ACTION=provision \
		-e TF_VAR_billing_account_id="$${GCP_BILLING_ACCOUNT_ID:-}" \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_plan_pending \
	'

.PHONY: do-import ## @-> 03.02 import terraform resource
do-import: no-plan-ref demand_var-AWS_PROFILE demand_var-ENV demand_var-TF_PROJ demand_var-RESOURCE_ADDRESS demand_var-RESOURCE_IDENTIFIER demand_var-STEP
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e AWS_PROFILE=$(AWS_PROFILE) \
		-e RESOURCE_ADDRESS=$(RESOURCE_ADDRESS) \
		-e RESOURCE_IDENTIFIER=$(RESOURCE_IDENTIFIER) \
		-e TF_PROJ=$(TF_PROJ) \
		-e STEP=$(STEP) \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_import \
	'

.PHONY: do-provision ## @-> 03.03 provision a step
do-provision: no-plan-ref demand_var-ENV demand_var-STEP
	./run -a do_check_container_dns
	@case "$(STEP)" in 030-cloud-run-hub) \
	  ENV=$(ENV) ./run -a do_check_hub_image_regress \
	    || { echo "REFUSED: 030 apply from this tree would move the live hub image backwards (see the verdict above). Refresh the checkout the tf-runner mounts, or set ALLOW_IMAGE_REGRESS=1 for a deliberate rollback."; exit 1; } ;; \
	036-spl-demo-workspace) \
	  bash ../csi-spl-api/src/bash/build.sh ../csi-spl-api/src/go/spool-hub-api/bin/spool \
	    || { echo "REFUSED: 036 needs the spool CLI its create path signs with (step 036, 03-demo-workspace.tf); the host build failed."; exit 1; } ;; \
	esac
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  # 061 only, and only when set: an empty string is not a list, and other steps stay unchanged. \
	  wine_tf=(); \
	  case "$(STEP)" in \
	    061-gcp-vm-wine-box) \
	      [ -n "$${TF_VAR_iap_members:-}" ] && wine_tf+=(-e TF_VAR_iap_members); \
	      [ -n "$${TF_VAR_desktop_user_ssh_public_keys:-}" ] && wine_tf+=(-e TF_VAR_desktop_user_ssh_public_keys); \
	      ;; \
	  esac; \
	  docker exec \
		"$${wine_tf[@]}" \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		-e ACTION=provision \
		-e ENV_ORDER_OVERRIDE="$${ENV_ORDER_OVERRIDE:-}" \
		-e TF_VAR_billing_account_id="$${GCP_BILLING_ACCOUNT_ID:-}" \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_provision \
	'

.PHONY: do-provision-and-update-gh-keys ## @-> 03.03b provision step 120 + update GH GCP keys via gh CLI
do-provision-and-update-gh-keys: no-plan-ref demand_var-ENV
	@$(MAKE) do-provision ENV=$(ENV) STEP=120-github-general-secrets
	@ENV=$(ENV) ./run -a do_github_update_gcp_keys

.PHONY: do-tf-apply-target ## @-> 03.04 provision target resource only
do-tf-apply-target: no-plan-ref demand_var-ENV demand_var-STEP demand_var-TARGET
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e TARGET="$(TARGET)" \
		-e STEP=$(STEP) \
		-e ENV_ORDER_OVERRIDE="$${ENV_ORDER_OVERRIDE:-}" \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_apply_target \
	'

.PHONY: do-deprovision ## @-> 03.05 divest a step only
do-deprovision: no-plan-ref demand_var-ENV demand_var-STEP
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		-e GIT_REF=$(GIT_REF) \
		-e TF_VAR_billing_account_id="$${GCP_BILLING_ACCOUNT_ID:-}" \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_divest \
	'

.PHONY: do-tf-plan-destroy ## @-> 03.06 show what a full-step destroy would remove (changes nothing)
do-tf-plan-destroy: demand_var-ENV demand_var-STEP
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		-e ACTION=provision \
		-e TF_VAR_billing_account_id="$${GCP_BILLING_ACCOUNT_ID:-}" \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_plan_destroy \
	'

.PHONY: do-provision-local ## @-> 03.07 provision a step locally
do-provision-local: no-plan-ref demand_var-ENV demand_var-STEP
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_provision_local \
	'

.PHONY: do-deprovision-local ## @-> 03.08 divest a step locally
do-deprovision-local: no-plan-ref demand_var-ENV demand_var-STEP
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_divest_local \
	'

.PHONY: do-tf-destroy-target ## @-> 03.09 divest target resource only (dry run unless DRY_RUN=0)
do-tf-destroy-target: no-plan-ref demand_var-ENV demand_var-STEP demand_var-TARGET
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e TARGET="$(TARGET)" \
		-e STEP=$(STEP) \
		-e DRY_RUN="$(DRY_RUN)" \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_destroy_target \
	'

.PHONY: do-tf-import ## @-> 03.10 import target resource to state
do-tf-import: no-plan-ref demand_var-ENV demand_var-STEP demand_var-TARGET demand_var-ID
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		-e TARGET="$(TARGET)" \
		-e ID="$(ID)" \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_import \
	'

.PHONY: do-tf-replace-target ## @-> 03.11 reprovision (destroy/recreates) terraform resource
do-tf-replace-target: no-plan-ref demand_var-ENV demand_var-STEP demand_var-TARGET
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e TARGET="$(TARGET)" \
		-e STEP=$(STEP) \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_replace_target \
	'

.PHONY: do-tf-taint-target ## @-> 03.12 taint terraform resource
do-tf-taint-target: no-plan-ref demand_var-ENV demand_var-STEP demand_var-TARGET
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e TARGET="$(TARGET)" \
		-e STEP=$(STEP) \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_taint_target \
	'

.PHONY: do-tf-untaint-target ## @-> 03.13 untaint terraform resource
do-tf-untaint-target: no-plan-ref demand_var-ENV demand_var-STEP demand_var-TARGET
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$(ENV) \
		-e APP=$${APP#*-} \
		-e TARGET="$(TARGET)" \
		-e STEP=$(STEP) \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_untaint_target \
	'

.PHONY: do-tf-state-list ## @-> 03.14 list the objects in the terraform state
do-tf-state-list: demand_var-ENV demand_var-STEP
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_state_list \
	'

.PHONY: do-tf-state-pull ## @-> 03.15 pull remote state from s3
do-tf-state-pull: demand_var-ENV demand_var-STEP
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_state_pull \
	'

.PHONY: do-tf-state-push ## @-> 03.16 push state to s3
do-tf-state-push: no-plan-ref demand_var-ENV demand_var-STEP demand_var-TFSTATE_FILE
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		-e TFSTATE_FILE=$(TFSTATE_FILE) \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_state_push \
	'

.PHONY: do-tf-state-remove ## @-> 03.17 remove target resource from state (state backup first; dry run unless DRY_RUN=0; FORCE=1 skips the lock)
do-tf-state-remove: no-plan-ref demand_var-ENV demand_var-STEP demand_var-TARGET
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		-e TARGET="$(TARGET)" \
		-e DRY_RUN="$(DRY_RUN)" \
		-e FORCE="$(FORCE)" \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_state_remove \
	'

.PHONY: do-tf-state-show ## @-> 03.18 show target resource state
do-tf-state-show: demand_var-ENV demand_var-STEP demand_var-TARGET
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e STEP=$(STEP) \
		-e TARGET="$(TARGET)" \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_tf_state_show \
	'

.PHONY: do-gcp-sync-secrets ## @-> 03.20 sync secrets from Google Sheet to GCP Secret Manager
do-gcp-sync-secrets: demand_var-ENV
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		-e DRY_RUN=$${DRY_RUN:-0} \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_gcp_sync_secrets \
	'

.PHONY: do-gcp-update-secrets ## @-> 03.21 read secrets from Google Sheet (display only)
do-gcp-update-secrets: demand_var-ENV
	@bash -c '\
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; do_resolve_oap APP; \
	  export ENV=$(ENV); \
	  docker exec \
		-e ORG=$$ORG \
		-e ENV=$$ENV \
		-e APP=$${APP#*-} \
		con-$$ORG-$$APP-tf-runner \
		./run -a do_gcp_update_secrets \
	'

.PHONY: do-tf-030-import-existing-cloud-run ## @-> 03.22 import live Cloud Run into 030 state (import only)
do-tf-030-import-existing-cloud-run: demand_var-ENV
	ENV=$(ENV) ./run -a do_tf_030_import_existing_cloud_run

