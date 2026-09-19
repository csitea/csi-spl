# csi-spl ::: all.env.yaml, the settings shared by every env (deep-merged
# UNDER <env>.env.yaml by do_spl_merged_cnf). It holds THE domain and the hub
# env-var names; everything env-specific is in <env>.env.yaml.
from typing import Any
from pydantic import BaseModel
from pydantic_yaml import YamlModel


class Dns(BaseModel):
    BASE_DOMAIN: str


class Env(YamlModel):
    dns: Dns
    hub: Any
    auth: Any
    mail: Any
    box: Any


class CnfModel(YamlModel):
    env: Env
