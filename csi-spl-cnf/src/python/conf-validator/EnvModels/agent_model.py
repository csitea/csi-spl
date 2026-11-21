# csi-spl ::: env.box.agent_model (spec 184 row C1, contract 7.1.1): the
# model a new agent starts with, per vendor (default) and per vendor per task
# kind (by_kind). "" = the CLI's own default (the launcher adds nothing).
# Syntax only (owner Q3 liv): whether the CLI offers the model is checked
# live at spawn (7.1.6), never here. Refused here: a model failing the
# syntax of 7.1.2, a kind or vendor the split does not know, and a non-empty
# model for a vendor whose words (7.1.3) are UNVERIFIED.
# Usage: AgentModel.parse_obj(cnf["env"]["box"]["agent_model"]); Box in
# agent_split.py wires it, so the all/dev/prd models refuse a bad block.
#   cd csi-spl-cnf/src/python/conf-validator && python3 -m unittest tests.test_agent_model
import re
from typing import Dict

from pydantic import BaseModel, Extra, validator

# spec 115's vendors and kinds, the same lists the split validates
VENDORS = ("agy", "mistral", "claude", "grok", "qwen", "codex")
KINDS = (
    "specs_and_docs",
    "tests",
    "simple_coding",
    "complex_coding",
    "i18n",
    "secret",
    "orchestration",
)
# spec 184 7.1.2: anything else never reaches a command line
MODEL_RX = re.compile(r"^[A-Za-z0-9._:/-]{1,80}$")
# spec 184 7.1.3: no measured model words yet (row M0 fills them); such a
# vendor holds only ""
UNVERIFIED_VENDORS = ("agy", "qwen", "codex")


def check_model(vendor, model, where):
    """Refuse an unknown vendor, a non-string, a bad syntax, or a model for an UNVERIFIED vendor."""
    if vendor not in VENDORS:
        raise ValueError(
            f"{where}: unknown vendor {vendor!r} (one of {', '.join(VENDORS)})"
        )
    if not isinstance(model, str):
        raise ValueError(f"{where}.{vendor}: model must be a string")
    if model == "":
        return
    if not MODEL_RX.fullmatch(model):
        raise ValueError(
            f"{where}.{vendor}: model {model!r} fails ^[A-Za-z0-9._:/-]{{1,80}}$ (spec 184 7.1.2)"
        )
    if vendor in UNVERIFIED_VENDORS:
        raise ValueError(
            f'{where}.{vendor}: model words UNVERIFIED (spec 184 7.1.3, row M0); only "" is allowed'
        )


class AgentModel(BaseModel, extra=Extra.forbid):
    """env.box.agent_model: default (vendor -> model) and by_kind (kind -> vendor -> model)."""

    default: Dict[str, str] = {}
    by_kind: Dict[str, Dict[str, str]] = {}

    @validator("default", pre=True)
    def default_cells(cls, cells):
        if cells is None:
            return {}
        if not isinstance(cells, dict):
            raise ValueError("default must map vendor -> model")
        for vendor, model in cells.items():
            check_model(vendor, model, "default")
        return cells

    @validator("by_kind", pre=True)
    def kind_cells(cls, rows):
        if rows is None:
            return {}
        if not isinstance(rows, dict):
            raise ValueError("by_kind must map task kind -> vendor -> model")
        for kind, cells in rows.items():
            if kind not in KINDS:
                raise ValueError(
                    f"by_kind: unknown task kind {kind!r} (one of {', '.join(KINDS)})"
                )
            if not isinstance(cells, dict):
                raise ValueError(f"by_kind.{kind} must map vendor -> model")
            for vendor, model in cells.items():
                check_model(vendor, model, f"by_kind.{kind}")
        return rows
