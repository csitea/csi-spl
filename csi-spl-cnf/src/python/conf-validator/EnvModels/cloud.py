# csi-spl ::: the shape of ONE cloud env's EFFECTIVE config: all.env.yaml
# deep-merged under <env>.env.yaml plus the derived env.dns.fqdn, i.e. the
# file do_spl_merged_cnf writes and tpl-gen renders the tfvars from. The raw
# <env>.env.yaml alone is not a renderable config (no hub, no fqdn), so it is
# not what this model describes.
from typing import Any, Dict, Optional
from pydantic import BaseModel, root_validator
from pydantic_yaml import YamlModel


class Gcp(BaseModel):
    gcp_project: str
    gcp_region: str
    state_bucket: str


class Dns(BaseModel):
    BASE_DOMAIN: str
    env_subdomain: str
    fqdn: str


class Versions(BaseModel):
    infra_version: str
    terraform_version: str
    google_provider_version: Optional[str]


class Env(YamlModel):
    ENV: str
    ORG: str
    APP: str
    ORG_APP: str
    dns: Dns
    versions: Versions
    gcp: Gcp
    # one entry per terraform step; its keys are the step's own tfvars
    steps: Dict[str, Optional[Dict[str, Any]]]
    hub: Any
    auth: Any
    mail: Any
    box: Any

    @root_validator(skip_on_failure=True)
    def realm(cls, values):
        # owner realm rule: env <env> is GCP project <org>-<app>-<env> and
        # its terraform state lives in <org>-<app>-<env>-tfstate
        org_app, env, gcp = values["ORG_APP"], values["ENV"], values["gcp"]
        if org_app != f'{values["ORG"]}-{values["APP"]}':
            raise ValueError(f"ORG_APP {org_app} is not ORG-APP")
        if gcp.gcp_project != f"{org_app}-{env}":
            raise ValueError(f"gcp.gcp_project {gcp.gcp_project} is not {org_app}-{env}")
        if gcp.state_bucket != f"{gcp.gcp_project}-tfstate":
            raise ValueError(f"gcp.state_bucket {gcp.state_bucket} is not {gcp.gcp_project}-tfstate")
        return values


class CnfModel(YamlModel):
    """The base configuration model

    Description:
        This data model describes how the data in configuration files should look like
    """

    env: Env
