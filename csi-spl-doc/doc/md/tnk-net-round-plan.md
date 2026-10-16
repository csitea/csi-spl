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

**Status: v1.0 (consensus)**. Approved by the expert panel (Editor: `a-271@sat`, Claude seat 1: `c-673`, Claude seat 2: `c-719`).

## 1. Measured facts on the laptop box (re-measured baseline)

Empirically verified on `PC` by panel seats `c-673` and `c-719` (Debian 13.5 Trixie, kernel `6.12.90+deb13.1-amd64`, NetworkManager `1.52.1`):
- **Active uplinks:** Primary Wi-Fi (`wlp0s20f3`, Intel `iwlwifi`), one DHCP IPv4 default route (`metric 600`), and a live IPv6 default route (`proto ra metric 600 pref high`). Both families must be managed in parity (Proposal P2).
- **Wired port:** Built-in Intel `e1000e` Gigabit NIC (`enp0s31f6`) present, carrier down (unplugged). The only connection profile is `Wired connection 1`, an in-memory auto-default in `/run/NetworkManager/system-connections/` with `connection.autoconnect-priority = -999` by design (`NM_SETTING_CONNECTION_AUTOCONNECT_PRIORITY_MIN`). NM 1.52.1 defaults Ethernet route metric to `100` and Wi-Fi to `600`.
- **Secondary uplinks (USB tethering):** Modules `rndis_host`, `cdc_ncm`, `cdc_ether`, `ipheth`, and `huawei_cdc_ncm` are present. On Debian 13, `/usr/lib/systemd/network/99-default.link` sets `NamePolicy=keep kernel database onboard slot path` (no `mac`), so a USB tether receives an interface path name (`en...u<port>`), not `usb*` or `enx*`. Matching must use driver matching (`match.driver`), and route metric must be `650` (below Wi-Fi 600) with `connection.metered = yes` to prevent mobile data drain while Wi-Fi is healthy.
- **Wi-Fi power saving:** `/usr/sbin/iw dev wlp0s20f3 get power_save` reads `Power save: on` (`iwlwifi` driver `power_scheme = 2`). Setting `wifi.powersave = 2` explicitly disables 802.11 power saving sleep.
- **NetworkManager connectivity check:** `/etc/NetworkManager/conf.d/` is currently empty. `NetworkManager.conf(5)` CONNECTIVITY SECTION provides a native `+20000` route-metric penalty to devices lacking internet access (`CONNECTIVITY_LIMITED` / `CONNECTIVITY_NONE`). Setting `uri = http://network-test.debian.org/nm`, `interval = 10`, and `timeout = 5` enables automated failover within <= 15 s without requiring a custom watchdog script. Assert `rp_filter != 1` on all uplinks.
- **DNS architecture & residue:** Agents run directly on the host (16 host processes as `<HARNESS_USER>`), not in containers (the 14 Docker containers host test DBs and build infra). `systemd-resolved` was installed during an incident and is currently `inactive` and `disabled`. NetworkManager manages `/etc/resolv.conf` as a symlink to `/run/NetworkManager/resolv.conf` containing public DNS (`8.8.8.8`, `1.1.1.1`). Pinning `dns=default` and `rc-manager=symlink` while masking `systemd-resolved` permanently protects against DNS hijacking (Proposal P1).
- **Outage history:** The 11 beacon losses logged earlier were a single burst event at 06:41Z where the AP disappeared (`ssid-not-found`, mobile hotspot moving or sleeping).
- **Hub heartbeat continuity:** Heartbeat is executed by `spl_wd_beat` in `csi-spl-orc/src/bash/run/spl-watchdog.func.sh` every `WD_TICK = 30` s. The box self-fences after `box_down_min = 2 min` (120 s) with no beat ack. Any failover under `120 - 30 = 90 s` never fences. A dispatcher wake poke on route switch triggers immediate heartbeat check.
- **Agent socket resilience:** Linux kernel 6.12 `tcp_timer.c` shows `tcp_retries2 = 6` equals 25.4 s (below RFC 1122 100 s floor) and only terminates connections with unacknowledged outbound packets in flight; it never drops sockets waiting to read incoming streamed model tokens. Sockets bound to the old IP must be evicted on route switch using `ss -K -t src <old-ip>` (for both IPv4 and IPv6).

## 2. Technical sources (Debian 13 / NetworkManager / Linux kernel)

1. `NetworkManager.conf(5)` (NM 1.52.1-1):
   - `[connectivity]` section: `uri`, `interval` (default 300 s), `timeout` (default 20 s), `response`. Provides native `+20000` metric penalty on unroutable links.
   - `[connection]` section: `wifi.powersave = 2` (disable).
   - `[main]` section: `dns = default`, `rc-manager = symlink`.
2. `nm-settings-nmcli(5)` & `nm-settings-keyfile(5)`:
   - `connection.autoconnect-priority`: Range -999..999.
   - `connection.metered`: Ternary (`yes`, `no`, `unknown`).
   - `match.driver`: Driver wildcard list for device matching (`rndis_host;cdc_ncm;...`).
   - `ipv4.route-metric` & `ipv6.route-metric`: Kernel routing priority (lower wins).
   - `ipv4.dns-options`: `timeout:2,attempts:2`.
3. `systemd.link(5)` & `systemd.net-naming-scheme(7)`:
   - Interface naming scheme under Debian 13 `99-default.link` (`ID_NET_NAME_PATH`).
4. `NetworkManager-dispatcher(8)`:
   - Dispatcher hooks in `/etc/NetworkManager/dispatcher.d/` and `no-wait.d/`.
5. `tcp(7)`, `ss(8)`, `ip-route(8)`:
   - `ss -K`: Kernel socket destroy (`CONFIG_INET_DIAG_DESTROY=y`).
   - `tcp_retries2`: `retransmits_timed_out()` and `tcp_model_timeout()`.
   - `git-config(1)`: `http.lowSpeedLimit`, `http.lowSpeedTime`.
   - `ssh_config(5)`: `ServerAliveInterval`, `ServerAliveCountMax`.
6. Repo sources:
   - `csi-spl-orc/src/bash/run/spl-watchdog.func.sh` (`WD_TICK = 30`, `spl_wd_beat`, `spl_wd_fence`).
   - `csi-spl-api/src/go/spool-hub-api/internal/hub/box_beat.go` (`box_down_min = 2`).

## 3. The 10 actions

Every row is a named csi-rel action (`do_<verb>_<noun>`, `csi-spl-orc`) plus its test, executed on `PC` by a `PC`-pinned build lane.

| # | slug | practice | why | target & proof | csi-rel action & test | box | vendor | batch |
|---|---|---|---|---|---|---|---|---|
| 01 | `feat(net-01-powersave-off)` | Wi-Fi power save disabled | Wi-Fi power save is ON in driver (`power_scheme=2`), causing sleep state latency and potential drops | `/usr/sbin/iw dev <wlan> get power_save` reads `off`; 0 sleep drops across 24 h | `do_net_powersave_off`<br>`csi-spl-orc/src/bash/tests/net-powersave-off.tst.sh` | PC | mistral | Batch 1 (Lane 1) |
| 02 | `feat(net-02-connectivity-check)` | NM connectivity check | Without periodic check, dead WAN keeps default route indefinitely; native NM check adds +20000 metric penalty | `nmcli networking connectivity check` returns `full` on valid link, detects outage within <= 15 s (IPv4 + IPv6) | `do_net_connectivity_check`<br>`csi-spl-orc/src/bash/tests/net-connectivity-check.tst.sh` | PC | claude | Batch 1 (Lane 2) |
| 03 | `feat(net-03-wired-priority)` | Wired Ethernet persistent profile | Auto-default profile is ephemeral; need dedicated persistent profile bound to NIC with explicit metric 100 | Cable insert immediately installs default route with metric 100 (IPv4 + IPv6) in < 2 s, preempting Wi-Fi (600) | `do_net_wired_priority`<br>`csi-spl-orc/src/bash/tests/net-wired-priority.tst.sh` | PC | claude | Batch 2 (Lane 1) |
| 04 | `feat(net-04-usb-tether-profiles)` | USB tethering autoconnect | Debian 13 interface naming misses `usb*`/`enx*`; match by driver (`match.driver`); metric 650 prevents mobile data drain | Tether connects on plug in < 3 s; metric 650 with `metered=yes`; takes over when Wi-Fi drops or gets +20000 | `do_net_usb_tether_profiles`<br>`csi-spl-orc/src/bash/tests/net-usb-tether-profiles.tst.sh` | PC | mistral | Batch 2 (Lane 2) |
| 05 | `feat(net-05-wlan-ladder)` | Wireless priority ladder | Single Wi-Fi radio connects to one SSID at a time; autoconnect priorities govern selection without route metric confusion | Ladder: Home (prio 10) > Hotspot A (8) > Hotspot B (7) > Travel (5); metric 600; hotspots metered | `do_net_wlan_ladder`<br>`csi-spl-orc/src/bash/tests/net-wlan-ladder.tst.sh` | PC | mistral | Batch 3 (Lane 1) |
| 06 | `feat(net-06-dns-pin-and-mask)` | Pin NM DNS mode & mask resolved | Prevent `systemd-resolved` residue from hijacking `/etc/resolv.conf` (caused 22m hub outage); declare native NM DNS | `dns=default`, `rc-manager=symlink`; `systemctl is-enabled systemd-resolved` reads `masked` | `do_net_dns_pin_and_mask`<br>`csi-spl-orc/src/bash/tests/net-dns-pin-and-mask.tst.sh` | PC | claude | Batch 3 (Lane 2) |
| 07 | `feat(net-07-dns-fast-failover)` | Uplink DNS fast failover | Stale DHCP DNS on failover causes lookup stalls; set public resolvers and fast 2 s glibc timeout options on all profiles | `ipv4.dns = 8.8.8.8,1.1.1.1` and `timeout:2,attempts:2` on all profiles; host resolution in < 2 s during switch | `do_net_dns_fast_failover`<br>`csi-spl-orc/src/bash/tests/net-dns-fast-failover.tst.sh` | PC | claude | Batch 4 (Lane 1) |
| 08 | `feat(net-08-beat-continuity)` | Hub beat anti-fence guard | Spec 102 §10.2: box fences after 120 s with no beat ack; failover under 90 s never fences at 30 s watchdog tick | Route change wake poke triggers immediate beat check; beat ack age < 90 s throughout drill; 0 fence events | `do_net_beat_continuity`<br>`csi-spl-orc/src/bash/tests/net-beat-continuity.tst.sh` | PC | mistral | Batch 4 (Lane 2) |
| 09 | `feat(net-09-agent-conn-resilience)` | Fast socket eviction & git timeouts | IP change leaves open sockets hung; `tcp_retries2` does not drop sockets waiting to read; `ss -K` terminates old-IP sockets | `ss -K -t src <old-ip>` (IPv4+IPv6) in dispatcher terminates dead sockets in < 2 s; CLI retry reconnects; git timeouts set | `do_net_agent_conn_resilience`<br>`csi-spl-orc/src/bash/tests/net-agent-conn-resilience.tst.sh` | PC | claude | Batch 5 (Lane 1) |
| 10 | `test(net-10-failover-drill)` | End-to-end failover drill | Rigorous empirical proof that multi-uplink auto-switching meets all criteria with zero fencing and agent continuity | Precondition: >= 2 uplinks; failover < 30 s (IPv4 + IPv6); 0 fences; 100% of live host agents ($n$) verified | `do_net_failover_drill`<br>`csi-spl-orc/src/bash/tests/net-failover-drill.tst.sh` | PC | claude | Batch 5 (Lane 2) |

## 4. Detailed row specifications

### Row 01: `feat(net-01-powersave-off)` - Wi-Fi power save disabled
- **What:** Create `/etc/NetworkManager/conf.d/20-wifi-powersave-off.conf`:
  ```ini
  [connection]
  wifi.powersave = 2
  ```
  and apply runtime setting `/usr/sbin/iw dev <wlan> set power_save off`.
- **Why:** The Intel `iwlwifi` driver operates with `power_scheme = 2`. Disabling 802.11 power saving eliminates sleep state wake latency and disconnects during short quiet periods.
- **Command:** `/usr/sbin/iw dev $(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi"{print $1}') get power_save`
- **Target:** `Power save: off`.
- **Proof:** Zero power-save-induced beacon losses; configuration persists across `NetworkManager` restarts and reboots.

### Row 02: `feat(net-02-connectivity-check)` - NetworkManager connectivity check
- **What:** Create `/etc/NetworkManager/conf.d/30-connectivity.conf`:
  ```ini
  [connectivity]
  uri = http://network-test.debian.org/nm
  interval = 10
  timeout = 5
  ```
  Assert `rp_filter != 1` on all uplinks.
- **Why:** Without periodic check, NetworkManager cannot detect when an AP has lost WAN backhaul. `NetworkManager.conf(5)` natively applies a `+20000` metric penalty to unroutable interfaces, causing kernel default route failover to the backup link.
- **Command:** `nmcli networking connectivity check`
- **Target:** Transitions to `limited` or `none` within <= 15 s (`interval` + `timeout`) of internet loss; adds `+20000` penalty to both IPv4 and IPv6 routes.
- **Proof:** Route metric raises by +20000 on dead WAN; drops penalty within 10 s of backhaul restoration.

### Row 03: `feat(net-03-wired-priority)` - Wired Ethernet persistent profile
- **What:** Create persistent keyfile `/etc/NetworkManager/system-connections/wired-default.nmconnection`:
  ```ini
  [connection]
  id = wired-default
  type = ethernet
  interface-name = enp0s31f6
  autoconnect = yes
  autoconnect-priority = 100

  [ipv4]
  method = auto
  route-metric = 100

  [ipv6]
  method = auto
  route-metric = 100
  ```
- **Why:** Replaces the ephemeral in-memory profile `Wired connection 1` (-999). Setting `autoconnect-priority = 100` and explicit metric 100 ensures Ethernet automatically preempts Wi-Fi (600) and USB tether (650) within < 2 s of cable insertion.
- **Command:** `nmcli -f connection.autoconnect-priority,ipv4.route-metric,ipv6.route-metric connection show wired-default`
- **Target:** `autoconnect-priority: 100`, `route-metric: 100` (IPv4 and IPv6).
- **Proof:** Cable insert installs metric 100 default route ahead of Wi-Fi in < 2 seconds.

### Row 04: `feat(net-04-usb-tether-profiles)` - USB tethering autoconnect
- **What:** Create persistent keyfile `/etc/NetworkManager/system-connections/usb-tether.nmconnection`:
  ```ini
  [connection]
  id = usb-tether
  type = ethernet
  autoconnect = yes
  autoconnect-priority = 50
  metered = yes

  [match]
  driver = rndis_host;cdc_ncm;cdc_ether;ipheth;huawei_cdc_ncm;

  [ipv4]
  method = auto
  route-metric = 650

  [ipv6]
  method = auto
  route-metric = 650
  ```
- **Why:** On Debian 13, interface naming does not produce `usb*` or `enx*` names; driver matching (`match.driver`) reliably binds all tethered phones. Route metric `650` (below Wi-Fi 600) and `metered = yes` ensure phone data is used strictly as a backup when Wi-Fi is unavailable or unroutable.
- **Command:** `nmcli connection show usb-tether`
- **Target:** Interface acquires DHCP lease and metric 650 within 3 seconds of USB connection.
- **Proof:** When Wi-Fi is active and healthy, traffic routes via Wi-Fi (600); when Wi-Fi drops or receives +20000 penalty, traffic routes via USB tether (650).

### Row 05: `feat(net-05-wlan-ladder)` - Wireless priority ladder
- **What:** Configure explicit `connection.autoconnect-priority` and `connection.metered` on saved Wi-Fi profiles:
  - Primary Wi-Fi ("the home Wi-Fi"): priority `10`, metric `600`.
  - Phone A hotspot: priority `8`, metric `600`, `connection.metered = yes`.
  - Phone B hotspot: priority `7`, metric `600`, `connection.metered = yes`.
  - Travel Wi-Fi profiles: priority `5`, metric `600`.
  - Configure profiles by UUID to avoid exposing SSIDs in the repository.
- **Why:** A single Wi-Fi radio associates with one SSID at a time; autoconnect priorities govern candidate selection without creating confusing metric ladders across profiles on the same device.
- **Command:** `nmcli -f UUID,AUTOCONNECT-PRIORITY,METERED connection show`
- **Target:** Clean priority ladder with zero SSID leaks.
- **Proof:** NetworkManager selects highest priority available Wi-Fi profile on scan.

### Row 06: `feat(net-06-dns-pin-and-mask)` - Pin NetworkManager DNS mode & mask resolved
- **What:**
  1. Create `/etc/NetworkManager/conf.d/10-dns-pin.conf`:
     ```ini
     [main]
     dns = default
     rc-manager = symlink
     ```
  2. Mask `systemd-resolved`:
     ```bash
     systemctl mask systemd-resolved
     ```
- **Why:** Proposal P1: An unexpected start of `systemd-resolved` (from a package update or script) will overwrite `/etc/resolv.conf` and disconnect the box from the hub, repeating the 22-minute outage. Pinning NM DNS mode and masking `systemd-resolved` permanently secures DNS operation.
- **Command:** `systemctl is-enabled systemd-resolved; NetworkManager --print-config | grep -E '^dns=|^rc-manager='`
- **Target:** `masked`; `dns=default`, `rc-manager=symlink`.
- **Proof:** `/etc/resolv.conf` remains a symlink to `/run/NetworkManager/resolv.conf` under all conditions.

### Row 07: `feat(net-07-dns-fast-failover)` - Uplink DNS fast failover
- **What:** Configure public DNS servers and fast glibc resolver options on all connection profiles:
  ```bash
  nmcli connection modify "<profile>" ipv4.dns "8.8.8.8,1.1.1.1" ipv4.dns-options "timeout:2,attempts:2"
  ```
- **Why:** Agents run as host processes and resolve domain names through `/etc/resolv.conf`. By default, glibc waits 5 s per DNS server for 2 attempts (up to 20 s per lookup). Setting `timeout:2,attempts:2` with reliable public DNS ensures DNS lookups failover in < 2 s during uplink switches.
- **Command:** `grep -E 'nameserver|options' /etc/resolv.conf`
- **Target:** `nameserver 8.8.8.8`, `options timeout:2 attempts:2`.
- **Proof:** Host domain name resolution for API endpoints (`api.anthropic.com`, `generativelanguage.googleapis.com`) succeeds in < 2 s during network switch.

### Row 08: `feat(net-08-beat-continuity)` - Hub beat anti-fence guard
- **What:** Create dispatcher wake script `/etc/NetworkManager/dispatcher.d/no-wait.d/50-beat-poke.sh`:
  - On network event (`up`, `down`, `connectivity-change`), touch `/var/run/spl/watchdog.poke`.
  - The watchdog loop in `spl-watchdog.func.sh` wakes immediately on file creation to run `spl_wd_beat` without waiting for the 30 s tick.
- **Why:** Spec 102 §10.2 fences the box after 120 s with no beat ack. With `WD_TICK = 30` s, any switch under 90 s avoids fencing; an immediate wake poke reduces the beat delay to < 5 s post-switch.
- **Command:** `SPOOL_BOX_BEAT_DRY=1 bash csi-spl-orc/src/bash/run/spl-watchdog.func.sh --once`
- **Target:** Hub beat acknowledged in < 15 s of uplink switch; beat ack age < 90 s; 0 `FENCED` entries.
- **Proof:** Watchdog log records continuous unfenced state across network failover.

### Row 09: `feat(net-09-agent-conn-resilience)` - Fast socket eviction & git timeouts
- **What:**
  1. Deploy dispatcher script `/etc/NetworkManager/dispatcher.d/98-kill-dead-sockets.sh`:
     On default route change, execute:
     ```bash
     ss -K -t src <old-ipv4-addr>
     ss -K -6 -t src <old-ipv6-addr>
     ```
  2. Maintain `tcp_retries2 = 15` (or <= 8; do not set to 6, which cannot terminate sockets waiting on read and harms transient Wi-Fi blips).
  3. Set global timeouts:
     ```bash
     git config --system http.lowSpeedLimit 1000
     git config --system http.lowSpeedTime 10
     ```
     and in `/etc/ssh/ssh_config.d/99-keepalive.conf`:
     ```ini
     ServerAliveInterval 10
     ServerAliveCountMax 3
     ```
- **Why:** Model API streaming connections wait for incoming tokens without outbound packets in flight. `tcp_retries2` never aborts read-side idle sockets. `ss -K` immediately aborts sockets bound to the former uplink's source address, causing client libraries to receive `ECONNRESET` and instantly reconnect over the new default route.
- **Command:** `git config --system http.lowSpeedLimit; cat /etc/ssh/ssh_config.d/99-keepalive.conf`
- **Target:** Dead sockets aborted in < 2 s of route switch; agent CLIs reconnect without hanging.
- **Proof:** Triggering route switch aborts old-source socket; agent CLI retry loop resumes within 3 s.

### Row 10: `test(net-10-failover-drill)` - End-to-end failover drill
- **What:** Implement the end-to-end failover drill action `do_net_failover_drill`:
  1. **Precondition:** Verify >= 2 active uplinks with default routes (refuses if only 1 uplink is present).
  2. **Census:** Enumerate all live host agent processes ($n$) using `ps -eo user=,args= | awk '$2 ~ /(^|\/)(claude|vibe|agy|grok)$/'`.
  3. **Trigger:** Simulate primary uplink drop (blackhole or interface down).
  4. **Stopwatch:** Measure seconds until secondary default route takes over on both IPv4 and IPv6 (`ip route show default` and `ip -6 route show default`).
  5. **Fence check:** Verify watchdog heartbeat ack age remains < 90 s (0 fence events).
  6. **Agent proof:** Verify passive transcript / heartbeat timestamp advances across all $n$ live host agents, plus execute 1 active probe model call and 1 probe `spool send`.
  7. **Recovery:** Restore primary uplink and verify failover back to primary.
- **Why:** Empirical verification that multi-uplink auto-switching, beat continuity, and agent resilience function seamlessly in production.
- **Command:** `cd csi-spl-orc && ./run -a do_net_failover_drill`
- **Target:** Total failover < 30 s (aim < 15 s); 0 fences; 100% agent continuity ($n$ of $n$).
- **Proof:** Drill report detailing exact timestamps, route changes, heartbeat age, and verified agent responses.

## 5. Owner addition: agent fleet continuity (d609d0e9)

The owner requirement: *"And, of course, how this network switch will affect the agents (aka, we must ensure that the agents will 'know' the new network and they will be able to use the new network)."*

The plan addresses this through four verified mechanisms:
1. **Socket Eviction by Old Source Address (Row 09):** Agents run as host processes. When the outbound default route changes, open TCP sockets bound to the old source IP enter a hung state. Streamed model API connections waiting to read are terminated immediately via `ss -K -t src <old-ip>` (for both IPv4 and IPv6), forcing instant reconnection over the new interface.
2. **Fast DNS Resolver Failover (Row 06 & Row 07):** By pinning NM DNS mode (`dns=default`, `rc-manager=symlink`), masking `systemd-resolved`, and configuring `timeout:2,attempts:2` with public DNS across all profiles, DNS queries failover within < 2 s without stalls.
3. **Heartbeat Continuity & Anti-Fence (Row 08):** Route change wake pokes notify the watchdog loop to trigger an immediate hub heartbeat, ensuring the 120 s fence timer is never reached.
4. **Empirical Agent Proof in Drill (Row 10):** The drill verifies agent execution across all $n$ live host agents on `PC` via passive transcript progression plus active probe model API and spool messaging over the new route.

## 6. Execution batches & disjoint files (R1)

All files modified by the 10 rows are completely disjoint across the repository:

- **Batch 1 (Lane 1 & Lane 2):**
  - Row 01: `/etc/NetworkManager/conf.d/20-wifi-powersave-off.conf`, `csi-spl-orc/src/bash/run/net-powersave-off.func.sh`, `csi-spl-orc/src/bash/tests/net-powersave-off.tst.sh`
  - Row 02: `/etc/NetworkManager/conf.d/30-connectivity.conf`, `csi-spl-orc/src/bash/run/net-connectivity-check.func.sh`, `csi-spl-orc/src/bash/tests/net-connectivity-check.tst.sh`
- **Batch 2 (Lane 1 & Lane 2):**
  - Row 03: `/etc/NetworkManager/system-connections/wired-default.nmconnection`, `csi-spl-orc/src/bash/run/net-wired-priority.func.sh`, `csi-spl-orc/src/bash/tests/net-wired-priority.tst.sh`
  - Row 04: `/etc/NetworkManager/system-connections/usb-tether.nmconnection`, `csi-spl-orc/src/bash/run/net-usb-tether-profiles.func.sh`, `csi-spl-orc/src/bash/tests/net-usb-tether-profiles.tst.sh`
- **Batch 3 (Lane 1 & Lane 2):**
  - Row 05: `csi-spl-orc/src/bash/run/net-wlan-ladder.func.sh`, `csi-spl-orc/src/bash/tests/net-wlan-ladder.tst.sh`
  - Row 06: `/etc/NetworkManager/conf.d/10-dns-pin.conf`, `csi-spl-orc/src/bash/run/net-dns-pin-and-mask.func.sh`, `csi-spl-orc/src/bash/tests/net-dns-pin-and-mask.tst.sh`
- **Batch 4 (Lane 1 & Lane 2):**
  - Row 07: `csi-spl-orc/src/bash/run/net-dns-fast-failover.func.sh`, `csi-spl-orc/src/bash/tests/net-dns-fast-failover.tst.sh`
  - Row 08: `/etc/NetworkManager/dispatcher.d/no-wait.d/50-beat-poke.sh`, `csi-spl-orc/src/bash/run/net-beat-continuity.func.sh`, `csi-spl-orc/src/bash/tests/net-beat-continuity.tst.sh`
- **Batch 5 (Lane 1 & Lane 2):**
  - Row 09: `/etc/NetworkManager/dispatcher.d/98-kill-dead-sockets.sh`, `/etc/ssh/ssh_config.d/99-keepalive.conf`, `csi-spl-orc/src/bash/run/net-agent-conn-resilience.func.sh`, `csi-spl-orc/src/bash/tests/net-agent-conn-resilience.tst.sh`
  - Row 10: `csi-spl-orc/src/bash/run/net-failover-drill.func.sh`, `csi-spl-orc/src/bash/tests/net-failover-drill.tst.sh`

## 7. Panel consensus & signatures

| Seat | Vendor | Agent ID | Status | Verdict Landed SHA |
|---|---|---|---|---|
| Editor | agy | a-271@sat | Approved v1.0 | Current HEAD |
| Expert 1 | claude | c-673 | Consensus (seat-claude.md) | `458659b17162e90a2a274e80e013fa5abb8558ac` |
| Expert 2 | claude | c-719 | Consensus (seat-mistral.md) | `b4b59f91a1432a96c13c86fec4a45fc0ba9b94f3` |

Consensus achieved across all panel seats. Row lanes spawn in batches according to Section 6 without waiting for owner approval (rounds-rulebook.md §1.4).
