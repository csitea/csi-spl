# step 036 (077 iac audit): the tf-runner mounts ~/.spool-hub, where a new
# demo workspace's root key is saved (0600). Made here, 0700, before compose
# starts: a missing bind source is created by docker as root. An existing dir
# keeps its mode (mkdir -p does not chmod it).
.PHONY: do-spool-hub-dir
do-spool-hub-dir:
	@mkdir -p -m 700 $(HOME)/.spool-hub
	@mkdir -p -m 700 $(HOME)/.spool-hub/tenants

.PHONY: do-echo-attach-exec
do-echo-attach-exec:
	@echo "To attach to containers:"
	@docker ps --format '{{.Names}}' | xargs -I {} echo "docker exec -it {} /bin/bash"

.PHONY: do-setup-app-inf  ## @-> 01.02 setup the whole csi-spl dockerized setup
do-setup-app-inf: do-create-network demand_var-GITHUB_TOKEN do-spool-hub-dir
	@bash -c '\
	  source lib/bash/funcs/define-all-run-vars.func.sh; \
	  do_define_all_run_vars; \
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; \
	  echo "ORG: $$ORG"; \
		sleep 10; \
	  do_resolve_oap APP; \
	  echo "APP: $$APP"; \
	  do_resolve_oap PROJ; \
	  echo "PROJ: $$PROJ"; \
	  echo export DOCKER_BUILDKIT=1; \
	  ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} down --rmi all && \
	  ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} --verbose build && \
	  ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} --verbose up -d \
	'
	./run -a do_check_container_dns
	@$(MAKE) do-echo-attach-exec


# just echo what this ^^^ task does 
.PHONY: do-echo-setup-app-inf
do-echo-setup-app-inf: demand_var-GITHUB_TOKEN
	@bash -c '\
	  source lib/bash/funcs/define-all-run-vars.func.sh; \
	  do_define_all_run_vars; \
	  source lib/bash/funcs/resolve-oap.func.sh; \
	  do_resolve_oap ORG; \
	  echo "ORG: $$ORG"; \
	  do_resolve_oap APP; \
	  echo "APP: $$APP"; \
	  do_resolve_oap PROJ; \
	  echo "PROJ: $$PROJ"; \
	  echo export DOCKER_BUILDKIT=1; \
	  echo ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} down --rmi all && \
	  echo ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} --verbose build && \
	  echo ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} --verbose up -d; \
	'
	@$(MAKE) do-echo-attach-exec


.PHONY: do-setup-app-inf-no-cache  ## @-> 01.03 setup the whole csi-spl dockerized setup
do-setup-app-inf-no-cache: do-create-network demand_var-GITHUB_TOKEN do-spool-hub-dir
	@export DOCKER_BUILDKIT=1; ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} down --rmi all \
	&& ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} --verbose build --no-cache \
	&& ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} --verbose up -d
	./run -a do_check_container_dns
	@$(MAKE) do-echo-attach-exec

.PHONY: do-setup-app-inf-up  ## @-> 01.02 setup the whole csi-spl dockerized setup
do-setup-app-inf-up: demand_var-GITHUB_TOKEN do-spool-hub-dir
	@export DOCKER_BUILDKIT=1; ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} down --rmi all \
	&& ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} --verbose up -d
	./run -a do_check_container_dns
	@$(MAKE) do-echo-attach-exec
