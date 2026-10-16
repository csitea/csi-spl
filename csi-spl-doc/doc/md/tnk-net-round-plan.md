# Networking round: multi-uplink auto-switching & agent continuity (10 actions)

Owner HUM-10, t1 topic `06871e35-9873-46f1-8bee-2fe8ed8570e7` (opened from `eb4bd4b3` msgs `f3558c0f` + `89eaab70`):
- `f3558c0f`: "Create a new discussion which should focus on the configuration of the box to have multiple VLANs opened to be able to switch networks automatically."
- `d29d53b4` (verbatim excerpt): "I have the box, which is just a Lenovo laptop, a little bit better one. The problem is that the network is dropping. I have two VLAN phones, and I'm about to probably buy a SpaceX antenna. I will have access to some VLANs from time to time, so we need a panel and discussion on how to configure the networking on the box. I'm kind of moving pretty often from place to place, and I usually drop one of the phones next to the laptop. We need to have a discussion on what kind of a harness we should do on Debian 13, on which the machine is operating. Whenever I have two VLANs within reach to which the laptop does have access, it will automatically know how to switch."
- `d609d0e9` (verbatim, owner addition): "And, of course, how this network switch will affect the agents (aka, we must ensure that the agents will 'know' the new network and they will be able to use the new network)."
- Dispatcher's reading (`9d9bd690`): "VLAN" = Wi-Fi network (WLAN) / network uplink; the machine is a laptop that moves; one built-in Wi-Fi radio joins one network at a time, so concurrent links for instant failover require a second physical link (USB tether from the phone, secondary USB Wi-Fi dongle, or Starlink / router Ethernet on the wired port).

Consensus: rounds need no owner go (rulebook 1.4: consensus, then build, no second go).
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, R1–R16) by pointer.
Issue: SPL-2109.
Editor: **a-271@sat** (agy).
Target box: **PC** (the Debian 13 laptop).

**Status: v0.1 draft**. Submitted to expert panel seats for verification, review, and signing.

## 1. Measured facts on the laptop box (baseline)

Measured on the laptop box by `c-001@PC` (read-only probe, 2026-10-16 ~04:0xZ, n=1):
- **Current active uplink:** Single Wi-Fi uplink (Intel `iwlwifi`), one DHCP default route (`default via <gateway> dev <wlan> proto dhcp src <ip> metric 600`).
- **Wired port:** Built-in Intel `e1000e` Gigabit NIC present, carrier down (no cable plugged). Connection profile exists but has `connection.autoconnect-priority = -999`, preventing auto-takeover on link up.
- **Secondary uplinks:** No USB tethering device attached, no secondary USB Wi-Fi dongle, no WWAN modem.
- **NetworkManager configuration:** `NetworkManager.conf` has only `[main] plugins=ifupdown,keyfile` and `[ifupdown] managed=false`. `/etc/NetworkManager/conf.d/` is empty: **NO connectivity check is configured**; Wi-Fi power save is unconfigured (`default` = enabled).
- **Saved profiles:** 6 saved Wi-Fi profiles; only 1 is in range at the current location.
- **Wi-Fi drop frequency:** 11 Wi-Fi beacon losses / disconnects logged in the preceding 6 hours.
- **Recent outage impact:** At 03:41:37Z..03:44:25Z (2 min 48 s), a Wi-Fi disconnect triggered the spec 102 §10.2 fence (the box fenced itself after 120 s with no hub heartbeat ack, stopping local agent execution until connectivity returned at 03:44:36Z).
- **Agent fleet isolation:** 32 docker `veth*` and bridge links active on the box hosting agent containers. The harness must strictly touch host uplinks and not perturb Docker internal bridge routing.

## 2. Technical sources (Debian 13 / NetworkManager)

Every proposal in this plan is backed by verified Debian 13 (Trixie) man pages, kernel documentation, and NetworkManager specifications:
1. `NetworkManager.conf(5)`:
   - `[connectivity]` section: `uri`, `interval`, `response`. Periodic background HTTP check determining whether an active interface has real internet access (`CONNECTIVITY_FULL`) or a captive portal / dead gateway (`CONNECTIVITY_LIMITED` / `CONNECTIVITY_NONE`).
   - `[connection]` section: `wifi.powersave=2` (disables 802.11 power saving; 0: default, 1: ignore, 2: disable, 3: enable).
2. `nm-settings(5)` & `nmcli(1)`:
   - `connection.autoconnect-priority`: Priority integer between -999 and 999. Higher priority connects first.
   - `ipv4.route-metric` / `ipv6.route-metric`: Kernel route metric. Lower metric is preferred in the Linux routing table.
   - `connection.interface-name` / `match.interface-name`: Device wildcard matching for dynamic USB tethering devices (`usb*`, `enx*`).
3. `NetworkManager-dispatcher(8)`:
   - Dispatcher scripts in `/etc/NetworkManager/dispatcher.d/` triggered asynchronously on network events: `up`, `down`, `connectivity-change`.
   - Environment variables: `$1` (interface), `$2` (action), `$CONNECTIVITY_STATE`.
4. `tcp(7)`, `ss(8)`, `ip-route(8)`:
   - Kernel sysctl `net.ipv4.tcp_retries2 = 6`: drops dead TCP connection timeouts from default 15 minutes (~900 s) to ~15-20 s.
   - `TCP_USER_TIMEOUT` (RFC 5482) and `ss -K`: immediate termination of sockets bound to an invalid/dead local IP when default route moves.
5. `systemd-resolved(8)` / `resolv.conf(5)` & Docker daemon networking:
   - Dynamic DNS uplink tracking over `127.0.0.53` and fallback resolver list in `/etc/docker/daemon.json` (`["1.1.1.1", "8.8.8.8"]`).

## 3. The 10 actions

Every row is a named csi-rel action (`do_<verb>_<noun>`, `csi-spl-orc`) plus its test, executed on `PC` by a `PC`-pinned build lane.

| # | slug | practice | why | target & proof | csi-rel action & test | box | vendor | batch |
|---|---|---|---|---|---|---|---|---|
| 01 | `feat(net-01-powersave-off)` | Wi-Fi power save disabled | 11 beacon losses in 6 h caused by 802.11 power saving sleep cycles on Intel iwlwifi | `Power save: off` verified on Wi-Fi interface; 0 sleep drops across 24 h | `do_net_powersave_off`<br>`csi-spl-orc/src/bash/tests/net-powersave-off.tst.sh` | PC | mistral | Batch 1 (Lane 1) |
| 02 | `feat(net-02-connectivity-check)` | NM connectivity check | Without periodic check, NM cannot distinguish "associated with AP" from "has internet", so dead WAN never triggers switch | `nmcli networking connectivity check` returns `full` on valid link, detects outage within 10 s | `do_net_connectivity_check`<br>`csi-spl-orc/src/bash/tests/net-connectivity-check.tst.sh` | PC | claude | Batch 1 (Lane 2) |
| 03 | `feat(net-03-wired-priority)` | Wired port auto-takeover | Built-in e1000e NIC profile has autoconnect-priority -999; cable insert does not take over default route | `autoconnect-priority = 100`, `route-metric = 100`; cable insert takes default route within 2 s | `do_net_wired_priority`<br>`csi-spl-orc/src/bash/tests/net-wired-priority.tst.sh` | PC | claude | Batch 2 (Lane 1) |
| 04 | `feat(net-04-usb-tether-profiles)` | USB tethering autoconnect | Moving laptop with phone next to it needs plug-and-play USB cable tether as instant secondary uplink | USB tether profile matches `usb*`/`enx*`; priority 50, metric 200; activates on plug in < 3 s | `do_net_usb_tether_profiles`<br>`csi-spl-orc/src/bash/tests/net-usb-tether-profiles.tst.sh` | PC | mistral | Batch 2 (Lane 2) |
| 05 | `feat(net-05-wlan-ladder)` | Wireless metric & priority ladder | Multiple saved Wi-Fi profiles conflict without a strict autoconnect priority ladder | Primary Wi-Fi (metric 600, prio 10) > Phone A (metric 700, prio 8) > Phone B (metric 710, prio 7) | `do_net_wlan_ladder`<br>`csi-spl-orc/src/bash/tests/net-wlan-ladder.tst.sh` | PC | mistral | Batch 3 (Lane 1) |
| 06 | `feat(net-06-wan-watchdog)` | Silent blackhole WAN watchdog | AP remains associated but router WAN drops: kernel default route blackholes traffic | Watchdog / dispatcher raises metric +1000 when ping/HTTP fails for 15 s; switches route in < 20 s | `do_net_wan_watchdog`<br>`csi-spl-orc/src/bash/tests/net-wan-watchdog.tst.sh` | PC | claude | Batch 3 (Lane 2) |
| 07 | `feat(net-07-dns-resilience)` | DNS resolver continuity for fleet | Stale DHCP nameservers on link switch cause 30-60 s DNS lookup timeouts inside 32 Docker agent containers | Docker daemon fallback DNS (`1.1.1.1`) + cache flush on switch; container DNS resolves in < 100 ms | `do_net_dns_resilience`<br>`csi-spl-orc/src/bash/tests/net-dns-resilience.tst.sh` | PC | claude | Batch 4 (Lane 1) |
| 08 | `feat(net-08-beat-continuity)` | Hub beat anti-fence guard | Spec 102 §10.2: box fences itself after 120 s with no beat ack; 03:41Z drop fenced box for 2 min 48 s | Immediate beat trigger on route switch + fast 3 s backoff; max beat gap < 25 s (0 fence events) | `do_net_beat_continuity`<br>`csi-spl-orc/src/bash/tests/net-beat-continuity.tst.sh` | PC | mistral | Batch 4 (Lane 2) |
| 09 | `feat(net-09-agent-conn-resilience)` | Agent CLI fast reconnect & TCP timeout | When IP changes, open TCP sockets to model APIs / git hang for 15 min in ESTABLISHED state | `tcp_retries2 = 6`, `ss -K` on stale IP, `http.lowSpeedLimit`; CLIs detect drop and reconnect in < 5 s | `do_net_agent_conn_resilience`<br>`csi-spl-orc/src/bash/tests/net-agent-conn-resilience.tst.sh` | PC | claude | Batch 5 (Lane 1) |
| 10 | `test(net-10-failover-drill)` | End-to-end failover drill | Need empirical proof that total link loss switches seamlessly, avoids fence, and keeps agents live | Automated drill: failover < 30 s, 0 fences, 100% of live agents ($n$) make model call & spool send | `do_net_failover_drill`<br>`csi-spl-orc/src/bash/tests/net-failover-drill.tst.sh` | PC | claude | Batch 5 (Lane 2) |

## 4. Detailed row specifications

### Row 01: `feat(net-01-powersave-off)` - Wi-Fi power save disabled
- **What:** Create `/etc/NetworkManager/conf.d/20-wifi-powersave-off.conf`:
  ```ini
  [connection]
  wifi.powersave = 2
  ```
  and apply runtime setting `iw dev <wlan> set power_save off`.
- **Why:** The Intel `iwlwifi` driver drops association (BEACON-LOSS) when 802.11 power saving enters low power states during short idle periods. 11 disconnects were logged in 6 hours.
- **Command:** `iw dev $(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi"{print $1}') get power_save`
- **Target:** `Power save: off`.
- **Proof:** Zero power-save-induced beacon losses; configuration persists across `NetworkManager` restarts and reboots.

### Row 02: `feat(net-02-connectivity-check)` - NetworkManager connectivity check
- **What:** Create `/etc/NetworkManager/conf.d/30-connectivity.conf`:
  ```ini
  [connectivity]
  uri = http://network-test.debian.org/nm
  interval = 10
  response = NetworkManager is online
  ```
- **Why:** `NetworkManager` on the machine has an empty `conf.d/`. Without a connectivity check, the OS cannot detect when an AP has lost internet backhaul, keeping a dead default route indefinitely.
- **Command:** `nmcli networking connectivity check`
- **Target:** Transitions to `limited` or `none` within 10 seconds of internet loss.
- **Proof:** Outage detection within 10 s; recovers to `full` within 10 s of backhaul restoration.

### Row 03: `feat(net-03-wired-priority)` - Wired Ethernet auto-takeover
- **What:** Configure the `e1000e` Ethernet connection profile:
  ```bash
  nmcli connection modify "<wired-profile>" connection.autoconnect yes connection.autoconnect-priority 100 ipv4.route-metric 100 ipv6.route-metric 100
  ```
- **Why:** Today the wired connection has `autoconnect-priority = -999`. When an Ethernet cable (from a local switch or future Starlink terminal) is connected, the machine leaves Wi-Fi as the default route.
- **Command:** `nmcli -f connection.autoconnect-priority,ipv4.route-metric connection show "<wired-profile>"`
- **Target:** `connection.autoconnect-priority: 100`, `ipv4.route-metric: 100`.
- **Proof:** Plugging in cable immediately installs kernel route with metric 100, preempting Wi-Fi (metric 600) in < 2 seconds.

### Row 04: `feat(net-04-usb-tether-profiles)` - USB tethering autoconnect
- **What:** Create a persistent connection profile `/etc/NetworkManager/system-connections/usb-tether.nmconnection`:
  ```ini
  [connection]
  id = usb-tether
  type = ethernet
  match-device = interface-name:usb*,interface-name:enx*
  autoconnect = yes
  autoconnect-priority = 50

  [ipv4]
  method = auto
  route-metric = 200

  [ipv6]
  method = auto
  route-metric = 200
  ```
- **Why:** Connecting a phone via USB provides a dedicated physical network interface without competing for the single Wi-Fi radio. A moving laptop user can drop the phone next to the laptop and plug in a USB cable to get an instant backup uplink.
- **Command:** `nmcli connection show usb-tether`
- **Target:** Interface acquires DHCP lease and metric 200 within 3 seconds of USB connection.
- **Proof:** Default route `default via <phone-ip> dev usb0 metric 200` automatically appears above Wi-Fi (metric 600).

### Row 05: `feat(net-05-wlan-ladder)` - Wireless metric & priority ladder
- **What:** Set deterministic priorities and route metrics on all saved Wi-Fi profiles:
  - Primary location Wi-Fi ("the home Wi-Fi"): priority `10`, route-metric `600`.
  - Phone A hotspot: priority `8`, route-metric `700`.
  - Phone B hotspot: priority `7`, route-metric `710`.
  - Secondary/travel Wi-Fi profiles: priority `5`, route-metric `750`.
  - Set `connection.autoconnect = no` on stale/unused SSIDs.
- **Why:** Without explicit priorities, NetworkManager selects Wi-Fi networks arbitrarily based on signal strength or history, causing connection thrashing between the home network and phone hotspots.
- **Command:** `nmcli -f NAME,AUTOCONNECT-PRIORITY,IP4-METRIC connection show`
- **Target:** Clear ladder with zero SSID names exposed in public files.
- **Proof:** Kernel routing table maintains exact ladder: Wired (100) > USB Tether (200) > Primary Wi-Fi (600) > Phone Hotspots (700..710).

### Row 06: `feat(net-06-wan-watchdog)` - Silent blackhole WAN watchdog
- **What:** Deploy NetworkManager dispatcher script `/etc/NetworkManager/dispatcher.d/90-wan-watchdog.sh` and health checker timer:
  - If interface is in `connectivity-change` with status `limited` or `none`, or fails 3 consecutive external health probes (HTTP to hub API, ICMP to `1.1.1.1`):
  - Increase the dead interface's route metric by +1000 (`ip route change ... metric 1600`) to force kernel failover to the next metric route.
  - Automatically revert metric when connectivity check returns `full`.
- **Why:** If the Wi-Fi AP remains powered on but its WAN connection drops, standard link-state monitoring sees the interface as UP and traffic blackholes.
- **Command:** `bash csi-spl-orc/src/bash/run/net-wan-watchdog.func.sh --status`
- **Target:** Failover executed in < 15 seconds of WAN drop; restored within 10 seconds of recovery.
- **Proof:** Blackhole test triggers metric adjustment and routes traffic through alternate link.

### Row 07: `feat(net-07-dns-resilience)` - DNS resolver continuity for fleet
- **What:**
  1. Configure `systemd-resolved` with fallback DNS:
     ```ini
     [Resolve]
     FallbackDNS = 1.1.1.1 8.8.8.8
     ```
  2. Configure `/etc/docker/daemon.json`:
     ```json
     {
       "dns": ["1.1.1.1", "8.8.8.8"]
     }
     ```
  3. Dispatcher script flushes DNS cache (`resolvectl flush-caches`) on default route changes.
- **Why:** When switching from Wi-Fi to USB tethering, the local DNS server IP changes (e.g. from `192.168.1.1` to `192.168.42.129`). Docker containers caching the old DNS server hang for 30–60 s on DNS resolution timeouts.
- **Command:** `docker exec $(docker ps -q | head -1) getent hosts api.anthropic.com`
- **Target:** DNS lookup resolves within < 100 ms immediately after network switch.
- **Proof:** DNS resolution verified inside live agent container during uplink switch.

### Row 08: `feat(net-08-beat-continuity)` - Hub beat anti-fence guard
- **What:**
  - Update `do_spl_box_beat` daemon logic: hook into route change events via netlink or dispatcher poke (`/var/run/spl/box-beat.poke`).
  - Upon route change, immediately trigger a box heartbeat instead of waiting for the next 30 s tick.
  - Set request timeout to 5 s with a 3 s retry loop on failure.
- **Why:** Spec 102 §10.2: the machine fences itself if it receives no hub beat ack for 120 s. The 03:41Z drop lasted 2 min 48 s, fencing the box and terminating running lanes.
- **Command:** `SPOOL_BOX_BEAT_DRY=1 bash csi-spl-orc/src/bash/run/spl-box-beat.func.sh`
- **Target:** Hub beat acknowledged within < 15 s of switch; max beat gap during failover < 25 s (0 fence events).
- **Proof:** Beat continuity logged throughout drill; zero fence states triggered.

### Row 09: `feat(net-09-agent-conn-resilience)` - Agent CLI fast reconnect & TCP timeout
- **What:**
  1. Set kernel sysctl parameters in `/etc/sysctl.d/99-net-retries.conf`:
     ```ini
     net.ipv4.tcp_retries2 = 6
     net.ipv4.tcp_keepalive_time = 30
     net.ipv4.tcp_keepalive_intvl = 5
     net.ipv4.tcp_keepalive_probes = 3
     ```
  2. In dispatcher script `/etc/NetworkManager/dispatcher.d/98-kill-dead-sockets.sh`:
     Execute `ss -K -t "dport = :443 or dport = :80"` against sockets whose local address is the old interface IP.
  3. Set global git timeout:
     ```bash
     git config --system http.lowSpeedLimit 1000
     git config --system http.lowSpeedTime 10
     ```
- **Why:** Owner addition (`d609d0e9`): An IP change breaks open TCP connections. Linux defaults keep dead sockets in `ESTABLISHED` for up to 15 minutes before timeout, causing model API calls in agent CLIs (Claude, Mistral, Agy) to hang indefinitely.
- **Command:** `sysctl net.ipv4.tcp_retries2 net.ipv4.tcp_keepalive_time`
- **Target:** Dead sockets aborted in < 5 seconds; CLI wrappers catch connection reset and immediately reconnect via the new interface.
- **Proof:** Simulated route change aborts lingering socket; agent CLI retry loop resumes without human intervention.

### Row 10: `test(net-10-failover-drill)` - End-to-end failover drill
- **What:** Implement the end-to-end drill action `do_net_failover_drill`:
  1. Record baseline network state and list of live agents ($n$ live containers on `PC`).
  2. Disconnect active primary uplink (simulated cable unplug or Wi-Fi beacon loss).
  3. Measure failover stopwatch: time until secondary default route is active and hub ping/HTTP succeeds.
  4. Verify zero fence conditions triggered (hub beat delivered within < 30 s).
  5. Query every live agent container on `PC` to execute a model API call and spool send over the new network.
  6. Reconnect primary uplink and measure recovery time (< 15 s).
- **Why:** Rigorous empirical proof that all requirements are met: failover under 30 s, zero fencing, and 100% agent continuity ($n$ of $n$).
- **Command:** `cd csi-spl-orc && ./run -a do_net_failover_drill`
- **Target:** Failover < 30 s (aim < 15 s, far below 120 s fence); 100% of live agents verified operational.
- **Proof:** Drill report detailing exact seconds, route changes, beat timestamps, and verified agent responses.

## 5. Owner addition: agent fleet continuity (d609d0e9)

The owner required: *"And, of course, how this network switch will affect the agents (aka, we must ensure that the agents will 'know' the new network and they will be able to use the new network)."*

The plan addresses this through four specific mechanisms:
1. **Socket Eviction & Fast Reset (Row 09):** When an uplink switch changes the outbound IP, existing TCP connections to Anthropic, Google, and OpenAI APIs enter a blackhole state. System-wide TCP retry reduction (`tcp_retries2 = 6`) and dispatcher socket eviction (`ss -K`) immediately terminate dead connections within 2 s instead of hanging for 15 minutes.
2. **Container DNS Refresh (Row 07):** Docker bridge containers (`veth*`) inherit fallback public resolvers (`1.1.1.1`, `8.8.8.8`) in `daemon.json`, avoiding reliance on local router DHCP resolvers that become unreachable on network change.
3. **Heartbeat Continuity (Row 08):** Hub beat probes dispatch immediately on route change, preventing the 120 s silence window that triggers box fencing.
4. **Empirical Agent Proof in Drill (Row 10):** The failover drill explicitly counts every live agent container ($n$) on `PC` and requires a verified model API call and spool send on the new network before passing.

## 6. Execution batches & disjoint files (R1)

All files modified by the 10 rows are completely disjoint across the repository:

- **Batch 1 (Lane 1 & Lane 2):**
  - Row 01: `/etc/NetworkManager/conf.d/20-wifi-powersave-off.conf`, `csi-spl-orc/src/bash/run/net-powersave-off.func.sh`, `csi-spl-orc/src/bash/tests/net-powersave-off.tst.sh`
  - Row 02: `/etc/NetworkManager/conf.d/30-connectivity.conf`, `csi-spl-orc/src/bash/run/net-connectivity-check.func.sh`, `csi-spl-orc/src/bash/tests/net-connectivity-check.tst.sh`
- **Batch 2 (Lane 1 & Lane 2):**
  - Row 03: `csi-spl-orc/src/bash/run/net-wired-priority.func.sh`, `csi-spl-orc/src/bash/tests/net-wired-priority.tst.sh`
  - Row 04: `/etc/NetworkManager/system-connections/usb-tether.nmconnection`, `csi-spl-orc/src/bash/run/net-usb-tether-profiles.func.sh`, `csi-spl-orc/src/bash/tests/net-usb-tether-profiles.tst.sh`
- **Batch 3 (Lane 1 & Lane 2):**
  - Row 05: `csi-spl-orc/src/bash/run/net-wlan-ladder.func.sh`, `csi-spl-orc/src/bash/tests/net-wlan-ladder.tst.sh`
  - Row 06: `/etc/NetworkManager/dispatcher.d/90-wan-watchdog.sh`, `csi-spl-orc/src/bash/run/net-wan-watchdog.func.sh`, `csi-spl-orc/src/bash/tests/net-wan-watchdog.tst.sh`
- **Batch 4 (Lane 1 & Lane 2):**
  - Row 07: `/etc/docker/daemon.json`, `/etc/systemd/resolved.conf.d/fallback.conf`, `csi-spl-orc/src/bash/run/net-dns-resilience.func.sh`, `csi-spl-orc/src/bash/tests/net-dns-resilience.tst.sh`
  - Row 08: `csi-spl-orc/src/bash/run/net-beat-continuity.func.sh`, `csi-spl-orc/src/bash/tests/net-beat-continuity.tst.sh`
- **Batch 5 (Lane 1 & Lane 2):**
  - Row 09: `/etc/sysctl.d/99-net-retries.conf`, `/etc/NetworkManager/dispatcher.d/98-kill-dead-sockets.sh`, `csi-spl-orc/src/bash/run/net-agent-conn-resilience.func.sh`, `csi-spl-orc/src/bash/tests/net-agent-conn-resilience.tst.sh`
  - Row 10: `csi-spl-orc/src/bash/run/net-failover-drill.func.sh`, `csi-spl-orc/src/bash/tests/net-failover-drill.tst.sh`

## 7. Panel consensus & signatures

| Seat | Vendor | Agent ID | Status | Signature SHA |
|---|---|---|---|---|
| Editor | agy | a-271@sat | Proposed v0.1 | Pending |
| Expert 1 | claude | Pending placement | Pending review | Pending |
| Expert 2 | mistral | Pending placement | Pending review | Pending |

Once all panel seats sign the v1.0 sha, row lanes spawn automatically without waiting for owner approval (rounds-rulebook.md §1.4).
