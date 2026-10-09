# spec 115 CNF-1: env.box.agent_split_by_kind, the per-kind weights and the
# backup vendor. The real all.env.yaml holds the spec's table; each table rule
# of spec 115 section 2 has a control that turns the validator red.
#   cd csi-spl-cnf/src/python/conf-validator && python3 -m unittest discover
import copy
import unittest
from pathlib import Path

from pydantic import ValidationError

from EnvModels import AllEnv

ALL_ENV = Path(__file__).resolve().parents[4] / "csi-spl" / "all.env.yaml"

# spec 115 section 2: kind -> (main, backup)
SPEC_MAIN_BACKUP = {
    "specs_and_docs": ("agy", "claude"),
    "tests": ("claude", "mistral"),
    "simple_coding": ("mistral", "claude"),
    "complex_coding": ("claude", "mistral"),
    "i18n": ("agy", "claude"),
    "secret": ("claude", "mistral"),
}

ROWS = {
    "specs_and_docs": {"agy": 70, "mistral": 20, "claude": 10, "backup": "claude"},
    "tests": {"claude": 70, "mistral": 30, "backup": "mistral"},
    "simple_coding": {"mistral": 80, "claude": 20, "backup": "claude"},
    "complex_coding": {"claude": 80, "mistral": 20, "backup": "mistral"},
    "i18n": {"agy": 100, "backup": "claude"},
    "secret": {"claude": 100, "backup": "mistral"},
}


def _all_env(rows):
    return {"env": {
        "dns": {"BASE_DOMAIN": "example.com"},
        "hub": {}, "auth": {}, "mail": {},
        "box": {"agent_split": {"claude": 60}, "agent_split_by_kind": rows},
        "i18n": {"default_locale": "en", "locales": ["en"]},
    }}


class AgentSplitByKindTest(unittest.TestCase):
    def assertRed(self, rows, needle):
        with self.assertRaises(ValidationError) as cm:
            AllEnv.parse_obj(_all_env(rows))
        self.assertIn(needle, str(cm.exception))

    def test_all_env_yaml_holds_the_spec_table(self):
        rows = AllEnv.parse_raw(ALL_ENV.read_text()).env.box.agent_split_by_kind
        self.assertEqual(set(rows), set(SPEC_MAIN_BACKUP))
        for kind, (main, backup) in SPEC_MAIN_BACKUP.items():
            self.assertEqual((rows[kind].main(), rows[kind].backup), (main, backup), kind)

    def test_other_box_keys_pass_through(self):
        box = AllEnv.parse_obj(_all_env(ROWS)).env.box
        self.assertEqual(box.agent_split, {"claude": 60})

    def test_a_row_not_summing_to_100_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["tests"]["claude"] = 71
        self.assertRed(rows, "sum to 101")

    def test_a_tied_main_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["tests"].update(claude=50, mistral=50)
        self.assertRed(rows, "tie")

    def test_backup_equal_to_main_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["simple_coding"]["backup"] = "mistral"
        self.assertRed(rows, "is the main")

    def test_a_weight_out_of_range_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["i18n"].update(agy=110, claude=-10)
        self.assertRed(rows, "i18n")

    def test_agy_in_a_coding_kind_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["complex_coding"].update(claude=70, agy=10)
        self.assertRed(rows, "agy writes no code")
        rows = copy.deepcopy(ROWS)
        rows["tests"]["backup"] = "agy"
        self.assertRed(rows, "agy writes no code")

    def test_secret_outside_claude_and_mistral_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["secret"].update(claude=90, grok=10)
        self.assertRed(rows, "secret")
        rows = copy.deepcopy(ROWS)
        rows["secret"]["backup"] = "qwen"
        self.assertRed(rows, "secret")

    def test_unknown_or_missing_kind_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["docs"] = rows.pop("specs_and_docs")
        self.assertRed(rows, "kinds unknown")

    def test_unknown_vendor_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["i18n"].update(agy=90, gemini=10)
        self.assertRed(rows, "gemini")


if __name__ == "__main__":
    unittest.main()
