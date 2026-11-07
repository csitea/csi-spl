**Answer (machine lens).** The machines did not get 3 times slower: the same gate parts took about the same time on 11-06 as on 11-05 (within about 15%, section 3.2). Output fell because capacity was missing: the laptop was off the network or suspended for 14.7 h of 24, and for about 6.9 h new lanes were refused on a stale 97% Claude reading, which left the satellite near idle (and the laptop, until it suspended).
Only about 21 of 48 box-hours were usable (44%), which accounts for about 82% of the drop from a median day, not all of it; the rest is not established. Nothing new started on the machines: load, system time and fork rate on 11-06 are inside the range of the previous 10 days, and no reboot or new heavy cron explains the day.
System time near 40% on the satellite is real but old: it was there on every day since at least 10-28. It comes from process creation (about 1,400 forks/s, r = 0.78 with system time); cron jobs alone hold 5.2 of its 16 cores, averaged since boot.
The felt "3 times slower" has a measured candidate: a gate takes about 4 times longer on the satellite than on the laptop (p50 839 s vs 206 s on 11-06), so losing the laptop moves the remaining work to the slower box. That link is suggested, not demonstrated.

Seat claude-1, lens: the machine. Measured 2026-11-07 00:53-01:00Z, tree `origin/master` 04a51b255. "Laptop" and "satellite" are the two boxes; both have 16 CPUs and 62 GiB.

## 1. Timeline, 2026-11-06 (UTC)

| time | what | source |
|---|---|---|
| 00:20-07:15 | laptop link down, 6.9 h. The box stayed awake: 74% idle, about 1,000 forks/s. Lanes there were cut off | uplink probe tsv, `tcp_ok`; its log shows gateway loss 100%; sar; no suspend event in that span |
| 09:20 | new lanes refused: "waiting: claude weekly >= 90%", a kept row at 97%. The start time is the holder's report | commit fe0455e48 body for the wording. I did not read a log line for 09:20 |
| 09:30-09:40 | satellite user CPU falls from 40% to 17%; idle from 24% to 49% | sar, 10-min samples |
| 10:00-16:59 | 0 master commits in 7 consecutive hours | `git log`, per-hour count |
| 14:32-18:50 | laptop suspended: "Lid closed", 4.3 h | journal, `systemd-logind` |
| 16:12 | kept row removed by hand | commit fe0455e48 body |
| 16:20-16:50 | satellite idle goes from 55% to 1%; load peaks at 144 within the 16Z hour | sar; `box_stats` |
| 19:25-22:55 | laptop suspended again: "Lid closed", 3.5 h | journal, `systemd-logind` |
| 23:00 onward | laptop back; 10 commits in the 23Z hour | `git log` |

Both edges of the idle window sit within about 20 min of the reported hold. That timing is strong evidence the hold caused it, but I did not trace a lane being refused.

## 2. Usable capacity on 11-06

| box | hours | lost to |
|---|---|---|
| satellite | 17.1 of 24 | hold 6.9 h |
| laptop | 4.1 of 24 | link 6.9 h, suspend 7.8 h, hold while online 5.2 h |
| together | 21.2 of 48 (44%) | |

Commits by committer date: 11-05 161, 11-06 36, and the median of 10-25..11-05 is 113 (n = 12 days). 11-05 was a high day, not a typical one.
- Commits per usable box-hour: 11-06 1.7 (36 / 21.2); 11-05 3.4 (161 / 48); a median day 2.4 (113 / 48).
- Lost hours alone would take a median day from 113 to about 50, which is 63 of the 77 commits lost (82%). Against 11-05 the same sum explains 90 of 125 (72%). The remaining drop per usable hour is not explained by this lens. Treating all box-hours as equal is a simplification: section 3.3 shows they are not.

Per-hour commits, 00Z to 23Z:

```
11-05: 2 4 8 7 7 2 27 13 1 9 0 14 5 3 1 3 5 4 4 15 9 10 4 4
11-06: 0 0 0 1 2 1 0 5 4 3 0 0 0 0 0 0 0 5 2 1 2 0 0 10
```

## 3. Evidence

### 3.1 CPU, load and forks per day

sar averages per day, 10-min samples (n = 144 for a full day). Laptop 11-06 has n = 99 because it was suspended. Load is the `box_stats` daily average of `load1`. The sar and `box_stats` columns come from different sources.

| day | sat user | sat sys | sat idle | sat fork/s | sat load | lap user | lap sys | lap idle | lap fork/s | lap load |
|---|---|---|---|---|---|---|---|---|---|---|
| 10-28 | 43.3 | 44.6 | 10.1 | 1683 | 33.1 | 27.6 | 25.8 | 46.3 | 1963 | 16.8 |
| 10-29 | 34.5 | 39.0 | 24.5 | 1423 | 27.7 | 35.5 | 29.4 | 34.8 | 2201 | 19.6 |
| 10-30 | 43.4 | 43.5 | 11.4 | 1577 | 42.3 | 36.5 | 29.8 | 32.8 | 2226 | 22.0 |
| 10-31 | 44.3 | 43.7 | 10.1 | 1502 | 45.0 | 37.5 | 28.7 | 33.4 | 1852 | 33.4 |
| 11-01 | 30.3 | 32.6 | 35.3 | 1198 | 22.8 | 36.0 | 26.3 | 37.4 | 1889 | 22.5 |
| 11-02 | 37.8 | 34.2 | 25.9 | 1033 | 30.5 | 33.4 | 25.5 | 40.6 | 1852 | 25.2 |
| 11-03 | 24.8 | 28.8 | 43.8 | 1007 | 19.7 | 39.1 | 29.4 | 31.2 | 2093 | 27.5 |
| 11-04 | 44.4 | 42.6 | 11.1 | 1447 | 37.7 | 44.3 | 34.8 | 20.6 | 2472 | 34.4 |
| 11-05 | 42.3 | 42.2 | 13.3 | 1377 | 35.1 | 42.6 | 34.0 | 23.0 | 2420 | 28.6 |
| 11-06 | 33.3 | 40.5 | 23.8 | 1331 | 31.3 | 19.8 | 20.4 | 59.1 | 1265 | 14.8 |

11-06 was a quieter day than 11-05 on both boxes, not a heavier one.

Satellite, 11-06 per hour (hour: user/sys/idle, fork/s):

```
00 45/41/11 1380   06 37/52/ 9 1806   12 11/24/63  754   18 36/48/14 1565
01 41/39/17 1185   07 42/51/ 6 1615   13 10/23/66  746   19 40/50/ 8 1625
02 44/36/17 1061   08 38/46/13 1506   14 14/30/54  942   20 44/47/ 6 1516
03 41/45/ 9 1207   09 31/37/29 1157   15 16/30/54  994   21 37/48/13 1608
04 38/45/ 8 1430   10 13/26/60  831   16 29/38/32 1314   22 41/48/10 1802
05 51/46/ 2 1530   11 11/23/65  750   17 49/47/ 3 1661   23 42/53/ 3 1950
```

Same satellite window, 17-23Z (n = 7 hours each): 11-05 user 45.0, sys 43.7, idle 8.9, 1427 fork/s. 11-06 user 41.0, sys 48.7, idle 8.3, 1676 fork/s. System time and forks rose about 5 points and 17%, one evening each, so a small sample. On the holder's 00:21-00:44Z read: 11-07 00Z had idle 1.9% (n = 6 samples), and an hour or stretch that idle also occurred on 11-06 at 05Z and 16:50-17:10Z, so it is a saturated moment rather than a new state.

### 3.2 The same work: gate parts, median seconds

Tier `fast`, verdict PASS, from each box's `~/.cache/csi-spl/pre-push.log` (n in brackets).

| part | sat 11-03 | sat 11-04 | sat 11-05 | sat 11-06 | lap 11-05 | lap 11-06 |
|---|---|---|---|---|---|---|
| api | 219 (10) | 253 (13) | 268 (23) | 253 (10) | 225 (25) | 206 (10) |
| iac | 253 (7) | 394 (7) | 373 (3) | 416 (6) | 158 (4) | 366 (2) |
| orc-features | 200 (8) | 279 (19) | 260 (11) | 264 (12) | 210 (21) | 217 (2) |
| wui | 405 (18) | 583 (8) | 563 (3) | none | 192 (46) | 224 (2) |
| wui-e2e | 510 (15) | 807 (16) | 633 (5) | 565 (9) | 481 (33) | 271 (2) |

- On the satellite, 11-05 to 11-06 moves -11% to +12% on the four parts with data for both days. The laptop rows have n = 2 for most of 11-06, so they are weak.
- The `orc` part is left out: its median swings 7 s to 331 s with what a change touched, so it is not fixed work.
- A real step is visible on the satellite on 11-04: wui 405 to 583, e2e 510 to 807, iac 253 to 394. On 11-03 to 11-04 the satellite load went from 19.7 to 37.7; concurrent gates there averaged 2.1 and 2.0 on those two days, so concurrency does not explain the step. 11-05, the good day, already carries the slower numbers, so this step did not cause the 11-06 fall.
- Thin data after midnight: 11-07 orc-features 606 s (n = 2), whole gate p50 1867 s (n = 7). That may be a catch-up surge. It is not enough to call a new slowdown.

### 3.3 Whole gate span

First part start to last part end, per tree + HEAD, tier `fast`, at least 8 parts, seconds.

| day | sat n | sat p50 | sat p90 | lap n | lap p50 | lap p90 |
|---|---|---|---|---|---|---|
| 10-31 | 95 | 1031 | 2975 | 181 | 176 | 1349 |
| 11-03 | 90 | 862 | 2945 | 114 | 230 | 1469 |
| 11-04 | 111 | 915 | 2878 | 220 | 225 | 1925 |
| 11-05 | 121 | 366 | 1981 | 236 | 79 | 1068 |
| 11-06 | 68 | 839 | 2758 | 31 | 206 | 606 |

- A gate of "about 50 min" is real and not new: satellite p90 was 49.6 min on 10-31 and 46 min on 11-06.
- This measure is rough. A re-run on the same HEAD stretches a span (the largest are over 6 h), and cached runs pull p50 down. The change mix differs per box.
- The satellite is slower than the laptop on every row, by 3.7 to 5.9 times at p50 and 1.5 to 4.5 times at p90. Part medians differ less (api 1.2 times, wui 2.9 times on 11-05).

### 3.4 Which box lands the commits

Master commits joined to the HEAD each box's gate log recorded, 10-31..11-06.

| | laptop only | satellite only | both | unmatched |
|---|---|---|---|---|
| 10-31..11-05 | 212 | 97 | 56 | 270 |
| 11-06 | 7 | 12 | 4 | 13 |

- Unmatched is large; a rebase after the gate changing the sha is my assumed reason, not checked. So these are partial counts. Among matched commits the laptop lands about twice what the satellite does.
- 17-23Z satellite-only plus both: 11-05 7, 11-06 6 (21 and 4 unmatched). Laptop-only: 18 and 0. This suggests the satellite's output held steady and the laptop's share vanished. n is small and the unmatched rows could change it.

### 3.5 Why system time is about 40%

- It is old. Satellite sys/user is 0.91 to 1.22 on all 11 days 10-28..11-07, sys 28.8 to 47.8%. Laptop sys has climbed from 14.7-20.8% on 10-15..10-21 to 34% on 11-04 and 11-05, with heavier use. I read that older history on the laptop only.
- It tracks process creation. Per 10-min sample, sys% against fork/s: satellite r = 0.78, n = 1455, slope 1.63 points per 100 forks/s, intercept 17. Laptop r = 0.80, n = 1300, slope 0.86, intercept 11. A fork costs the satellite about twice what it costs the laptop. Why (a virtual machine is one guess) is not established.
- Live rates at 00:54Z over 10 s: laptop 2568 forks/s and 61,558 context switches/s; satellite 1864 and 27,130.
- Cron alone is large. CPU from `system.slice/cron.service/cpu.stat`, averaged since boot over 142 h:

  | box | cron user | cron sys | total sys, whole box | cron share of sys |
  |---|---|---|---|---|
  | satellite | 1.6 cores | 3.6 cores | 5.7 cores | 63% |
  | laptop | 1.1 cores | 2.3 cores | 3.8 cores | 61% |

  Claude, the pre-push gates and the test postgres are not in that cgroup: `/proc/<pid>/cgroup` puts them in user sessions and docker (n = 1 process checked for each). The watchdog is in it. So 5.2 of the satellite's 16 cores go to cron scaffolding before any lane runs.
- A floor with almost no lane work: the satellite at 10-15Z on 11-06 ran at sys 23-30%, user 10-16%, 746-994 forks/s, load 5.8-9.4, with `agents_live` at 9-14.
- What forks. A 25 s sample of new pids by owning `./run` action:

  | action | satellite (3230 caught) | laptop (2638 caught) |
  |---|---|---|
  | `do_spl_watchdog` | 1315 (41%) | 597 (23%) |
  | `do_check_pre_push` | 970 (30%) | 604 (23%) |
  | under a claude process | 33 (1%) | 302 (11%) |
  | all else | 912 | 1135 |

  The sampler caught only 5-7% of forks (polling /proc), so very short processes are under-counted. n = 1 window per box. These shares order the suspects; they are not a measurement of cost. By name, about 60% of the new pids are `bash` or `run`.
- A `./run` action start sources 626 `*.func.sh` files. Timed on the laptop at load about 40, three runs of a lease `show`: 0.65-0.70 s wall, 0.46-0.49 s user, 0.19-0.26 s sys. Crontabs hold 18-20 every-minute rows per box (63-71 rows in all). At that cost the start-up of those rows is about 0.25 core, so the start-up is not the main spend; the work inside the ticks is.
- The watchdog started with the boot and walks every local agent every 30 s (`WD_TICK`). Its action file last changed on 11-05 (172f19775, alarm kinds), so I see no sign of a new cost, but I have no per-tick CPU history to prove that.

## 4. Ruled out

| suspect | finding |
|---|---|
| A reboot or crash | both boxes up 5 d 22 h at measurement, last boot 11-01 |
| Memory | satellite 34 GiB available and no swap on 11-05 and 11-06. Laptop 38-41 GiB available; swap 14-17 GiB used, and paging was 2 KB/s in and 0 out in the vmstat samples at 00:53Z (n = 2) |
| Disk | iowait average 0.43% satellite, 0.19% laptop. One satellite sample reached 45.6%; I did not chase it |
| New cron on 11-05 | both crontabs were rewritten on 11-05 (04:34Z laptop, 05:38Z satellite), and the link watcher's log dir appeared at those minutes. It is a small share: `do_spl_box_link_watch` 2 of 2638 sampled pids on the laptop, none listed on the satellite. I did not diff the old crontab because I read no copy of it |
| journald | 0.0 core by cgroup, though the line rate is high: 13,543 lines in 10 min on the satellite at 00:00Z, and sudo logs long base64 commands |
| Docker, test postgres | 0.0-0.2 core by cgroup at my read. 15 postgres processes on the satellite at 8.3% CPU. The holder's 23 backends in BIND were not reproduced at my one read (n = 1), so this does not rule them out for that moment |
| Chrome | 42% of one core on the laptop; not in the top consumers on the satellite at my read |

Noted, no effect found: 95 idle `gpg-agent` processes on the laptop against 2 on the satellite, none younger than 1 h. Probably left by tests, not established.

## 5. What I could not read

- Per-process CPU over time: no process accounting exists that I found, and sar keeps totals only. So "what consumed it on 11-05" can be answered only by cgroup since boot and by today's sample, not per day.
- Cron's share per day: the cgroup counter is cumulative since 11-01.
- Why the laptop link dropped at 00:20Z. The network journal returned no lines for that span before 06:50Z, and I did not establish why. The lid-closes are logged; who closed it and why is not a machine fact.
- The 09:20Z start of the hold, from a log. The fe0455e48 body itself says no log holds the 97 read.
- Agent idle time, turn lengths and queue waits, including the p90 jump on 11-03. These belong to other lenses and I did not measure them.
- The remaining drop per usable hour (section 2).

## 6. How not to repeat it

These are proposals for the editor. I changed nothing.

1. **Make lost capacity loud.** A box off the network or suspended for over 15 min, and new lanes refused for over 30 min, should each raise one alert naming the cause. 11-06 lost 6.9 h to each of the link and the hold. I did not check which alerts did fire. The hold's own bug is fixed by SPL-4932.
2. **Decide what the laptop is.** It lands the larger share of matched commits, yet it runs on Wi-Fi and suspends on a lid-close. Either stop suspend on lid-close and give it a wired link, or plan on it being absent and move the fast gate capacity elsewhere. This is the owner's call.
3. **Measure the satellite's gate gap.** The same parts run up to 2.9 times longer there. Find out whether that is the fork cost, the load or the machine, before moving more lanes onto it.
4. **Cut the fixed cost, measuring first.** Cron takes 5.2 of 16 cores before any lane runs. Run each cron family in its own cgroup scope for a day to get a real per-action cost, then cut the top one. Candidates only, from a biased sample: the watchdog tick.
5. **Keep the history.** Add sys%, fork/s and cron cgroup CPU to the `box_stats` row, so the next "what changed" is one query, and chart commits per usable box-hour instead of commits per day.

## 7. How to re-measure

Run on each box, reading only:

- CPU and forks: `LC_ALL=C sadf -d -U /var/log/sysstat/sa<DD> -- -u` and `-- -w`. The fields are sar's; average them per hour or day in UTC.
- Load and agents: `ENV=prd SQL="select box, date_trunc('hour',at), count(*), avg(load1), max(load1), avg(mem_avail_kb), avg(swap_used_kb), avg(agents_live) from box_stats where at >= '2026-10-28' group by 1,2 order by 1,2" ./run -a do_spl_db_query`
- Cron cost: `cat /sys/fs/cgroup/system.slice/cron.service/cpu.stat`, divided by uptime.
- Commits: `git log origin/master --since=2026-10-25T00:00Z --format=%cI`, grouped per UTC hour.
- Link: the uplink probe's per-box tsv under `/var/csi/csi-spl/uplink-probe/`, field 5 `tcp_ok`.
- Suspend: `journalctl --utc -t systemd-logind --since '2026-11-05 20:00'`, grep `Lid|Suspending`.
- Gate: `PART` lines in `~/.cache/csi-spl/pre-push.log` of every home on the box.
