# spec 184 row C1: env.box.agent_model (contract 7.1.1), the conf-validator
# model EnvModels/agent_model.py. The real all.env.yaml ships the block empty;
# each refusal of the row's done test has a control that turns it red.
#   cd csi-spl-cnf/src/python/conf-validator && python3 -m unittest tests.test_agent_model
import copy
import unittest
from pathlib import Path

from pydantic import ValidationError

from EnvModels import AllEnv
from EnvModels import agent_model, agent_split

ALL_ENV = Path(__file__).resolve().parents[4] / "csi-spl" / "all.env.yaml"

EMPTY = {
    "default": {v: "" for v in ("claude", "agy", "grok", "mistral", "qwen", "codex")},
    "by_kind": {},
}


def _all_env(block):
    return {
        "env": {
            "dns": {"BASE_DOMAIN": "example.com"},
            "hub": {},
            "auth": {},
            "mail": {},
            "box": {"agent_model": block},
            "i18n": {"default_locale": "en", "locales": ["en"]},
        }
    }


class AgentModelTest(unittest.TestCase):
    def assertRed(self, block, needle):
        with self.assertRaises(ValidationError) as cm:
            AllEnv.parse_obj(_all_env(block))
        self.assertIn(needle, str(cm.exception))

    def assertGreen(self, block):
        return AllEnv.parse_obj(_all_env(block)).env.box.agent_model

    def test_all_env_yaml_ships_the_block_empty(self):
        got = AllEnv.parse_raw(ALL_ENV.read_text()).env.box.agent_model
        self.assertIsNotNone(got, "env.box.agent_model is missing from all.env.yaml")
        self.assertEqual(got.default, EMPTY["default"])
        self.assertEqual(got.by_kind, {})

    def test_vendor_and_kind_lists_equal_the_split(self):
        self.assertEqual(agent_model.VENDORS, agent_split.VENDORS)
        self.assertEqual(agent_model.KINDS, agent_split.KINDS)

    def test_verified_vendors_take_a_model(self):
        block = copy.deepcopy(EMPTY)
        block["default"].update(
            claude="sonnet", grok="grok-4.6", mistral="mistral-large"
        )
        block["by_kind"] = {
            "complex_coding": {"claude": "claude-opus-5-5"},
            "tests": {"grok": "grok-4.7-build-fast", "agy": ""},
        }
        got = self.assertGreen(block)
        self.assertEqual(got.default["claude"], "sonnet")
        self.assertEqual(got.by_kind["complex_coding"]["claude"], "claude-opus-5-5")

    def test_a_model_failing_the_syntax_is_red(self):
        for bad in ("a b", "x'y", 'q"', "$(id)", "a;b", "m" * 81):
            block = copy.deepcopy(EMPTY)
            block["default"]["claude"] = bad
            with self.subTest(model=bad):
                self.assertRed(block, "7.1.2")
        block = copy.deepcopy(EMPTY)
        block["by_kind"] = {"tests": {"grok": "a b"}}
        self.assertRed(block, "7.1.2")

    def test_the_80_char_edge_is_green(self):
        block = copy.deepcopy(EMPTY)
        block["default"]["claude"] = "m" * 80
        self.assertGreen(block)

    def test_a_cell_for_an_unknown_kind_is_red(self):
        block = copy.deepcopy(EMPTY)
        block["by_kind"] = {"poetry": {"claude": "sonnet"}}
        self.assertRed(block, "unknown task kind 'poetry'")

    def test_a_cell_for_an_unknown_vendor_is_red(self):
        block = copy.deepcopy(EMPTY)
        block["default"]["gpt"] = "x"
        self.assertRed(block, "unknown vendor 'gpt'")
        block = copy.deepcopy(EMPTY)
        block["by_kind"] = {"tests": {"cursor": ""}}
        self.assertRed(block, "unknown vendor 'cursor'")

    def test_an_unverified_vendor_with_a_model_is_red(self):
        for vendor in ("agy", "qwen", "codex"):
            block = copy.deepcopy(EMPTY)
            block["default"][vendor] = "some-model"
            with self.subTest(vendor=vendor, where="default"):
                self.assertRed(block, "UNVERIFIED")
            block = copy.deepcopy(EMPTY)
            block["by_kind"] = {"i18n": {vendor: "some-model"}}
            with self.subTest(vendor=vendor, where="by_kind"):
                self.assertRed(block, "UNVERIFIED")

    def test_an_unknown_key_is_red(self):
        block = copy.deepcopy(EMPTY)
        block["catalogue"] = {"claude": ["sonnet"]}
        self.assertRed(block, "catalogue")

    def test_a_non_string_model_is_red(self):
        block = copy.deepcopy(EMPTY)
        block["default"]["claude"] = 5
        self.assertRed(block, "must be a string")


if __name__ == "__main__":
    unittest.main()
