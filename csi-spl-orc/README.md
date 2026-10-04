# csi-spl-orc

Local dev orchestration (`lde`) for the spool **hub**: Postgres, a GCS
emulator and `spool serve` in docker compose, wired from `csi-spl-cnf` and
nothing else. Shaped like `pas-psf-orc` (compose split -infra / -rdb / -api,
`gen-docker-env`). The lde actions are LOCAL ONLY: they call no gcloud and
no terraform. The few CLOUD actions (below) are owner-gated dry runs by default.
The WUI joins it with `do_wui_up`; `do_lde_up` brings up both. Docker is the
only host tool they need (spec 072 A46): the hub builds inside docker.

| action | what |
|---|---|
| `./run -a do_lde_up` | the whole dev stack: `do_setup_app_inf` + `do_wui_up` (one-shot WUI install, sign-in on), then the URLs |
| `./run -a do_lde_down` | the inverse (`LDE_PURGE=1` also drops the volumes) |
| `./run -a do_setup_app_inf` | build `spool` in docker + the hub image, bring the stack up, smoke it (pg, gcs, migrate, serve, hello) |
| `./run -a do_teardown_app_inf` | `compose down` for this tree (`LDE_PURGE=1` also drops the volumes) |
| `./run -a do_gen_docker_env` | render `compose.env` + `hub.env` from cnf (called by the two above) |
| `./run -a do_provision_spool_root` | make the box's `/var/spool-hub` (cnf `env.box`) with the group-only perms model (017 FR-SEC-001) |
| `./run -a do_repair_spool_root` | migrate an existing box spool to that model: group, members, perms; `DRY_RUN=1` default |

## Cloud actions (dev / prd) -- owner-gated

Mutating cloud actions are a **dry run unless `DRY_RUN=0`**. They read every
name from the effective cnf (`do_spl_cloud_cnf`: the same merge tpl-gen
renders from), and need `GCP_ACCOUNT` (a fail-fast env var, never committed)
only for a real run. Every gcloud call carries `--account`; nothing writes
the shared gcloud or docker config. Nothing here runs terraform: that is
`csi-spl-iac`. `do_spl_wait_for_mapping_cert` is the exception: it is the
wait, so it polls (read-only) until the 032 mapping cert is provisioned.

| action | what |
|---|---|
| `ENV=dev ./run -a do_build_push_hub_image` | build the hub image as cnf `hub.image.ref` (the image 030 runs); `DRY_RUN=0` pushes it to the 028 registry |
| `ENV=dev DOMAIN=<host> ./run -a do_spl_wait_for_mapping_cert` | poll a 032 Cloud Run domain mapping until `CertificateProvisioned=True` (not a dry-run: this IS the wait). Runs as the env SA from its key. Replaces the 031-era `do_wait_for_cert` (retired with the load balancer, 007 T090) |
| `ENV=dev ./run -a do_export_all_dns_settings` | snapshot Cloud DNS zones + record-sets to JSON under the env's cloud state dir; `DRY_RUN=1` default |
| `TEST_DOMAIN=example.test ./run -a do_flush_dns` | flush the operator host resolver cache; `DRY_RUN=1` default (the real run sudo-mutates the host) |

## Gandi LiveDNS (public DNS)

Public NS stay on Gandi LiveDNS. These actions talk to Gandi's v5 API
(`GANDI_API_BASE`, default their public host), never to Cloud DNS. Domain
is `$DOMAIN` or cnf `env.dns.BASE_DOMAIN`. Token: `GANDI_PAT` or
`$HOME/.gandi/.<org>/token` (mode 600). Record writes are dry-run unless
`CONFIRM=yes`. `do_gandi_set_nameservers` is dry-run **only** and refuses
`ns-cloud-*`. Apex `@` A/AAAA/CNAME is refused (Gandi parking).

| action | what |
|---|---|
| `./run -a do_gandi_check_creds` | prove the token lists domains |
| `./run -a do_gandi_get_nameservers` | read registrar NS |
| `./run -a do_gandi_list_dns_records` | list LiveDNS records |
| `RRSET_NAME=* RRSET_TYPE=A RRSET_VALUES=<ip> ./run -a do_gandi_set_dns_record` | upsert one record (`CONFIRM=yes` to apply) |
| `NAMESERVERS=ns-101-a.gandi.net,... ./run -a do_gandi_set_nameservers` | dry-run only; never re-delegates |

## Where things come from

| thing | source |
|---|---|
| hub env-var names + defaults | `csi-spl-cnf/csi-spl/all.env.yaml` `env.hub.env` |
| lde values (ports, images, local DSN, emulator) | `csi-spl-cnf/csi-spl/lde.env.yaml` |
| schema | `csi-spl-rdb/src/sql/postgres/spool-hub/`, applied by `spool migrate` (bundled into the image) |
| rendered env files | `$HOME/.local/share/csi-spl/lde/<tree>/` (never in git) |

Each git tree gets its own compose project (`csi-spl-lde-<tree>`), volumes and
image tag. Host ports bind 127.0.0.1 only; to run two trees at once, override
`LDE_PG_PORT`, `LDE_GCS_PORT`, `LDE_HUB_PORT`.

## Exit codes of do_setup_app_inf

`0` every check PASS; `3` nothing failed but a check is BLOCKED (the hub
binary on this tree lacks a verb, e.g. `serve`, which the 003 hub lane ships);
`1` a check FAILED. BLOCKED is never counted as green.

## /var/spool-hub permissions model

Spec 017 FR-SEC-001 (local mail is unsigned, so the spool is closed to every
OS user outside its group): group `spool-agents` (cnf
`env.box.spool_root_group`), mode `2770` (setgid, **not** sticky: `recv --ack`
renames a message another user wrote), ACLs `u/g rwx`, `o ---` (cnf
`env.box.spool_root_other`), access and default, on the root and every subdir;
files are `rw`, never `x`. So an inbox created by one member under umask 022
stays writable for the other members and unreachable for everyone else.

**Who joins the group:** every OS user that runs an agent (the harness user
the spawned agents run as) and every user that reads or writes the spool (the
box owner). A running process keeps the groups it started with, so each member
restarts its agents / re-logs in after joining.

`do_provision_spool_root` never creates the group. An existing box migrates
with the named repair action, in a quiet window (no agent mid-send):

```bash
./run -a do_repair_spool_root
```

```bash
DRY_RUN=0 SPOOL_ROOT_MEMBERS="<HARNESS_USER> <DEV_USER>" ./run -a do_repair_spool_root
```

The first is the default dry run (current state + the exact root commands);
the second creates the group, adds the members, re-groups the tree, sets
setgid on every dir, applies the ACLs and proves `nobody` can neither list nor
write the root. Until then `do_provision_spool_root` leaves an existing root
as it is, with a WARN. `do_setup_app_inf` runs it only with `LDE_SPOOL_ROOT=1`.

## Tests

`bash src/bash/tests/run-all-tests.sh`
