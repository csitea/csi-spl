# spec 166 row B1: env.rhythm, the day and night of do_spl_rhythm_phase.
# night_start and night_end are hours 0..23; the real all.env.yaml carries
# the spec's window (20 to 7, Europe/Berlin).
#   cd csi-spl-cnf/src/python/conf-validator && python3 -m unittest discover
import unittest
from pathlib import Path

from pydantic import ValidationError

from EnvModels import AllEnv
from EnvModels.all import Rhythm

ALL_ENV = Path(__file__).resolve().parents[4] / "csi-spl" / "all.env.yaml"


def _all_env(**rhythm):
    return {
        "env": {
            "dns": {"BASE_DOMAIN": "example.com"},
            "rhythm": rhythm,
            "hub": {},
            "auth": {},
            "mail": {},
            "box": {},
            "i18n": {"default_locale": "en", "locales": ["en"]},
        }
    }


class RhythmTest(unittest.TestCase):
    def test_all_env_yaml_carries_the_spec_window(self):
        r = AllEnv.parse_raw(ALL_ENV.read_text()).env.rhythm
        self.assertEqual(
            (r.timezone, r.night_start, r.night_end, r.zombie_idle_days, r.zombie_max),
            ("Europe/Berlin", 20, 7, 7, 500),
        )

    def test_hours_0_and_23_are_accepted(self):
        r = AllEnv.parse_obj(_all_env(night_start=0, night_end=23)).env.rhythm
        self.assertEqual((r.night_start, r.night_end), (0, 23))

    def test_night_start_outside_0_23_is_refused(self):
        for bad in (24, -1, 99):
            with self.assertRaises(ValidationError) as cm:
                AllEnv.parse_obj(_all_env(night_start=bad))
            self.assertIn("night_start", str(cm.exception))
        with self.assertRaises(ValidationError):
            Rhythm(night_end=24)

    def test_all_env_yaml_carries_a_live_reflection_discussion(self):
        r = AllEnv.parse_raw(ALL_ENV.read_text()).env.rhythm
        self.assertRegex(r.reflection_discussion or "", r"^[0-9a-f]{8}-")
        self.assertNotEqual(
            r.reflection_discussion, "c0b0d572-c575-4849-8792-4c3ce4d170f2"
        )

    def test_reflection_discussion_not_a_uuid_is_refused(self):
        for bad in ("c0b0d572", "fcf09921-8F21-4518-a117-f8ddb41bfff5", "t1"):
            with self.assertRaises(ValidationError) as cm:
                AllEnv.parse_obj(_all_env(reflection_discussion=bad))
            self.assertIn("reflection_discussion", str(cm.exception))

    def test_absent_rhythm_is_the_spec_window(self):
        doc = _all_env()
        del doc["env"]["rhythm"]
        r = AllEnv.parse_obj(doc).env.rhythm
        self.assertEqual(
            (r.night_start, r.night_end, r.timezone), (20, 7, "Europe/Berlin")
        )


if __name__ == "__main__":
    unittest.main()
