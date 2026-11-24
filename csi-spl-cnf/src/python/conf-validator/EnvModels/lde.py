# csi-spl ::: the shape of the lde (local developer stack) EFFECTIVE config:
# all.env.yaml deep-merged under lde.env.yaml plus the derived env.dns.fqdn,
# i.e. what do_spl_merged_cnf writes for ENV=lde. lde runs no terraform, so it
# has no steps, versions or GCP project; its own settings sit under env.lde
# (compose project, ports, emulators), read by csi-spl-orc do_setup_app_inf.
# SPL-451: this model is also one third of csi-spl-cnf/schema/env-schema.json
# (conf_validator/env_schema_export.py generates the JSON schema from it).
from typing import Any, Literal
from pydantic import root_validator
from pydantic_yaml import YamlModel

from .agent_split import Box
from .all import Rhythm
from .cloud import Cloud, Dns, I18n


class Env(YamlModel):
    ENV: Literal["lde"]
    ORG: str
    APP: str
    ORG_APP: str
    dns: Dns
    cloud: Cloud = Cloud()
    hub: Any
    auth: Any
    i18n: I18n
    mail: Any
    box: Box
    rhythm: Rhythm = Rhythm()
    # env.lde: compose_project, pg, gcs, wui, hub, smoke_tenant, switches, ...
    lde: Any

    @root_validator(skip_on_failure=True)
    def realm(cls, values):
        if values["ORG_APP"] != f"{values['ORG']}-{values['APP']}":
            raise ValueError(f"ORG_APP {values['ORG_APP']} is not ORG-APP")
        return values


class CnfModel(YamlModel):
    env: Env
