# csi-spl-orc

Operator and local dev orchestration (`lde`) for **csi-spl**, modeled directly on `/opt/pas/pas-psf/pas-psf-orc`.

## Role

Provides the central `./run` runner, containerized runners, and local development harness across all `csi-spl` sibling projects:
- **`csi-spl-api`**: Local test database (`start-api-test-db.sh`), Go build/test orchestration, testkit runners.
- **`csi-spl-iac`**: Terraform runner (`con-spl-tf-runner` / `tfswitch`), tpl-gen config rendering, and plan/apply actions.
- **`csi-spl-wui`**: Node/pnpm dev harness, containerized build, e2e test execution.

## Standard Actions

- `./run do-test-all`: Runs all tests across api, iac, and wui.
- `./run do-api-test-db-start`: Launches local Postgres test instance with schema migrations.
- `./run do-wui-dev`: Launches Nuxt 3 local dev server on port 3000.
- `./run do-tf-plan`: Renders tfvars from `csi-spl-cnf` via `tpl-gen` and plans Terraform resources.
