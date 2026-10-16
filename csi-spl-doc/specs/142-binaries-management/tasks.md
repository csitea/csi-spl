# 142 tasks: binaries management, the build rows

Spec: [spec.md](spec.md). Issue: SPL-2271. In order; each row is one small
lane with its own test and a red control (a planted defect the test must
catch, run on a throwaway branch, never on trunk). Rows are disjoint by
file. "Box change" = the row changes a box when it runs: **those need the
owner's go per box** (PC and sat separately). Every other row only lands
code or files in git.

Paths: `iac/` = `csi-spl-iac/`, `orc/` = `csi-spl-orc/`.

| row | what | files | test + red control | box change |
|---|---|---|---|---|
| B1 | The manifests, backfilled from the spec's section 2 | `iac/cnf/box-pkgs/{pc,satellite}.tsv`, `iac/cnf/box-pkgs/base-{pc,satellite}.txt` | `iac/src/bash/tests/box-pkgs-manifest.tst.sh`: 7 columns, fixed kinds, `needed_by` never empty, every `installed_by` resolves to a role dir or a `do_*` function, every `satellite-replica.tsv` tool has a row. Red: a row with an empty `needed_by`; a row naming `do_no_such_action` | no (the base lists are read with `apt-mark showmanual`, read-only) |
| B2 | `do_box_pkg_flag`, the pure takeover check + the service map in cnf | `iac/src/bash/run/box-pkg-flag.func.sh`, cnf `env.box.pkg_services` (`csi-spl-cnf/csi-spl/all.env.yaml`) | `box-pkg-flag.tst.sh` with fixtures: the PC 10-16 simulation (`Inst systemd-resolved`, `Inst libnss-resolve`, owner NetworkManager) -> 2 FLAG lines; the sat probes (owner systemd-resolved) -> 0; a `Remv network-manager` -> 1. Red: drop `libnss-resolve` from the map -> the PC case must go red | no |
| B3 | `do_box_pkg_drift`, read-only | `iac/src/bash/run/box-pkg-drift.func.sh` | `box-pkg-drift.tst.sh`, stubbed `apt-mark` / journal / bin dirs: an unlisted package -> `NOT-IN-MANIFEST` with the journal's agent id; `DRIFT_STRICT=1` -> exit 2. Red: a stub that drops the journal join must lose the agent id | no to land; running it is read-only |
| B4 | `do_box_pkg_install`: simulate, flag + note, snapshot, journal, install, verify, health, auto-undo hook | `iac/src/bash/run/box-pkg-install.func.sh` | `box-pkg-install.tst.sh`, every command stubbed (`apt-get`, `dpkg-query`, `sudo`, `spool-send.sh` through `<X>_SEND`, the SPOOL_TEST guard): the journal intent line exists BEFORE the stubbed install runs; a flagged install sends the note before it; `BOX_PKG_REASON` or `AGENT_ID` empty -> refused; `DRY_RUN=1` never calls the install. Red: move the journal write after the install -> red | **yes, at its first real run per box**: it creates `/var/lib/csi-spl/box-pkg/` and `/var/backups/box-pkg/` (root-owned) |
| B5 | `do_box_pkg_purge`, the undo (or this behaviour added to c-001's action of that name if it landed first) | `iac/src/bash/run/box-pkg-purge.func.sh` | `box-pkg-purge.tst.sh`: replays 10-16 on a temp root (snapshot = the 12:43Z backup's layout, resolv link + nsswitch) -> link restored, `hosts:` without `resolve`; a purge that would remove more than the closure -> refused. Red: skip the nsswitch restore -> red | **yes, every real run** (it purges and restores; the 10-16 case is already undone on PC, so nothing runs there now) |
| B6 | Wire B5 into B4's auto-undo (D5) | `box-pkg-install.func.sh` (B4's file, after B4 landed) | extend `box-pkg-install.tst.sh`: flagged + health red -> purge called once, note carries both lines; `BOX_PKG_AUTO_UNDO=0` -> not called; unflagged + health red -> not called. Red: auto-undo on an unflagged install -> red | no to land (it runs inside B4) |
| B7 | Hints point at the action | `{iac,orc,utl}/lib/bash/funcs/require-bin.func.sh` | `require-bin-hint.tst.sh`: the hint for `jq` and for an unknown name prints `do_box_pkg_install`, never `sudo apt-get install`. Red: one of the 3 copies left on the old hint | no |
| B8 | Seed line + fleet rules index | `orc/src/bash/features/spawn-agents/lib/spawn-core.inc.sh`, `csi-spl-doc/doc/md/fleet-rules-index.md` | `spawn-agents/tests/test-seed-box-pkg.sh`: every vendor's rendered seed holds the line once; `do_check_fleet_rules_drift` green. Red: the line in only the claude seed | no |
| B9 | Daily drift report per box | `orc/src/bash/run/box-pkg-drift-install-cron.func.sh` (the `<x>-install-cron` pattern of `box-disk-sweep-install-cron.func.sh`), listed in `do_install_box_crons` | `box-pkg-drift-install-cron.tst.sh`: the rendered crontab line runs `do_box_pkg_drift` and posts a `note` only when non-empty. Red: post on an empty report | **yes, per box** (crontab) |
| B10 | Satellite playbook reads the manifest (optional) | `iac/src/terraform/060-gcp-vm-satellite/roles/02_os_binaries/` | the B1 test also checks: every `apt` row of `satellite.tsv` with `installed_by=play 02_os_binaries` is in the role's list and back. Red: a package in the role but not in the manifest | **yes, sat, when the playbook is applied** |

Order: B1, B2, B3 (code only, any order among them; B3 and B4 live in iac/, B9 in orc/ because the box crons are there), then B4, B5, B6, then
B7, B8, then B9 and B10. B4..B6 are claude (`complex_coding`); B1, B3, B7
fit `simple_coding`; B8 touches the seed (fleet rule, claude).

## Open points for the dispatcher (none blocks B1..B3)

- O1. D5 auto-undo default on (spec 4): flip to off if the owner prefers a
  note only.
- O2. The backfill rows (the spec's 2.2 PC table + sat python3-pip) get
  `needed_by=unknown (backfill)`; a lane that uses one claims it, or drift
  keeps naming it.

<!-- version: 0.1.0 · updated: 2026-10-17 -->
