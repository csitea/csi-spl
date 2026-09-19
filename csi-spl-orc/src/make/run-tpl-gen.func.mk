# usage: include it in your Makefile by:
# include src/make/tpl-gen.mk

.PHONY: tpl-gen ## @-> 02.03 apply the environment cnf file into the templates
tpl-gen:
	cd ${TPG_PROJ_PATH}/src/python/tpl-gen && source .venv/bin/activate && poetry run python3 tpl_gen/tpl_gen.py

.PHONY: convert-yaml-to-json ## @-> 02.04 convert all the yaml files into json files
convert-yaml-to-json:
	cd ${TPG_PROJ_PATH}/src/python/tpl-gen && source .venv/bin/activate && poetry run python3 tpl_gen/convert_yaml_to_json.py


.PHONY: do-convert-yaml-to-json ## @-> 02.05 docker based convert all the yaml files into json files
do-convert-yaml-to-json:
	docker exec -e ORG=$(ORG) -e CNF_SRC=$(CNF_SRC) -e TPL_SRC=$(TPL_SRC) -e TGT=$(TGT) -e DATA_PATH=$(DATA_KEY_PATH) $(ORG)-${PROJ}-tpl-gen-con make convert-yaml-to-json


# eof file: src/make/tpl-gen.mk
