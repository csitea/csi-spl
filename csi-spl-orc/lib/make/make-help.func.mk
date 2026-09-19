# usage: include it in your Makefile
# include lib/make/make-help.task

.DEFAULT_GOAL := usage

# ---- make run <action-name> dispatcher ----
# Enables: make run hello-world  =>  ./run -a do_hello_world
# Enables: make run gcp-list-secrets  =>  ./run -a do_gcp_list_secrets
# Passes through env vars: ENV=dev make run gcp-list-secrets
ifeq (run,$(firstword $(MAKECMDGOALS)))
  RUN_ACTION := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  $(eval $(RUN_ACTION):;@:)
endif

.PHONY: run  ## @-> run a shell action (usage: make run <action-name>)
run:
ifdef RUN_ACTION
	@./run -a do_$(subst -,_,$(RUN_ACTION))
else
	@echo "Usage: make run <action-name>"
	@echo "Example: make run hello-world  =>  ./run -a do_hello_world"
	@echo ""
	@echo "Run 'make print-help' to see all available actions."
endif

.PHONY: print-help  ## @-> show all make targets and shell actions
print-help:
	@echo ""
	@echo "================================================================================"
	@echo "  MAKE TARGETS"
	@echo "================================================================================"
	@fgrep -h "##" $(MAKEFILE_LIST)|fgrep -v fgrep|sed -e 's/^\.PHONY: //'|sed -e 's/^\(.*\)##/\1/'| \
      column -t -s $$'@'
	@echo ""
	@echo "================================================================================"
	@echo "  SHELL ACTIONS (usage: make run <action-name>)"
	@echo "================================================================================"
	@find src/bash/run/ lib/bash/funcs -name '*.func.sh' 2>/dev/null | \
      perl -ne 's|(.*)/(.*)\.func\.sh|$$2|g; print' | \
      sort -u | \
      while read -r action; do \
        printf "  make run %-45s ./run -a do_%s\n" "$$action" "$$(echo $$action | tr '-' '_')"; \
      done
	@echo ""
	@echo "Search actions by keyword: make help-with SRCH=<keyword>"
	@echo "================================================================================"

.PHONY: help  ## @-> show this help  the default action-
help:
	@clear
	@fgrep -h "##" $(MAKEFILE_LIST)|fgrep -v fgrep|sed -e 's/^\.PHONY: //'|sed -e 's/^\(.*\)##/\1/'| \
      column -t -s $$'@'

.PHONY: usage  ## @-> show the usage from the README.md , add it to histor
usage:
	@clear
	@./run -a do_help_to_history



.PHONY: help-with  ## @-> search shell actions by keyword (usage: make help-with SRCH=keyword)
help-with: demand_var-SRCH
	@SRCH=$(SRCH) ./run -a do_help_with

.PHONY: tf-help  ## @-> show this help  the default action
tf-help:
	# @clear
	while read -r step ; do echo 'clear;export STEP='$$step'; ORG=spe APP=prp ENV=env make do-provision-$$STEP | tee -a 2>&1 ~/Desktop/$$ORG.$$APP.$$ENV.$$STEP.log' ; done < <(ls -1 src/terraform/ | grep -v bucket)| column -t
