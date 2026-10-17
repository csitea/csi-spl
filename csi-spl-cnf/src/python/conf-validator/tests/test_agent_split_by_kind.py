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

# spec 115 section 2: kind -> (main, backup). Owner HUM-10 msg 91bf8278
# (2026-10-17, "Docs and reviews only, no coding"): mistral is out of every
# coding kind; claude is their main, so grok (off) is the legal backup.
SPEC_MAIN_BACKUP = {
    "specs_and_docs": ("agy", "claude"),
    "tests": ("claude", "grok"),
    "simple_coding": ("claude", "grok"),
    "complex_coding": ("claude", "grok"),
    "i18n": ("agy", "claude"),
    "secret": ("claude", "grok"),
    "orchestration": ("claude", "grok"),
}

ROWS = {
    "specs_and_docs": {"agy": 80, "mistral": 15, "claude": 5, "backup": "claude"},
    "tests": {"claude": 85, "grok": 15, "backup": "grok"},
    "simple_coding": {"claude": 59, "grok": 41, "backup": "grok"},
    "complex_coding": {"claude": 90, "grok": 10, "backup": "grok"},
    "i18n": {"agy": 100, "backup": "claude"},
    "secret": {"claude": 100, "backup": "grok"},
    "orchestration": {"claude": 65, "grok": 35, "backup": "grok"},
}
# the coding kinds of the owner order: mistral 0 and never the backup
NO_MISTRAL_KINDS = (
    "tests",
    "simple_coding",
    "complex_coding",
    "secret",
    "orchestration",
)


def _all_env(rows, split=None):
    return {
        "env": {
            "dns": {"BASE_DOMAIN": "example.com"},
            "hub": {},
            "auth": {},
            "mail": {},
            "box": {
                "agent_split": split or {"claude": 60},
                "agent_split_by_kind": rows,
            },
            "i18n": {"default_locale": "en", "locales": ["en"]},
        }
    }


class AgentSplitByKindTest(unittest.TestCase):
    def assertRed(self, rows, needle, split=None):
        with self.assertRaises(ValidationError) as cm:
            AllEnv.parse_obj(_all_env(rows, split))
        self.assertIn(needle, str(cm.exception))

    def assertGreen(self, rows, split=None):
        AllEnv.parse_obj(_all_env(rows, split))

    def test_all_env_yaml_holds_the_spec_table(self):
        rows = AllEnv.parse_raw(ALL_ENV.read_text()).env.box.agent_split_by_kind
        self.assertEqual(set(rows), set(SPEC_MAIN_BACKUP))
        for kind, (main, backup) in SPEC_MAIN_BACKUP.items():
            self.assertEqual(
                (rows[kind].main(), rows[kind].backup), (main, backup), kind
            )

    def test_other_box_keys_pass_through(self):
        box = AllEnv.parse_obj(_all_env(ROWS)).env.box
        self.assertEqual(box.agent_split, {"claude": 60})

    def test_a_row_not_summing_to_100_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["tests"]["claude"] = 86
        self.assertRed(rows, "sum to 101")

    def test_a_tied_main_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["tests"].update(claude=50, grok=0, mistral=50)
        self.assertRed(rows, "tie")

    def test_backup_equal_to_main_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["simple_coding"]["backup"] = "claude"
        self.assertRed(rows, "is the main")

    def test_a_weight_out_of_range_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["i18n"].update(agy=110, claude=-10)
        self.assertRed(rows, "i18n")

    def test_agy_in_a_coding_kind_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["complex_coding"].update(claude=80, agy=10)
        self.assertRed(rows, "agy writes no code")
        rows = copy.deepcopy(ROWS)
        rows["tests"]["backup"] = "agy"
        self.assertRed(rows, "agy writes no code")

    def test_secret_outside_claude_grok_and_mistral_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["secret"].update(claude=90, qwen=10)
        self.assertRed(rows, "secret")
        rows = copy.deepcopy(ROWS)
        rows["secret"].update(claude=90, agy=10)
        self.assertRed(rows, "secret")
        rows = copy.deepcopy(ROWS)
        rows["secret"]["backup"] = "qwen"
        self.assertRed(rows, "secret")
        rows = copy.deepcopy(ROWS)
        rows["secret"]["backup"] = "agy"
        self.assertRed(rows, "secret")

    def test_secret_with_grok_is_green(self):
        rows = copy.deepcopy(ROWS)
        rows["secret"] = {"grok": 60, "claude": 40, "backup": "claude"}
        self.assertGreen(rows)

    def test_orchestration_outside_claude_grok_and_mistral_is_red(self):
        rows = copy.deepcopy(ROWS)
        rows["orchestration"].update(claude=55, agy=10)
        self.assertRed(rows, "orchestration")
        rows = copy.deepcopy(ROWS)
        rows["orchestration"].update(claude=55, qwen=10)
        self.assertRed(rows, "orchestration")
        rows = copy.deepcopy(ROWS)
        rows["orchestration"]["backup"] = "agy"
        self.assertRed(rows, "orchestration")

    def test_orchestration_with_mistral_is_green_only_when_coding_is_allowed(self):
        rows = copy.deepcopy(ROWS)
        rows["orchestration"] = {
            "claude": 50,
            "grok": 30,
            "mistral": 20,
            "backup": "mistral",
        }
        self.assertGreen(rows, {"claude": 60, "mistral_coding_allowed": True})
        self.assertRed(rows, "mistral writes no code")

    # owner HUM-10 msg 91bf8278: each coding kind with a mistral weight or a
    # mistral backup is red (the controls: today's old rows), docs keep it
    def test_mistral_in_a_coding_kind_is_red(self):
        for kind in NO_MISTRAL_KINDS:
            rows = copy.deepcopy(ROWS)
            main = rows[kind].get("claude", 0)
            rows[kind].update(claude=main - 5, mistral=5)
            self.assertRed(rows, f"{kind}: mistral writes no code")
            rows = copy.deepcopy(ROWS)
            rows[kind]["backup"] = "mistral"
            self.assertRed(rows, f"{kind}: mistral writes no code")

    def test_the_old_rows_are_red(self):
        rows = copy.deepcopy(ROWS)
        rows["tests"] = {"claude": 70, "grok": 15, "mistral": 15, "backup": "mistral"}
        rows["simple_coding"] = {
            "grok": 41,
            "mistral": 39,
            "claude": 20,
            "backup": "claude",
        }
        rows["complex_coding"] = {
            "claude": 80,
            "grok": 10,
            "mistral": 10,
            "backup": "mistral",
        }
        rows["secret"] = {"claude": 100, "backup": "mistral"}
        self.assertRed(rows, "mistral writes no code")

    def test_specs_and_docs_keeps_mistral(self):
        rows = copy.deepcopy(ROWS)
        rows["specs_and_docs"] = {
            "mistral": 60,
            "agy": 30,
            "claude": 10,
            "backup": "claude",
        }
        self.assertGreen(rows)
        rows["specs_and_docs"] = {"agy": 80, "claude": 20, "backup": "mistral"}
        self.assertGreen(rows)

    def test_all_env_yaml_keeps_coding_off_for_mistral(self):
        box = AllEnv.parse_raw(ALL_ENV.read_text()).env.box
        self.assertIs(box.agent_split["mistral_coding_allowed"], False)
        self.assertGreater(box.agent_split_by_kind["specs_and_docs"].mistral, 0)

    def test_all_env_yaml_rows_hold_the_owner_weights(self):
        rows = AllEnv.parse_raw(ALL_ENV.read_text()).env.box.agent_split_by_kind
        for kind, row in ROWS.items():
            want = {
                v: row.get(v, 0) for v in ("agy", "mistral", "claude", "grok", "qwen")
            }
            got = {v: getattr(rows[kind], v) for v in want}
            self.assertEqual((got, rows[kind].backup), (want, row["backup"]), kind)

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
