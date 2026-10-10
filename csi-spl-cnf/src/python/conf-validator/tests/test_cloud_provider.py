# spec 076 T002: env.cloud.provider is gcp, none or aws (default gcp), in both
# the all.env.yaml model and the effective cloud env model.
#   cd csi-spl-cnf/src/python/conf-validator && python3 -m unittest discover
import unittest
from pathlib import Path

from pydantic import ValidationError

from EnvModels import AllEnv
from EnvModels.all import Cloud as AllCloud
from EnvModels.cloud import Cloud as EnvCloud

ALL_ENV = Path(__file__).resolve().parents[4] / "csi-spl" / "all.env.yaml"


def _all_env(**cloud):
    return {
        "env": {
            "dns": {"BASE_DOMAIN": "example.com"},
            "cloud": cloud,
            "hub": {},
            "auth": {},
            "mail": {},
            "box": {},
            "i18n": {"default_locale": "en", "locales": ["en"]},
        }
    }


class CloudProviderTest(unittest.TestCase):
    def test_all_env_yaml_says_gcp(self):
        self.assertEqual(
            AllEnv.parse_raw(ALL_ENV.read_text()).env.cloud.provider, "gcp"
        )

    def test_each_known_provider_is_accepted(self):
        for p in ("gcp", "none", "aws"):
            self.assertEqual(
                AllEnv.parse_obj(_all_env(provider=p)).env.cloud.provider, p
            )
            self.assertEqual(EnvCloud(provider=p).provider, p)

    def test_azure_is_rejected(self):
        with self.assertRaises(ValidationError) as cm:
            AllEnv.parse_obj(_all_env(provider="azure"))
        self.assertIn("cloud", str(cm.exception))
        for model in (AllCloud, EnvCloud):
            with self.assertRaises(ValidationError):
                model(provider="azure")

    def test_provider_defaults_to_gcp(self):
        self.assertEqual(AllEnv.parse_obj(_all_env()).env.cloud.provider, "gcp")
        doc = _all_env()
        del doc["env"]["cloud"]
        self.assertEqual(AllEnv.parse_obj(doc).env.cloud.provider, "gcp")
        self.assertEqual(EnvCloud().provider, "gcp")


if __name__ == "__main__":
    unittest.main()
