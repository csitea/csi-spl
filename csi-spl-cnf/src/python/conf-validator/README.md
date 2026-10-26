# Configuration Validator

> Generated from qto doc `7cb1f76c-0efb-454d-8bc5-833acfa4c63c`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Ported from csi-rel-cnf's conf-validator. The CLI (`conf_validator/`), the exit-code
contract and the dependencies (`pyproject.toml`, `poetry.lock`) are csi-rel's, with only
names changed. The models (`EnvModels/`) describe csi-spl's config shape instead of csi-rel's.

It validates a YAML config against the Pydantic model registered for an env. It uses
`typer` for the CLI, `rich` for console logging and `pydantic_yaml` (pydantic 1.x) for parsing.

<a id="ws-doc-ebb01e09-3ae8-43a4-8338-9304784c1022"></a>
## What is validated: the EFFECTIVE config

csi-spl keeps its config in two files:

- `csi-spl-cnf/csi-spl/all.env.yaml` holds what every env shares: the domain, the hub, auth,
  mail and box settings.
- `csi-spl-cnf/csi-spl/<env>.env.yaml` holds what is specific to one env.

`do_spl_merged_cnf` (in `csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh`) deep-merges the
first file under the second and derives `env.dns.fqdn`. tpl-gen renders the tfvars from that
merged file. `make do-spl-merged-cnf` writes it to `csi-spl-cnf/csi-spl/.merged/<env>.env.yaml`,
which is git-ignored. `make do-generate-config-for-step` then validates that file and renders
from it.

A raw `<env>.env.yaml` on its own has no hub block and no fqdn, so it cannot be rendered.
Validating it exits `1`.

<a id="ws-doc-5b71abe9-982b-4787-826c-d1ca3fdd446e"></a>
## Models

- `EnvModels/cloud.py` covers `dev` and `prd`. It requires `ENV`, `ORG`, `APP`, `ORG_APP`,
  `dns` (`BASE_DOMAIN`, `env_subdomain`, `fqdn`), `versions`, `gcp` (`gcp_project`,
  `gcp_region`, `state_bucket`), `steps` (one map per terraform step) and `hub`, `auth`,
  `mail`, `box`. It also enforces the realm rule:
  - `ORG_APP` is `<ORG>-<APP>`
  - `gcp.gcp_project` is `<ORG_APP>-<ENV>`
  - `gcp.state_bucket` is `<gcp_project>-tfstate`
- `EnvModels/all.py` covers `all.env.yaml` on its own: `dns.BASE_DOMAIN` plus the shared blocks.

<a id="ws-doc-6855d2ef-62f2-4fec-aec9-d0602286b4a3"></a>
## Usage

Run it from this directory with the file and the env as positional arguments. This is
exactly what the Make target runs:

```bash
poetry run validate <path-to-yaml-file> <environment>
```

<a id="ws-doc-c482ee51-eeb7-40e7-8ca8-aee0bfb1a9a6"></a>
## Exit codes are a contract, because the Make target gates on them

| Code | Meaning |
|------|---------|
| `0` | parsed against the env's model and **valid** |
| `1` | **checked and invalid**; the offending fields are printed |
| `2` | **could not be checked**: the env has no model, or the file is not there |

`csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh` pins these codes.

<a id="ws-doc-9e906666-760d-4e65-98c0-a85336a443f4"></a>
## Which envs can be validated

`dev`, `prd` and `all`, as listed in `Classes/EnvEnum.py`. `lde` has no model, so it exits `2`.
