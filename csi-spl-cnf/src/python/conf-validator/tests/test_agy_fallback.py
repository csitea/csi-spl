# spec 184 section 10 (SPL-6661): env.box.agent_split.agy_fallback, the
# conf-validator model EnvModels/agy_fallback.py. The real all.env.yaml ships
# it off; each refusal has its case, and the red control is case 1 (the
# shipped block must read enabled: false).
#   cd csi-spl-cnf/src/python/conf-validator && python3 -m unittest tests.test_agy_fallback
import copy
import unittest
from pathlib import Path

import yaml
from pydantic import ValidationError

from EnvModels import AllEnv

ALL_ENV = Path(__file__).resolve().parents[4] / "csi-spl" / "all.env.yaml"

OK = {
    "enabled": True,
    "weekly_min": 0.05,
    "five_hour_min": 0.05,
    "alt_min": 0.1,
    "models": ["claude-sonnet-5-5-high", "gpt-oss-120b-medium"],
    "kinds": ["specs_and_docs", "complex_coding"],
    "cache_s": 300,
}


def _all_env(block):
    return {
        "env": {
            "dns": {"BASE_DOMAIN": "example.com"},
            "hub": {},
            "auth": {},
            "mail": {},
            "box": {"agent_split": {"agy_fallback": block}},
            "i18n": {"default_locale": "en", "locales": ["en"]},
        }
    }


class AgyFallbackTest(unittest.TestCase):
    def assertRed(self, block, needle):
        with self.assertRaises(ValidationError) as cm:
            AllEnv.parse_obj(_all_env(block))
        self.assertIn(needle, str(cm.exception))

    def test_1_shipped_block_is_off(self):
        doc = yaml.safe_load(ALL_ENV.read_text())
        block = doc["env"]["box"]["agent_split"]["agy_fallback"]
        self.assertIs(block["enabled"], False)
        AllEnv.parse_obj(_all_env(block))
        self.assertTrue(all(not m.startswith("gemini") for m in block["models"]))

    def test_2_a_good_block_passes(self):
        AllEnv.parse_obj(_all_env(OK))

    def test_3_a_model_with_a_space_is_refused(self):
        b = copy.deepcopy(OK)
        b["models"] = ["Claude Sonnet 5.5 (High)"]
        self.assertRed(b, "models")

    def test_4_a_gemini_alternative_is_refused(self):
        b = copy.deepcopy(OK)
        b["models"] = ["gemini-3.8-flash-high"]
        self.assertRed(b, "share the pool")

    def test_5_a_review_or_secret_kind_is_refused(self):
        for kind in ("review", "i18n", "secret", "orchestration"):
            b = copy.deepcopy(OK)
            b["kinds"] = ["tests", kind]
            self.assertRed(b, "doc and coding kinds only")

    def test_6_a_fraction_out_of_range_is_refused(self):
        b = copy.deepcopy(OK)
        b["weekly_min"] = 5
        self.assertRed(b, "weekly_min")

    def test_7_on_with_no_models_is_refused(self):
        b = copy.deepcopy(OK)
        b["models"] = []
        self.assertRed(b, "no alternative models")

    def test_8_an_unknown_key_is_refused(self):
        b = copy.deepcopy(OK)
        b["review_seats"] = True
        self.assertRed(b, "review_seats")


if __name__ == "__main__":
    unittest.main()
