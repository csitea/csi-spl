.PHONY: do-setup-tpl-gen  ## @-> 01.06 build and start tpl-gen + conf-validator for template generation
do-setup-tpl-gen: do-create-network demand_var-GITHUB_TOKEN
	@export DOCKER_BUILDKIT=1 && \
	${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} build tpl-gen conf-validator && \
	${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} up -d tpl-gen conf-validator && \
	echo "Containers started, waiting for tpl-gen init (poetry install)..." && \
	ok=0 && for i in $$(seq 1 90); do \
	  docker exec con-$(ORG)-$(APP)-tpl-gen test -f $(TPG_PROJ_PATH)/src/python/tpl-gen/.venv/bin/activate 2>/dev/null && ok=1 && break; \
	  sleep 2; \
	done && [ "$$ok" = "1" ] && echo "tpl-gen ready" && \
	ok=0 && for i in $$(seq 1 90); do \
	  docker exec con-$(ORG)-$(APP)-conf-validator test -f $(CNF_PROJ_PATH)/src/python/conf-validator/.venv/bin/activate 2>/dev/null && ok=1 && break; \
	  sleep 2; \
	done && [ "$$ok" = "1" ] && echo "conf-validator ready" && \
	echo "tpl-gen and conf-validator containers ready" || \
	{ echo "ERROR: tpl-gen/conf-validator setup failed"; exit 1; }

.PHONY: do-setup-tf-runner  ## @-> 01.07 build and start the tf-runner container (uses docker-compose-infra.yaml)
do-setup-tf-runner: do-create-network demand_var-GITHUB_TOKEN
	@export DOCKER_BUILDKIT=1 && \
	${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} build tf-runner && \
	${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE_WUI_INF} up -d tf-runner && \
	echo "tf-runner container started, waiting for it to be ready..." && \
	: "readiness = tfswitch present; terraform itself is installed later by" && \
	: "do_tf_init via 'tfswitch \$$TERRAFORM_VERSION', so probing for" && \
	: "/usr/local/bin/terraform here always failed on a healthy container" && \
	ok=0 && for i in $$(seq 1 90); do \
	  docker exec con-$(ORG)-$(APP)-tf-runner test -x /usr/local/bin/tfswitch 2>/dev/null && ok=1 && break; \
	  sleep 2; \
	done && [ "$$ok" = "1" ] && echo "tf-runner ready" || \
	{ echo "ERROR: tf-runner setup failed"; exit 1; }
