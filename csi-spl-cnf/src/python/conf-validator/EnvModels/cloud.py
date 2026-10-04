# csi-spl ::: the shape of ONE cloud env's EFFECTIVE config: all.env.yaml
# deep-merged under <env>.env.yaml plus the derived env.dns.fqdn, i.e. the
# file do_spl_merged_cnf writes and tpl-gen renders the tfvars from. The raw
# <env>.env.yaml alone is not a renderable config (no hub, no fqdn), so it is
# not what this model describes.
import re
from typing import Any, Dict, Optional
from pydantic import BaseModel, root_validator
from pydantic_yaml import YamlModel

# GCP's own project id rule
GCP_PROJECT_ID = re.compile(r"[a-z][a-z0-9-]{4,28}[a-z0-9]")


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
    i18n: I18n
    mail: Any
    box: Any

    @root_validator(skip_on_failure=True)
    def realm(cls, values):
        # realm rule: the env's GCP project is cnf gcp.gcp_project and its
        # terraform state lives in <gcp_project>-tfstate. The id is NOT
        # required to be <org>-<app>-<env> (spec 072 A8): project ids are
        # global, so a clone whose plain id is taken names its own, e.g.
        # <org>-<app>-<env>-<suffix>. Only GCP's own id rule applies.
        org_app, gcp = values["ORG_APP"], values["gcp"]
        if org_app != f'{values["ORG"]}-{values["APP"]}':
            raise ValueError(f"ORG_APP {org_app} is not ORG-APP")
        if not GCP_PROJECT_ID.fullmatch(gcp.gcp_project):
            raise ValueError(
                f"gcp.gcp_project {gcp.gcp_project} is not a GCP project id "
                "(6-30 lowercase letters, digits or -, a letter first, no - last)")
        if gcp.state_bucket != f"{gcp.gcp_project}-tfstate":
            raise ValueError(f"gcp.state_bucket {gcp.state_bucket} is not {gcp.gcp_project}-tfstate")
        return values


class CnfModel(YamlModel):
    """The base configuration model

    Description:
        This data model describes how the data in configuration files should look like
    """

    env: Env
