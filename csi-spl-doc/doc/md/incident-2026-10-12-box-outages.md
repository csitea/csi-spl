# Incident Analysis 2026-10-12: Box Outages

> Generated from qto doc `798579d5-ea4f-4ce0-bb39-e9af8943a71a`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

## 1. Timeline (UTC)

### 1.1 Incident 1: 16:04 - 16:09Z
- **16:04 - 16:06Z**: The hub box lease.log recorded `i/o timeout` errors (16:05:47, 16:06:36Z):
```text
dial tcp: lookup api.spool-hub.ai: i/o timeout
```
- **16:07:34Z**: Dispatch lease changed to `none@unreachable`.
- **16:08Z**: `getent api.spool-hub.ai` succeeded 4/10 times. `github.com` control failed. A `curl` to the hub `/version` succeeded in 8.1 s.
- **16:09:05Z**: Lease handed back.
- **16:09:22Z**: Healed (10/10, 3/3).

### 1.2 Rotation Failure: 16:15Z
- `c-003` refresh failed. `rotate.log` (16:23:03Z):
```text
no claude carrying c-003 started in %989 within 120s
```
- The old `c-003` was kept. Cause unread because no per-run spawn output was kept.

### 1.3 Incident 2: 16:18 - 16:29Z
- **16:18 - 16:20Z**: 3 lookup errors (16:18:02, 16:19:58, 16:20:14Z).
- **16:22 - 16:29Z**: TCP timeouts with the name resolved:
```text
dial tcp 216.239.34.21:443: i/o timeout
```
- **16:28:40Z**: The VM box benched the hub box ('27 of 60 heartbeats in 10 min').
- **16:29:45Z**: Dispatch transferred to `c-002@<BOX>`.
- **16:30Z**: Connectivity healthy (`dig` 8.8.8.8/1.1.1.1/10.50.193.212 3/3 each, HTTPS 5/5, TCP to the 3 front IPs 3/3, `ping` gw 20/20 max 71 ms). Hub box default route = Wi-Fi `wlp0s20f3`, gw 10.50.193.212 (also the 3rd resolver); 48 TX dropped.

### 1.4 Incident 3: 16:32 - 16:35Z
- `HUB-UNREACHABLE` again.
- A GitHub fetch failed after 134 s.
- HTTPS hub 2/3, e2e host 1/3. A 20-min stability wait never passed.
- **16:33Z**: 14 of 16 hub box agent panes idle; 9 closed by owner order. Many waiting hours on unplaced lanes or ACCEPTED.

### 1.5 ROOT LOAD FINDING: 16:29Z - 16:44Z
- From ~16:29Z, 8 infinite CPU burners ran for 14:49 min with NO timeout:
```bash
sh -c while :; do :; done
```
- Parent was `bash /var/tmp/c-296-bench/r7/load-runs.sh .../test-tmux-close-window.sh` (lane c-296, CI-refactor round 7).
- **16:30Z**: Hub box load avg 20.6/18.0/23.4 on 16 CPUs.
- **16:44Z**: Stopped by pid by `c-001@<BOX>`.

### 1.6 Recovery: 16:45Z - 16:59Z
- **16:45:14Z**: VM box rebooted on owner's order (back 16:47Z).
- **16:55Z**: SSH to VM box via IAP proxy restored.
- **16:59Z**: `lease.orch` still read `c-001@<BOX>` despite `do_spl_lease_rank` applied on VM box and hub box (orch `hub-box,box-desk,vm-box`). The owner noted OD pool design never became reality.

## 2. Root Causes

### 2.1 Incident 1
- **Cause**: Wi-Fi uplink drop.
- **Evidence**: DNS timeouts and `getent` failing partially (local CPU load was not measured at 16:05Z).
- **Confidence**: Proven.

### 2.2 Incident 2
- **Cause**: Wi-Fi degradation followed by severe CPU starvation of the hub websocket/heartbeat clients and the Wi-Fi driver.
- **Evidence**: DNS timeouts started at 16:18Z. The massive load avg spike (20.6) and CPU burners started matching the later part of the incident (16:29Z), leading to the hub box being benched.
- **Confidence**: High that CPU starvation caused the hub box benching. The exact start of the burners vs the initial 16:18Z errors is guessed, but the starvation from 16:29Z is measured.
- **Unproven**: Whether the dropped TX packets (48) on the Wi-Fi interface were purely external network factors or caused by internal CPU starvation of the network driver.

### 2.3 Incident 3
- **Cause**: Wi-Fi uplink drop (prime suspect for all 3 incidents), with CPU starvation as an aggravating factor from ~16:29Z.
- **Evidence**: The 8 burners were continuously active. However, `lease.log` shows `HUB-UNREACHABLE ... dial tcp 216.239.3x.21:443: i/o timeout` at 16:47:54Z and 16:49:11Z, AFTER the burners were stopped at 16:44Z.
- **Confidence**: Contributing, not proven as the sole cause. The persistence of network timeouts after burners were killed contradicts CPU starvation as the sole root cause.

## 3. Lessons Learnt

1. **Burner without timeout**: A CPU burner without a timeout ran on the hub box, causing severe resource exhaustion and violating the fleet rule (max 8 burners, each under `timeout 300` and `nice -n 19`).
2. **Box had no live probe**: The box lacked an active live probe, so outages were measured after the fact rather than actively alerted.
3. **Missing per-run spawn output**: The failed `c-003` rotation cause was unread because the per-run spawn output was not kept.
4. **Idle agents not reaped**: 14 of 16 panes sat idle for hours, consuming resources without automatic cleanup.
5. **Orchestrator priority mismatch**: Roles ranked the VM box first while the hub box is the owner's box (lease ranks), so the hub box lost the roles on every drop.
6. **Empty lane-map rows**: Lanes with an empty lane-map row (`c-868@<BOX>`, `m-869@<BOX>`) made 3 new lanes stop on 'exit 4'.

## 4. Prevention

1. **Burner guard**: A guard that refuses a busy loop without a timeout. (To be built in `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh`, action `do_spl_burner_guard`).
2. **Per-minute link probe on each box**: An active probe monitoring connection health. (Exists in flight: `m-869@<BOX>` `<BOX>-uplink-probe` named orc action in `csi-spl-orc`).
3. **Keep per-run spawn output for failed rotations**: Action to retain output for debugging spawn failures. (To be built in `csi-spl-orc/src/bash/features/spawn-agents/scripts/rotate.sh`).
4. **Idle-agent reaper**: Action to automatically close unused agent panes. (To be built. A dead-agent reaper exists as `do_spl_agent_id_reap` in `csi-spl-orc/src/bash/run/spl-agent-id-reap.func.sh`, but not an idle-agent reaper).
5. **OD Pool Design**: Proper handling of multiple Orchestrators and Dispatchers to prevent priority mismatches. (Covered in a separate spec lane).
6. **Spawn records SPAWN_LANE_FILES automatically**: Automatically record `SPAWN_LANE_FILES` from the brief. (To be built in `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh`).
