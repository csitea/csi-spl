# csi-spl ::: env.box.agent_split.agy_fallback (spec 184 section 10,
# SPL-6661): when agy's Gemini quota is low, an agy seat starts on one of
# agy's own alternative models. The rules here keep a bad block from ever
# reaching a launch line: the model ids follow the syntax of spec 184 7.1.2,
# no alternative is a Gemini model (they share the pool that is low), the
# kinds are doc and coding kinds only (never a review, never secret-class),
# and the switch on needs at least one alternative.
from typing import List

from pydantic import (
    BaseModel,
    Extra,
    confloat,
    conint,
    constr,
    root_validator,
    validator,
)

MODEL_RX = r"^[A-Za-z0-9._:/-]{1,80}$"
# doc and coding lanes only (c-001 847c41a2): i18n, secret and
# orchestration are never in the list
ALLOWED_KINDS = ("specs_and_docs", "tests", "simple_coding", "complex_coding")

Fraction = confloat(ge=0, le=1)


class AgyFallback(BaseModel, extra=Extra.forbid):
    """The agy alternative-model switch; ships off."""

    enabled: bool = False
    weekly_min: Fraction = 0.05
    five_hour_min: Fraction = 0.05
    alt_min: Fraction = 0.10
    models: List[constr(regex=MODEL_RX)] = []
    kinds: List[str] = []
    cache_s: conint(ge=0, le=86400) = 300

    @validator("models")
    def no_gemini_alternative(cls, models):
        gem = [m for m in models if m.lower().startswith("gemini")]
        if gem:
            raise ValueError(
                f"alternatives {gem} are Gemini models: they share the pool that is low"
            )
        return models

    @validator("kinds")
    def doc_and_coding_kinds_only(cls, kinds):
        bad = sorted(set(kinds) - set(ALLOWED_KINDS))
        if bad:
            raise ValueError(
                f"kinds {bad} may not fall back: doc and coding kinds only"
                f" ({', '.join(ALLOWED_KINDS)})"
            )
        return kinds

    @root_validator(skip_on_failure=True)
    def on_needs_models(cls, values):
        if values.get("enabled") and not values.get("models"):
            raise ValueError("enabled with no alternative models")
        return values
