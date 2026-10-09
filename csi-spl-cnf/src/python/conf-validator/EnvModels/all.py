# csi-spl ::: all.env.yaml, the settings shared by every env (deep-merged
# UNDER <env>.env.yaml by do_spl_merged_cnf). It holds THE domain and the hub
# env-var names; everything env-specific is in <env>.env.yaml.
from typing import Any, Literal
from pydantic import BaseModel, root_validator
from pydantic_yaml import YamlModel

from .agent_split import Box


class Cloud(BaseModel):
    """spec 076: the cloud provider the env runs on; gcp unless the cnf says otherwise."""
    provider: Literal["gcp", "none", "aws"] = "gcp"


class Dns(BaseModel):
    BASE_DOMAIN: str


class I18n(BaseModel):
    """spec 021: the WUI + hub-mail locale set and the unprefixed default."""
    default_locale: str
    locales: list

    @root_validator(skip_on_failure=True)
    def default_is_shipped(cls, values):
        if values["default_locale"] not in values["locales"]:
            raise ValueError(f'i18n.default_locale {values["default_locale"]} is not in i18n.locales')
        return values


class Env(YamlModel):
    dns: Dns
    cloud: Cloud = Cloud()
    hub: Any
    auth: Any
    i18n: I18n
    mail: Any
    box: Box


class CnfModel(YamlModel):
    env: Env
