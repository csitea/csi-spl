.PHONY: define-all-run-vars
define-all-run-vars:
	@bash -c '\
	  source lib/bash/funcs/define-all-run-vars.func.sh; \
	  do_define_all_run_vars; \
	  echo "HOST_NAME is set to: $$HOST_NAME"; \
	  echo "EXIT_CODE is set to: $$EXIT_CODE"; \
	  echo "RUN_UNIT is set to: $$RUN_UNIT"; \
	  echo "PROJ_PATH is set to: $$PROJ_PATH"; \
	  echo "APP_PATH is set to: $$APP_PATH"; \
	  echo "APP_NAME is set to: $$APP_NAME"; \
	  echo "ORG_PATH is set to: $$ORG_PATH"; \
	  echo "BASE_PATH is set to: $$BASE_PATH"; \
	  echo "PROJ is set to: $$PROJ"; \
	  echo "ENV is set to: $$ENV"; \
	  echo "GROUP is set to: $$GROUP"; \
	  echo "USER is set to: $$USER"; \
	  echo "UID is set to: $$UID"; \
	  echo "GID is set to: $$GID"; \
	  echo "OS is set to: $$OS"; \
	  echo "LOG_DIR is set to: $$LOG_DIR"; \
	  echo "LOG_FILE is set to: $$LOG_FILE"; \
	'
