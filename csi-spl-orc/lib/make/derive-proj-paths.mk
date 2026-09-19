# Derive project paths from base vars (ORG, APP, APP_PATH, DOCKER_HOME from .env)
# Uses ?= so .env values take precedence if still present (backward-compatible)

# Core paths
BASE_PATH ?= $(shell dirname $(shell dirname $(APP_PATH)))
BASE_DIR  ?= $(BASE_PATH)
PROJ_PATH ?= $(APP_PATH)/$(APP)-utl

# Standard project paths: ${APP_PATH}/${ORG}-${APP}-${type}
UTL_PROJ_PATH ?= $(APP_PATH)/$(APP)-utl
ORC_PROJ_PATH ?= $(APP_PATH)/$(APP)-orc
IAC_PROJ_PATH ?= $(APP_PATH)/$(APP)-iac
API_PROJ_PATH ?= $(APP_PATH)/$(APP)-api
WUI_PROJ_PATH ?= $(APP_PATH)/$(APP)-wui
CNF_PROJ_PATH ?= $(APP_PATH)/$(APP)-cnf

# Special cases (don't follow naming convention)
TPG_PROJ_PATH ?= $(APP_PATH)/tpl-gen
# Bot e2e scripts live in the WUI package (pnpm test:payment / test:e2e).
BOT_PROJ_PATH ?= $(WUI_PROJ_PATH)

# HOME_* paths (container-relative): ${DOCKER_HOME}${*_PROJ_PATH}
HOME_UTL_PROJ_PATH ?= $(DOCKER_HOME)$(UTL_PROJ_PATH)
HOME_ORC_PROJ_PATH ?= $(DOCKER_HOME)$(ORC_PROJ_PATH)
HOME_IAC_PROJ_PATH ?= $(DOCKER_HOME)$(IAC_PROJ_PATH)
HOME_API_PROJ_PATH ?= $(DOCKER_HOME)$(API_PROJ_PATH)
HOME_WUI_PROJ_PATH ?= $(DOCKER_HOME)$(WUI_PROJ_PATH)
HOME_CNF_PROJ_PATH ?= $(DOCKER_HOME)$(CNF_PROJ_PATH)

HOME_TPG_PROJ_PATH ?= $(DOCKER_HOME)$(TPG_PROJ_PATH)
HOME_TPL_PROJ_PATH ?= $(DOCKER_HOME)$(TPG_PROJ_PATH)
HOME_BOT_PROJ_PATH ?= $(DOCKER_HOME)$(BOT_PROJ_PATH)
