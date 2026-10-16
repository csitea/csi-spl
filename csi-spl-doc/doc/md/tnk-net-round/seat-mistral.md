# Networking round: seat 2 verdict (claude, replaces mistral m-676)

Seat 2 is **claude `c-719`**. It replaces the first seat 2, mistral `m-676`, which was stopped after it installed packages on PC. The file keeps its `seat-mistral.md` name on purpose.
Task `dispatch-06871e35`, round issue SPL-2109, lane issue SPL-2197. Editor: `a-271@sat`.
Review of: the plan **v0.1 draft** (the plan file one directory up).
Target box: **PC** (the Debian 13 laptop). This seat ran on PC, **read-only**: no install, no service change, no edit under `/etc`. Every probe below ran 2026-10-16 12:06-12:30Z, n=1 unless stated.

Where this seat agrees with seat 1 (`seat-claude.md`, c-673), it says so in one line. Its own work is the points seat 1 left unchecked, plus four new findings: the USB tether naming, the wired auto-default profile, the read-side TCP hang and the DNS residue left by `m-676`.

## Summary

**0 agree / 7 agree with changes / 3 disagree / 2 proposals.**

| Row | Slug | Verdict | One-line reason |
|---|---|---|---|
| 01 | `feat(net-01-powersave-off)` | agree with changes | Power save **is on** now (`iw` reads `on`). The setting is right, but the drops it should fix are not proven, and `iw` lives in `/usr/sbin` (not on the agents' PATH) |
| 02 | `feat(net-02-connectivity-check)` | agree with changes | The key row. `timeout` defaults to 20 s, so "within 10 s" needs `timeout` set; the check must also cover IPv6 (P2) |
| 03 | `feat(net-03-wired-priority)` | agree with changes | `-999` is the in-memory **auto-default** profile's built-in value and does not block activation. Make a named, persistent profile bound to the NIC instead of modifying `Wired connection 1` |
| 04 | `feat(net-04-usb-tether-profiles)` | disagree | On Debian 13 a tether is **not** named `usb*` or `enx*` (`NamePolicy` has no `mac`). Match by driver. `match-device` is not a profile key, and metric 200 puts all traffic on mobile data |
| 05 | `feat(net-05-wlan-ladder)` | agree with changes | Priorities yes; per-SSID metrics are moot on one radio (same as seat 1) |
| 06 | `feat(net-06-wan-watchdog)` | disagree | NM's connectivity check already adds a +20000 metric penalty, and `ip route change … metric` changes the route key (same as seat 1). Fold into row 02 |
| 07 | `feat(net-07-dns-resilience)` | disagree | `systemd-resolved` is now **installed but disabled** (left behind by `m-676`), and no agent runs in a container. Pin NM's DNS mode instead (P1) |
| 08 | `feat(net-08-beat-continuity)` | agree with changes | The beat is `spl_wd_beat`, once per `WD_TICK` (30 s). A failover under ~90 s never fences; "gap < 25 s" contradicts the 30 s tick |
| 09 | `feat(net-09-agent-conn-resilience)` | agree with changes | `tcp_retries2=6` is **25.4 s** (kernel source), and it never fires on a socket that is only **waiting to read**, which is the hung model stream. `ss -K` by source address is the fix |
| 10 | `test(net-10-failover-drill)` | agree with changes | Count host processes, not containers; require 2 live uplinks first; measure IPv4 and IPv6 |

## 1. Baseline on PC, re-measured by this seat

Each line is the command and what it printed (addresses and SSIDs replaced by placeholders).

| Fact | Command | Output |
|---|---|---|
| OS / kernel / NM | `cat /etc/debian_version; uname -r; /usr/sbin/NetworkManager --version` | `13.5`, `6.12.90+deb13.1-amd64`, `1.52.1` |
| IPv4 default | `ip route show default` | one route, `dev wlp0s20f3 proto dhcp … metric 600` |
| **IPv6 default** | `ip -6 route show default` | `default via fe80::… dev wlp0s20f3 proto ra metric 600 pref high`: **the box has a live IPv6 uplink** |
| Devices | `nmcli -t -f DEVICE,TYPE,STATE dev` (uplinks only) | `wlp0s20f3:wifi:connected`, `enp0s31f6:ethernet:unavailable` |
| **Wired profile** | `nmcli -t -f NAME,TYPE,AUTOCONNECT-PRIORITY,FILENAME c show` (ethernet) | `Wired connection 1:802-3-ethernet:-999:/run/NetworkManager/system-connections/Wired connection 1.nmconnection`: in memory (`/run`), NM's auto-default |
| Wi-Fi profiles | `nmcli -t -f TYPE,AUTOCONNECT,AUTOCONNECT-PRIORITY c show` | active Wi-Fi `yes:10`, six others `yes:0` |
| Active Wi-Fi settings | `nmcli -g ipv4.dns,ipv4.ignore-auto-dns,ipv4.dns-options,ipv4.route-metric,802-11-wireless.powersave,connection.metered c show <uuid>` | `8.8.8.8,1.1.1.1`, `no`, (empty), `-1`, `default`, `unknown` |
| **Power save now** | `/usr/sbin/iw dev wlp0s20f3 get power_save` | `Power save: on` (`iw` 6.9-1 has been installed since 2026-06-02 per `/var/log/dpkg.log`; it is in `/usr/sbin`, so `command -v iw` as the agent user finds nothing) |
| NM config | `ls /etc/NetworkManager/conf.d/ /usr/lib/NetworkManager/conf.d/` | empty; `no-mac-addr-change.conf` |
| **Interface naming** | `grep -vE '^#\|^$' /usr/lib/systemd/network/99-default.link` | `NamePolicy=keep kernel database onboard slot path` (no `mac`); `AlternativeNamesPolicy=… mac` |
| Tether drivers present | `ls /lib/modules/$(uname -r)/kernel/drivers/net/usb/` | `rndis_host`, `cdc_ncm`, `cdc_ether`, `ipheth`, `huawei_cdc_ncm` (`.ko.xz`) |
| `ss -K` support | `grep INET_DIAG /boot/config-$(uname -r)` | `CONFIG_INET_DIAG=m`, `CONFIG_INET_DIAG_DESTROY=y` |
| TCP sysctls | `cat /proc/sys/net/ipv4/{tcp_retries2,tcp_retries1,tcp_keepalive_time}` | `15`, `3`, `7200` |
| **DNS residue** | `grep -E ' install ' /var/log/dpkg.log \| tail` | `2026-10-16 13:19:40` (local, +03:00) `install systemd-resolved 257.13-1~deb13u1` and `libnss-resolve`: the `m-676` incident |
| | `systemctl is-active systemd-resolved; systemctl is-enabled systemd-resolved` | `inactive`, `disabled` |
| | `ls -la /etc/resolv.conf` | symlink -> `/run/NetworkManager/resolv.conf`, created `13:41` local |
| | `grep -v '^#' /etc/resolv.conf` | `8.8.8.8`, `1.1.1.1`, the DHCP router, an IPv6 RA server |
| | `grep ^hosts /etc/nsswitch.conf; ls -la /etc/nsswitch.conf` | `files myhostname mdns4_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] dns`, modified `13:19:41` |
| Wi-Fi drop history | `journalctl -t wpa_supplicant` | **not measured by this seat**: the seat's user is not in `adm`/`systemd-journal`, and the brief allows sudo only for git and `./run`. The drop history is seat 1's measurement (one AP-gone event, `ssid-not-found`), relayed, not re-checked |

## 2. Row-by-row review

### Row 01 — Wi-Fi power save: agree with changes

- `NetworkManager.conf(5)`, connection defaults: `wifi.powersave` "If left unspecified, the default value "ignore" will be used." `nm-settings-nmcli(5)` `802-11-wireless.powersave`: `default (0), ignore (1), disable (2), enable (3)`. The plan's `[connection] wifi.powersave = 2` is valid.
- Measured: `iw … get power_save` -> `on`. So the driver's own power save is active today. This supports the row, but does not prove it caused the drops.
- Changes: (a) call `/usr/sbin/iw` by full path, or verify with `nmcli -g 802-11-wireless.powersave` plus `iw` as root. (b) Target = BEACON-LOSS and DISCONNECTED counts, 24 h before against 24 h after, read by a user who can read the system journal (seat 1's P2 makes that one file).

### Row 02 — connectivity check: agree with changes

- `NetworkManager.conf(5)` CONNECTIVITY SECTION, verbatim: "default-route of devices without global connectivity get a penalty of +20000 to the route-metric". This is the automatic switch the owner asked for.
- Same section: `interval` "If missing, the default is 300 seconds"; `timeout` "If missing, the default is 20 seconds"; `uri` "If this option is blank or missing, connectivity checking is disabled"; `response` "If set to empty, the HTTP server is expected to answer with status code 204 or send no data."
- Changes: set `timeout = 5`; state the target as <= `interval` + `timeout` = 15 s, not 10 s. The same section warns that a strict `rp_filter` "will reject any response and the connectivity check on all but the best route will fail". The action asserts `rp_filter` != 1 on every uplink.
- Add IPv6: the box has an IPv6 default route (section 1). The drill must show the +20000 penalty on **both** `ip route` and `ip -6 route` while the uplink is blackholed (P2).

### Row 03 — wired takeover: agree with changes

- Measured: the only wired profile is `Wired connection 1`, stored in `/run/NetworkManager/system-connections/`, which means in memory.
- `NetworkManager.conf(5)` `no-auto-default`: "By default, NetworkManager creates a temporary wired connection for any Ethernet device that is managed and doesn't have a connection configured."
- NM 1.52.1 source, `src/core/devices/nm-device-ethernet.c` (fetched from the upstream tag `1.52.1`, line 1749): the auto-default is created with `NM_SETTING_CONNECTION_AUTOCONNECT_PRIORITY, NM_SETTING_CONNECTION_AUTOCONNECT_PRIORITY_MIN`, i.e. **-999 by design**.
- `nm-settings-nmcli(5)` `connection.autoconnect`: the priority decides only "If multiple profiles are ready to autoconnect on the same device". So the plan's diagnosis "-999 prevents auto-takeover" is wrong. It is the only candidate profile, and it activates on carrier.
- NM 1.52.1 source, `src/core/devices/nm-device.c` `nm_device_get_route_metric_default()`: `NM_DEVICE_TYPE_ETHERNET` -> `return 100`, `NM_DEVICE_TYPE_WIFI` -> `return 600` ("For both IPv4 and IPv6 we use the same default values"). So wired already wins at metric 100 with no change. This confirms the point seat 1 left unchecked.
- Change: do not `nmcli connection modify "Wired connection 1"`, a name NM generates. Add a named, persistent profile, `connection.interface-name enp0s31f6`, `autoconnect-priority 100`, explicit `ipv4/ipv6.route-metric 100` (a readable ladder). It then outranks any auto-default. Proof stays the real cable insert.

### Row 04 — USB tether profile: disagree (as written)

- **The name match misses on Debian 13.** `systemd.link(5)` `NamePolicy=`: "the first successful one is used". Debian's `99-default.link` lists `keep kernel database onboard slot path`, with **no `mac`**. A USB NIC therefore gets the `path` name, `systemd.net-naming-scheme(7)` `ID_NET_NAME_PATH`, `en…u<port>`. The `enx<MAC>` form (`ID_NET_NAME_MAC`) is only an *alternative* name here (`AlternativeNamesPolicy=… mac`), which NM's `interface-name` match does not see. The box's own NIC shows it: `enp0s31f6`, not `enx…`. I believe, from the kernel's usbnet code (unchecked on PC), that the kernel's `usb%d` name is an enumerated name, which `kernel` policy does not keep. Either way, `usb*`/`enx*` will not match, and the phone then falls to an auto-default `Wired connection 2` at **metric 100**: all traffic goes to mobile data, ahead of Wi-Fi.
- `match-device` is a `NetworkManager.conf(5)` key ("An optional device spec that restricts when the section applies"), not a connection-profile key (same as seat 1).
- Fix: `nm-settings-nmcli(5)` `match.driver`: "A list of driver names to match. Each element is a shell wildcard pattern." The drivers exist as modules on PC (section 1). Keyfile:

```ini
[connection]
id=usb-tether
type=ethernet
autoconnect=yes
autoconnect-priority=50
metered=yes

[match]
driver=rndis_host;cdc_ncm;cdc_ether;ipheth;huawei_cdc_ncm;

[ipv4]
method=auto
route-metric=650

[ipv6]
method=auto
route-metric=650
```

- Metric 650 (below Wi-Fi 600) and `connection.metered=yes` (`nm-settings-nmcli(5)`: "the change takes effect immediately") keep the phone a **backup**. Failover still happens: a lost Wi-Fi removes its route, and a Wi-Fi with no internet takes +20000 (row 02). This seat agrees with seat 1's 650.
- Caveat: `cdc_ether` also binds some USB Ethernet dongles. The lane reads `readlink /sys/class/net/<if>/device/driver` with the real phones plugged in, and narrows the list to what they show.
- Alternative (if a stable name is wanted): a `systemd.link(5)` file `[Match] Driver=rndis_host cdc_ncm …` with `[Link] NamePolicy=mac`. That is a udev change under `/etc`; `match.driver` needs none.

### Row 05 — Wi-Fi ladder: agree with changes

- Agrees with seat 1: keep priorities (10 / 8 / 7 / 5), drop the per-SSID metric ladder (one radio joins one SSID; `nm-settings-nmcli(5)`: "If the priorities are equal, then the most recently connected profile is activated"). Mark hotspots `connection.metered = yes`; select profiles by UUID, never write an SSID into the repo.
- Add: `connection.autoconnect-retries` (`nm-settings-nmcli(5)`: "-1 means the global default (4 times if not overridden) … after a timeout, NetworkManager will try to autoconnect again"). Leave it at the default; the lane does not raise it.

### Row 06 — WAN watchdog: disagree (fold into row 02)

- Agrees with seat 1 on all three points, each re-read here: the native +20000 penalty (`NetworkManager.conf(5)`); `ip-route(8)` route keys include the metric (`preference`), so `ip route change … metric 1600` makes a new route; `NetworkManager-dispatcher(8)`: for "connectivity-change and dns-change it [the interface] is empty", and scripts "will be killed if they run for too long".
- The slot goes to row 02's IPv6 proof and P1 below.

### Row 07 — DNS resilience: disagree (as written)

- New since seat 1 measured: `systemd-resolved` and `libnss-resolve` **are installed** (dpkg 13:19:40 local, by `m-676`). The unit is `disabled` and `inactive`, and `/etc/resolv.conf` is NM's symlink to `/run/NetworkManager/resolv.conf`. `nsswitch.conf` now carries `resolve [!UNAVAIL=return]` before `dns`; with resolved down it answers UNAVAIL and lookups fall through to `dns`.
- The plan's `FallbackDNS=` and `resolvectl flush-caches` need resolved **running**. Running it is exactly what cut the box from the hub for 22 min. `NetworkManager.conf(5)` `dns`: "If the key is unspecified, default is used, unless /etc/resolv.conf is a symlink to /run/systemd/resolve/stub-resolv.conf … In that case, systemd-resolved is chosen automatically."
- No agent runs in a container (seat 1, `ps`/`docker ps`); `/etc/docker/daemon.json` `dns` needs a daemon restart that stops other lanes' test databases. Leave it out.
- Instead: seat 1's `ipv4.dns` on every uplink profile plus `ipv4.dns-options = timeout:2,attempts:2` (`nm-settings-nmcli(5)` lists "attempts", "timeout", "rotate"; `resolv.conf(5)`), and P1 below.

### Row 08 — beat continuity: agree with changes

- Repo, `origin/master`: `csi-spl-orc/src/bash/run/spl-watchdog.func.sh`: `@param WD_TICK … default 30`; `spl_wd_fence` calls `spl_wd_beat "$now"` once per tick; `spl_wd_beat` is "bounded by WD_BEAT_TIMEOUT (10 s)"; FENCED when there is no ack for `box_down_min`. `csi-spl-api/src/go/spool-hub-api/internal/hub/box_beat.go` `boxDownMin`: `def := 2` (minutes). No `spl-box-beat.func.sh` exists (`git ls-tree … run/ | grep box-beat` -> nothing).
- Arithmetic: the fence is tested on a tick. An outage that starts right after an ack fences at the first tick >= 120 s later. Any outage shorter than 120 - 30 = **90 s** never fences, with no code change. The 2 min 48 s event of plan section 1 was longer than that.
- Changes: target "beat-ack age < 90 s during the drill; 0 `FENCED` lines in the watchdog log", not "gap < 25 s". The early beat on a route change (dispatcher touches a poke file, the tick's sleep wakes on it) is a good refinement. That file belongs to the watchdog lane, so the row runs `lane-map.sh --check` first.

### Row 09 — agent socket resilience: agree with changes

- Kernel v6.12 `net/ipv4/tcp_timer.c` (fetched): `retransmits_timed_out()` starts `if (!inet_csk(sk)->icsk_retransmits) return false;`. Then `tcp_model_timeout()` = `((2 << boundary) - 1) * rto_base` while `boundary <= ilog2(TCP_RTO_MAX / rto_base)`, with `rto_base = TCP_RTO_MIN`. With 200 ms and 120 s: threshold `ilog2(600) = 9`. Results:
  - `tcp_retries2 = 6` -> 127 x 0.2 = **25.4 s** (the plan says 15-20 s).
  - `8` -> 511 x 0.2 = 102.2 s, the first value above RFC 1122's 100 s (`tcp(7)`: "The RFC 1122 specified minimum limit of 100 seconds is typically deemed too short").
  - `15` (default) -> 1023 x 0.2 + 6 x 120 = 924.6 s, which is the plan's "15 minutes".
- **The bigger gap:** that first line means `tcp_retries2` only ends a socket that has **unacknowledged data in flight**. An agent waiting for a streamed model response has already sent its request. Nothing is in flight, nothing is retransmitted, and the socket waits, whatever `tcp_retries2` is. So the plan's mechanism 1 does not cover the main hang. Keepalive sysctls likewise touch only sockets with `SO_KEEPALIVE`, and `TCP_USER_TIMEOUT` (`tcp(7)`) is per-socket, set by the application.
- So the fix is `ss -K`. `ss(8)`: "-K, --kill Attempts to forcibly close sockets … It supports IPv4 and IPv6 sockets only"; PC has `CONFIG_INET_DIAG_DESTROY=y`. Kill by **source address no longer on the box or no longer the default's `src`**, for both families (`ss -K -t src <old-addr>`), not by destination port. A killed socket returns an error to the CLI at once, which is what makes it reconnect.
- Changes: keep `tcp_retries2` at 15, or 8 at most (6 also kills healthy sockets through a 30 s Wi-Fi re-scan). Drop the keepalive lines or label them "SO_KEEPALIVE sockets only". Agrees with seat 1 on git: `git-config(1)` `http.lowSpeedLimit`/`http.lowSpeedTime` (verbatim match). The repo remote is HTTPS (`git remote -v`), so they apply. `ssh_config(5)` `ServerAliveCountMax` "default value is 3", with `ServerAliveInterval`, covers SSH remotes.

### Row 10 — failover drill: agree with changes

- Agrees with seat 1: census = host agent processes (or `agent-run.tsv`), not containers; `DRY_RUN=1` default; read FENCED/UNFENCED from the watchdog log.
- Changes: (a) refuse to run unless >= 2 uplinks hold a default route. PC has 1 today, so a drill would only cut the box off. (b) Measure per family: IPv4 and IPv6 default route, and one `getent ahosts <api host>`. (c) Per-agent proof is passive (each agent's transcript or heartbeat advances after the switch), plus one probe model call and one probe `spool send`; report n of n.

## 3. Agent continuity requirements (owner d609d0e9)

| Requirement | Verdict | Evidence |
|---|---|---|
| Socket teardown | `tcp_retries2 = 6` is 25.4 s and **cannot** end a socket waiting to read; `ss -K` by old source address (IPv4 + IPv6) is the mechanism | `tcp_timer.c` `retransmits_timed_out`, `tcp_model_timeout`; `ss(8)`; `CONFIG_INET_DIAG_DESTROY=y` |
| Container DNS fallback | Not needed for agents (host processes). Host DNS already lists public servers first. The real DNS risk is the resolved residue (P1) | `/etc/resolv.conf`, `dpkg.log`, `systemctl is-enabled` |
| Beat continuity (< 120 s fence) | Met for any outage < 90 s at `WD_TICK = 30`; an early beat on a route change shortens it; the target is beat-ack age, not a 25 s gap | `spl-watchdog.func.sh`, `box_beat.go` |
| Post-drill proof, n live agents | Passive per-agent proof plus one probe call and spool send, after a 2-uplink precondition, both IP families | row 10 |

## 4. Proposals the plan missed (2)

### P1 — Pin NetworkManager's DNS mode and retire the `m-676` residue

- Today the DNS path depends on a disabled unit staying disabled. If anything enables or starts `systemd-resolved` (an upgrade, a later `apt-get install`, a well-meaning lane), it can take `/etc/resolv.conf` again. That is the 22-minute outage of 10:19-10:42Z. `NetworkManager.conf(5)` `dns` switches NM to resolved automatically when `/etc/resolv.conf` points into `/run/systemd/resolve/`.
- Proposal, as a named action with its test (`do_net_dns_pin`, `DRY_RUN=1` default, the owner's go for the root step): a `conf.d` file with `[main] dns=default` and `rc-manager=symlink`. `NetworkManager.conf(5)` on `symlink`: "If /etc/resolv.conf is instead a symlink, NetworkManager will leave it alone. Unless the symlink points to the internal file /run/NetworkManager/resolv.conf, in which case the symlink will be updated". Today's state then becomes the declared state. Then either purge `systemd-resolved libnss-resolve` (which also removes the `resolve` entry from `nsswitch.conf`), or `systemctl mask systemd-resolved`.
- Check, read-only, any time: `systemctl is-enabled systemd-resolved` -> `masked` (or not installed); `readlink /etc/resolv.conf` -> `/run/NetworkManager/resolv.conf`; `NetworkManager --print-config | grep -E '^dns=|^rc-manager='`.

### P2 — IPv6 parity in every row

- PC has a live IPv6 default route over Wi-Fi (`proto ra metric 600`) and an IPv6 DNS server in `/etc/resolv.conf`. Model APIs and GitHub answer over IPv6, so a share of agent sockets are likely IPv6 (I believe, unchecked by `ss` on PC; the lane counts `ss -t6 state established`).
- The plan is IPv4-only in practice: rows 03, 04 and 05 set `ipv6.route-metric` only in places, row 09's sysctl file is `net.ipv4.*`, and the drill reads `ip route`.
- Proposal: every row sets and proves both families. `ipv4.route-metric` and `ipv6.route-metric` are both explicit (`nm-settings-nmcli(5)`: "Note that for IPv6, the kernel accepts zero (0) but coerces it to 1024"). Row 09 kills `ss -K` sockets for both families. Row 10 times the failover on both `ip route show default` and `ip -6 route show default`. A row passes only when both show the switch.

## 5. Sources

Man pages read on PC with `man` (already installed, Debian 13 packages), same text as https://manpages.debian.org/trixie/:

- `NetworkManager.conf(5)` (network-manager 1.52.1-1), https://manpages.debian.org/trixie/network-manager/NetworkManager.conf.5.en.html: CONNECTIVITY SECTION (`enabled`, `uri`, `interval`, `timeout`, `response`, +20000, rp_filter), `dns`, `rc-manager`, `no-auto-default`, `match-device`, `wifi.powersave`.
- `nm-settings-nmcli(5)`, https://manpages.debian.org/trixie/network-manager/nm-settings-nmcli.5.en.html: `connection.autoconnect`, `connection.autoconnect-priority`, `connection.autoconnect-retries`, `connection.metered`, `ipv4.route-metric`, `ipv4.dns-options`, `ipv4.route-table`, `ipv4.routing-rules`, `match.driver`, `match.interface-name`, `802-11-wireless.powersave`.
- `NetworkManager-dispatcher(8)`, https://manpages.debian.org/trixie/network-manager/NetworkManager-dispatcher.8.en.html: empty interface on `connectivity-change`, `CONNECTIVITY_STATE`, root-owned scripts, killed when long, `no-wait.d`.
- `systemd.link(5)` and `systemd.net-naming-scheme(7)`, https://manpages.debian.org/trixie/udev/systemd.link.5.en.html: `NamePolicy=`, `Driver=`, `ID_NET_NAME_MAC`, `ID_NET_NAME_PATH`; the file `/usr/lib/systemd/network/99-default.link` (package `udev`).
- `systemd-resolved(8)`, https://manpages.debian.org/trixie/systemd-resolved/systemd-resolved.8.en.html: the four `/etc/resolv.conf` modes.
- `tcp(7)`, https://manpages.debian.org/trixie/manpages/tcp.7.en.html: `tcp_retries2`, `TCP_USER_TIMEOUT`. `ss(8)`, https://manpages.debian.org/trixie/iproute2/ss.8.en.html: `-K`. `ip-route(8)`. `resolv.conf(5)`. `git-config(1)`: `http.lowSpeedLimit`. `ssh_config(5)`: `ServerAliveCountMax`.

Source code, fetched read-only:

- Linux v6.12 `net/ipv4/tcp_timer.c`: `tcp_model_timeout()`, `retransmits_timed_out()` (https://raw.githubusercontent.com/torvalds/linux/v6.12/net/ipv4/tcp_timer.c).
- NetworkManager tag `1.52.1`: `src/core/devices/nm-device.c` `nm_device_get_route_metric_default()` (ethernet 100, Wi-Fi 600); `src/core/devices/nm-device-ethernet.c` auto-default `AUTOCONNECT_PRIORITY_MIN` (https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/tree/1.52.1).
- Repo `origin/master`: `csi-spl-orc/src/bash/run/spl-watchdog.func.sh` (`WD_TICK`, `spl_wd_fence`, `spl_wd_beat`), `csi-spl-api/src/go/spool-hub-api/internal/hub/box_beat.go` (`boxDownMin`).

Not verified (marked in the text): the kernel's name-assign type for `usb%d`; the share of IPv6 agent sockets; the drop history (the journal is not readable within this seat's limits).

## Signature

signed: c-719 on bfb56e90d0721afb848f0d2803eabd451c43638e
