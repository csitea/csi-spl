# csi-spl ::: all.env.yaml, the settings shared by every env (deep-merged
# UNDER <env>.env.yaml by do_spl_merged_cnf). It holds THE domain and the hub
# env-var names; everything env-specific is in <env>.env.yaml.
from typing import Any, Dict, Literal, Optional
from pydantic import BaseModel, root_validator, validator
from pydantic import BaseModel
from pydantic_yaml import parse_yaml_raw_as, to_yaml_str


class Cloud(BaseModel):
    """spec 076: the cloud provider the env runs on; gcp unless the cnf says otherwise."""
    provider: Literal["gcp", "none", "aws"] = "gcp"


class Dns(BaseModel):
    BASE_DOMAIN: str


class VendorSplitByKind(BaseModel):
    """spec 115: per-kind vendor split. Each row sums to 100, one vendor holds the strict maximum (main),
    and backup is a vendor other than main. agy is 0 in every coding kind (tests, simple_coding,
    complex_coding) and is never the backup there. secret: only claude and mistral may be non-zero
    or the backup."""
    agy: Optional[int] = 0
    mistral: Optional[int] = 0
    claude: Optional[int] = 0
    grok: Optional[int] = 0
    qwen: Optional[int] = 0
    backup: str

    @validator('agy', 'mistral', 'claude', 'grok', 'qwen', pre=True, always=True)
    def set_defaults(cls, v):
        return v or 0

    @root_validator(skip_on_failure=True)
    def validate_row(cls, values):
        vendors = ['agy', 'mistral', 'claude', 'grok', 'qwen']
        weights = [values.get(v, 0) for v in vendors]
        total = sum(weights)
        
        if total != 100:
            raise ValueError(f'Row sums to {total}, must be 100')
        
        main_vendor = max(vendors, key=lambda v: values.get(v, 0))
        main_weight = values.get(main_vendor, 0)
        
        # Check for tied main
        if weights.count(main_weight) > 1:
            raise ValueError(f'Tied main weight {main_weight} for vendors: {[v for v, w in zip(vendors, weights) if w == main_weight]}')
        
        # agy must be 0 in coding kinds
        if values.get('agy', 0) > 0 and cls.__fields__['agy'].field_info.description and 'coding' in cls.__fields__['agy'].field_info.description:
            raise ValueError('agy must be 0 in coding kinds')
        
        # secret: only claude and mistral may be non-zero or the backup
        if cls.__fields__['backup'].field_info.description and 'secret' in cls.__fields__['backup'].field_info.description:
            if values.get('backup') not in ['claude', 'mistral']:
                raise ValueError('secret backup must be claude or mistral')
            if values.get('agy', 0) > 0 or values.get('grok', 0) > 0 or values.get('qwen', 0) > 0:
                raise ValueError('secret kind: only claude and mistral may be non-zero')
        
        # backup must be a vendor other than main
        if values.get('backup') == main_vendor:
            raise ValueError(f'backup cannot be the main vendor ({main_vendor})')
        
        return values


class AgentSplitByKind(BaseModel):
    """spec 115: per-kind vendor split. Keys are the kind names."""
    specs_and_docs: VendorSplitByKind
    tests: VendorSplitByKind
    simple_coding: VendorSplitByKind
    complex_coding: VendorSplitByKind
    i18n: VendorSplitByKind
    secret: VendorSplitByKind

    @validator('tests', 'simple_coding', 'complex_coding')
    def coding_kind_agy_zero(cls, v):
        if v.agy != 0:
            raise ValueError('agy must be 0 in coding kinds')
        return v

    @validator('secret')
    def secret_backup_valid(cls, v):
        if v.backup not in ['claude', 'mistral']:
            raise ValueError('secret backup must be claude or mistral')
        if v.agy > 0 or v.grok > 0 or v.qwen > 0:
            raise ValueError('secret kind: only claude and mistral may be non-zero')
        return v


class Box(BaseModel):
    """spec 115: vendor split by task kind."""
    agent_split_by_kind: AgentSplitByKind
    agent_split: Optional[Dict[str, Any]] = None  # Kept for backward compatibility


class I18n(BaseModel):
    """spec 021: the WUI + hub-mail locale set and the unprefixed default."""
    default_locale: str
    locales: list

    @root_validator(skip_on_failure=True)
    def default_is_shipped(cls, values):
        if values["default_locale"] not in values["locales"]:
            raise ValueError(f'i18n.default_locale {values["default_locale"]} is not in i18n.locales')
        return values


class Env(BaseModel):
    dns: Dns
    cloud: Cloud = Cloud()
    hub: Any
    auth: Any
    i18n: I18n
    mail: Any
    box: Box


class CnfModel(BaseModel):
    env: Env