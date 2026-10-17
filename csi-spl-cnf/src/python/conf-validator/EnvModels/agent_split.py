# csi-spl ::: env.box.agent_split_by_kind (spec 115 CNF-1), shared by the
# all.env.yaml model and the cloud env model. The table rules of spec 115
# section 2 are enforced here, so a bad row turns the conf-validator red
# before tpl-gen renders anything.
from typing import Dict, Literal, Optional
from pydantic import BaseModel, Extra, conint, root_validator, validator

VENDORS = ("agy", "mistral", "claude", "grok", "qwen")
KINDS = (
    "specs_and_docs",
    "tests",
    "simple_coding",
    "complex_coding",
    "i18n",
    "secret",
    "orchestration",
)
CODING_KINDS = ("tests", "simple_coding", "complex_coding")
# the data rule, owner msgs 803c3b38, 26117740, 474f32a0: the secret-class
# kinds (orchestration: owner msgs a1e5c678, ff1baf01) take only these
SECRET_KINDS = ("secret", "orchestration")
SECRET_VENDORS = ("claude", "grok", "mistral")
# owner HUM-10, t1 b61851fb, msg 91bf8278 (2026-10-17): "Docs and reviews
# only, no coding": mistral is 0 and never the backup in these kinds while
# env.box.agent_split.mistral_coding_allowed is not true
MISTRAL_NO_CODE_KINDS = CODING_KINDS + SECRET_KINDS

Weight = conint(ge=0, le=100)


class KindRow(BaseModel, extra=Extra.forbid):
    """One kind's weights out of 100 (a vendor left out is 0) and its backup."""

    agy: Weight = 0
    mistral: Weight = 0
    claude: Weight = 0
    grok: Weight = 0
    qwen: Weight = 0
    backup: Literal["agy", "mistral", "claude", "grok", "qwen"]

    @root_validator(skip_on_failure=True)
    def sums_to_100_with_one_main(cls, values):
        weights = {v: values[v] for v in VENDORS}
        total = sum(weights.values())
        if total != 100:
            raise ValueError(f"weights sum to {total}, not 100")
        top = max(weights.values())
        mains = [v for v, w in weights.items() if w == top]
        if len(mains) != 1:
            raise ValueError(f"main is a tie between {', '.join(mains)} at {top}")
        if values["backup"] == mains[0]:
            raise ValueError(f"backup {values['backup']} is the main")
        return values

    def main(self) -> str:
        return max(VENDORS, key=lambda v: getattr(self, v))


class Box(BaseModel, extra=Extra.allow):
    """env.box: only agent_split_by_kind is modelled; the other keys pass through."""

    agent_split_by_kind: Optional[Dict[str, KindRow]]

    @root_validator(skip_on_failure=True)
    def mistral_writes_no_code(cls, values):
        rows = values.get("agent_split_by_kind")
        split = values.get("agent_split") or {}
        if rows is None or (
            isinstance(split, dict) and split.get("mistral_coding_allowed") is True
        ):
            return values
        for kind in MISTRAL_NO_CODE_KINDS:
            row = rows[kind]
            if row.mistral != 0 or row.backup == "mistral":
                raise ValueError(
                    f"{kind}: mistral writes no code, docs and reviews only"
                    " (weight 0, never the backup; owner msg 91bf8278)"
                )
        return values

    @validator("agent_split_by_kind")
    def kind_rules(cls, rows):
        if rows is None:
            return rows
        unknown = sorted(set(rows) - set(KINDS))
        missing = [k for k in KINDS if k not in rows]
        if unknown or missing:
            raise ValueError(f"kinds unknown: {unknown}, missing: {missing}")
        for kind in CODING_KINDS:
            row = rows[kind]
            if row.agy != 0 or row.backup == "agy":
                raise ValueError(
                    f"{kind}: agy writes no code (weight 0, never the backup)"
                )
        for kind in SECRET_KINDS:
            row = rows[kind]
            others = [
                v for v in VENDORS if v not in SECRET_VENDORS and getattr(row, v) != 0
            ]
            if others or row.backup not in SECRET_VENDORS:
                raise ValueError(
                    f"{kind}: only claude, grok and mistral may be non-zero or the backup"
                )
        return rows
