# Makefile

resolve-oap-org:
	@bash -c ' \
		source lib/bash/funcs/resolve-oap.func.sh; \
		do_resolve_oap ORG; \
		echo "ORG: $$ORG"; \
	'

resolve-oap-app:
	@bash -c ' \
		source lib/bash/funcs/resolve-oap.func.sh; \
		do_resolve_oap APP; \
		echo "APP: $$APP"; \
	'

resolve-oap-proj:
	@bash -c ' \
		source lib/bash/funcs/resolve-oap.func.sh; \
		do_resolve_oap PROJ; \
		echo "PROJ: $$PROJ"; \
	'

resolve-oap: resolve-oap-org resolve-oap-app resolve-oap-proj
