# Networking round: agy seat proposal (a-271@sat)

Seat: **a-271@sat** (agy), editor seat, task `dispatch-06871e35`, issue SPL-2109.
Plan: the multi-uplink auto-switching plan v0.1 draft.
Target box: **PC** (the Debian 13 laptop).

## 1. Measured facts & context (laptop baseline)

Measured on the laptop box by `c-001@PC` (read-only baseline, 2026-10-16 ~04:0xZ, n=1):
- **Active uplink:** Single Wi-Fi uplink (Intel `iwlwifi`), DHCP default route `metric 600`.
- **Wired port:** Intel `e1000e` Gigabit NIC present, unplugged. Profile `connection.autoconnect-priority = -999` (refuses auto-takeover).
- **Secondary uplinks:** No phone USB tethering device attached, no secondary USB Wi-Fi dongle, no WWAN.
- **NetworkManager config:** `/etc/NetworkManager/conf.d/` is empty. **NO connectivity check is configured**; Wi-Fi power save is default (enabled).
- **Outage history:** 11 Wi-Fi beacon losses / disconnects in 6 hours. At 03:41:37Z..03:44:25Z (2 min 48 s), a beacon loss caused a complete box disconnect that exceeded the 120 s threshold, fencing the box (spec 102 §10.2).
- **Fleet isolation:** 32 docker `veth*`/bridge links active on the box. All harness changes must leave docker internal routing intact.

## 2. Technical sources (Debian 13 / NetworkManager)

Proposals are grounded in verified Debian 13 (Trixie) man pages and kernel documentation:
- `NetworkManager.conf(5)`: `[connectivity]` (`uri`, `interval`, `response`), `[connection]` (`wifi.powersave=2`).
- `nm-settings(5)` / `nmcli(1)`: `connection.autoconnect-priority` (-999..999), `ipv4.route-metric` (kernel route priority), wildcard device matching `match.interface-name:usb*,enx*`.
- `NetworkManager-dispatcher(8)`: `/etc/NetworkManager/dispatcher.d/` asynchronous hook handling `up`, `down`, `connectivity-change`.
- `tcp(7)`, `ss(8)`: `net.ipv4.tcp_retries2 = 6` (fails dead sockets in ~15-20 s instead of 15 min), `ss -K` (kill sockets bound to dead IP on route change).
- `systemd-resolved(8)` & `/etc/docker/daemon.json`: fallback DNS (`1.1.1.1`, `8.8.8.8`) preventing stale DHCP nameserver lookups inside agent containers.

## 3. The 10 actions proposal

| # | slug | practice | sites | target | csi-rel action & test |
|---|---|---|---|---|---|
| 01 | `feat(net-01-powersave-off)` | Wi-Fi power save off | `/etc/NetworkManager/conf.d/20-wifi-powersave-off.conf` | `Power save: off` on `iw dev`; 0 sleep drops in 24 h | `do_net_powersave_off`<br>`csi-spl-orc/src/bash/tests/net-powersave-off.tst.sh` |
| 02 | `feat(net-02-connectivity-check)` | NM connectivity check | `/etc/NetworkManager/conf.d/30-connectivity.conf` | Outage detected in < 10 s; reports `limited`/`none` | `do_net_connectivity_check`<br>`csi-spl-orc/src/bash/tests/net-connectivity-check.tst.sh` |
| 03 | `feat(net-03-wired-priority)` | Wired auto-takeover | `e1000e` connection profile | Priority 100, metric 100; takes default route in < 2 s | `do_net_wired_priority`<br>`csi-spl-orc/src/bash/tests/net-wired-priority.tst.sh` |
| 04 | `feat(net-04-usb-tether-profiles)` | USB tethering autoconnect | `/etc/NetworkManager/system-connections/usb-tether.nmconnection` | Priority 50, metric 200; activates on plug in < 3 s | `do_net_usb_tether_profiles`<br>`csi-spl-orc/src/bash/tests/net-usb-tether-profiles.tst.sh` |
| 05 | `feat(net-05-wlan-ladder)` | Wireless metric & priority ladder | Saved Wi-Fi connection profiles | Home Wi-Fi (prio 10, metric 600) > Hotspot A (8, 700) > Hotspot B (7, 710) | `do_net_wlan_ladder`<br>`csi-spl-orc/src/bash/tests/net-wlan-ladder.tst.sh` |
| 06 | `feat(net-06-wan-watchdog)` | Silent blackhole WAN watchdog | `/etc/NetworkManager/dispatcher.d/90-wan-watchdog.sh` | Metric +1000 on 3 failed probes (15 s); switches route in < 20 s | `do_net_wan_watchdog`<br>`csi-spl-orc/src/bash/tests/net-wan-watchdog.tst.sh` |
| 07 | `feat(net-07-dns-resilience)` | DNS resolver continuity for fleet | `/etc/docker/daemon.json`, `systemd-resolved` fallback | Container DNS resolves in < 100 ms after route switch | `do_net_dns_resilience`<br>`csi-spl-orc/src/bash/tests/net-dns-resilience.tst.sh` |
| 08 | `feat(net-08-beat-continuity)` | Hub beat anti-fence guard | `do_spl_box_beat`, dispatcher poke | Immediate beat on route switch; max beat gap < 25 s (0 fence events) | `do_net_beat_continuity`<br>`csi-spl-orc/src/bash/tests/net-beat-continuity.tst.sh` |
| 09 | `feat(net-09-agent-conn-resilience)` | Fast TCP timeout & CLI reconnect | `/etc/sysctl.d/99-net-retries.conf`, `ss -K` | Dead sockets aborted in < 5 s; CLIs reconnect in < 5 s | `do_net_agent_conn_resilience`<br>`csi-spl-orc/src/bash/tests/net-agent-conn-resilience.tst.sh` |
| 10 | `test(net-10-failover-drill)` | End-to-end failover drill | `do_net_failover_drill` | Failover < 30 s, 0 fences, 100% of live agents ($n$) verified | `do_net_failover_drill`<br>`csi-spl-orc/src/bash/tests/net-failover-drill.tst.sh` |

## 4. Owner addition: fleet and agent continuity (d609d0e9)

The owner requirement (d609d0e9) ensures that running agents automatically use the new network:
1. **Model API socket termination (Row 09):** `tcp_retries2 = 6` drops Linux retransmit wait from 15 min to ~15-20 s. The dispatcher script triggers `ss -K` on stale sockets, forcing instant `ECONNRESET` so agent retry loops execute immediately.
2. **Container DNS stability (Row 07):** Docker daemon configured with fallback DNS (`1.1.1.1`, `8.8.8.8`) prevents container DNS hangs when DHCP nameserver changes.
3. **Fence prevention (Row 08):** Box heartbeat dispatches immediately on route transition, ensuring the 120 s fence timer never elapses.
4. **Empirical Drill Proof (Row 10):** The drill queries all running agent containers on `PC` ($n$) and verifies that every container performs a model call and spool send over the new route.

## 5. Signature

`signed: a-271@sat on v0.1 draft`
