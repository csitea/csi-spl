# Box sleep policy: awake on AC, lid close still sleeps

Issue SPL-2269. Owner HUM-10, poll 40d40bd0, answer A (msg 4a5233ef): "Keep it
awake while plugged in (agents keep running; lid close still sleeps)".

## 1. What the action sets

`cd csi-spl-orc && ./run -a do_box_sleep_policy`
(`csi-spl-orc/src/bash/run/box-sleep-policy.func.sh`, test
`csi-spl-orc/src/bash/tests/box-sleep-policy.tst.sh`)

| layer | setting | effect |
|---|---|---|
| systemd-logind drop-in `/etc/systemd/logind.conf.d/50-csi-spl-sleep-policy.conf` | `IdleAction=ignore`, `HandleLidSwitch=suspend`, `HandleLidSwitchExternalPower=suspend` | logind never idle-suspends; closing the lid suspends on battery and on AC alike |
| GNOME gsd-power, for the user who runs the action (the desktop user) | `sleep-inactive-ac-type 'nothing'` | no idle suspend on AC; the battery keys are not touched |

- `DRY_RUN=1` (the default) prints the drop-in and the commands. `DRY_RUN=0`
  writes them. A second run changes nothing.
- logind reads the drop-in on `systemctl reload systemd-logind` (SIGHUP). The
  action never restarts logind, because a restart can end the graphical session.
- `SLEEP_POLICY_CMD=show` reads back logind's live properties, the drop-in,
  the gsettings keys, AC online, the battery and UPower's `CriticalPowerAction`.
- GNOME 48's default for a user who never changed the key is
  `sleep-inactive-ac-type 'suspend'` after 900 s. So run the action as the
  desktop user, since gsettings is per user.

## 2. What put the main box to sleep on 2026-10-16 (measured, n=1)

The sleep from 19:54Z to 20:01Z was **not** an idle suspend. It was UPower's
critical-battery action:

- `journalctl -b 0`: `19:54:21Z systemd-logind: The system will hybrid sleep now!`.
  That boot logged no lid event.
- `/etc/UPower/UPower.conf`: `CriticalPowerAction=HybridSleep`,
  `PercentageAction=2.0`.
- `/var/lib/upower/history-charge-*.dat` for BAT0: 79 % charging at 18:29Z,
  then discharging at about 33 W (`history-rate`) to 4 % at 19:52Z. The box
  slept at the action level and woke at 20:01Z, charging from 0 %.
- Idle suspend on AC was already off at the time: the desktop user's
  `sleep-inactive-ac-type` was `'nothing'`, and logind's `IdleAction` was
  `ignore`.
- The same drain came back that evening: 39 % at 20:56Z, 13 % at 21:27Z. AC
  `online=1` and the USB-C source reported 20 V / 5 A. Under the box's load the
  battery still drained in phases.

So the policy above pins the owner's choice, but it would not have prevented
that sleep. A battery that drains while plugged in reaches the critical action
whatever the idle settings are. The fix for that is on the power side: the
charger, the cable or dock, or the load. The action leaves the UPower critical
action alone, because without it the box powers off hard at 0 %. `show` prints
the critical action and the battery state, so a read-back makes the risk visible.
