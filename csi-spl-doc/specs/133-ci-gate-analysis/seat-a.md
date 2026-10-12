# 133 seat A: wall time, queue wait and runner capacity

Seat A (c-298, claude), draft v0.1, 2026-10-12. The question: **of the
gate's ~47 min, how much is waiting and how much is running, and is runner
capacity the cause?**

## 0. Answer first

| view | n | median | waiting | running |
|---|---|---|---|---|
| one completed run, push to its last job | 82 | 43.0 min | **35%**: 12% before its jobs exist, 23% runner queue on the critical path | **63%** (2% `needs:` gaps) |
| one push, to the first verdict that covers it | 809 | 72.9 min | **67%**: 53% in line behind the run already going, 14% runner queue | **33%** |

- With a free runner for every job, a run still lasts as long as its
  critical path: **32.9 min p50** (classify, nuxt generate, the slowest e2e
  shard, gate health). An e2e shard is the critical job in **70 of 82**
  completed runs.
- Runners are a real but second cost. On average **4.22 of 6** were online.
  **62%** of all job-queue minutes fell in minutes with 3 or fewer runners
  online, while the runners that were online were busy **76%** of the time.
- Box load stretches the e2e shard from **27.4 min** p50 (the rest of the box
  under 3 cores) to **36.0 min** (6 cores or more): +31%, n=33 / 24.
- No single run can keep up with the cadence. Pushes come at 12.9 an hour and
  verdicts at 1.32 an hour, so **~9.7 pushes share one verdict**.

## 1. Data, tree and method

| item | value |
|---|---|
| runs | wf 10 (`10_ci-quality.yml`) on master, the newest 1000, fetched 2026-10-12T06:31Z (appendix A, command 1) |
| jobs | `gh api "repos/csitea/csi-spl/actions/runs/<id>/jobs?per_page=100&filter=latest"` for each of the 1000 (appendix A, command 2) |
| window | **the last 100 runs that ran at least one job**, so no superseded pending run: created 2026-10-09T14:27:11Z .. 2026-10-12T05:17:55Z, 62.8 h. Their conclusions: 74 failure, 18 cancelled, 8 success. **809** runs were created in the window; **709** of them have 0 jobs (superseded while pending) |
| workflow tree | timeouts from `origin/master` = `b3fe09647`: `git show origin/master:.github/workflows/10_ci-quality.yml \| grep -n timeout-minutes` |
| runner log | sat `/var/csi/csi-spl/gh-runner-cpu-budget/cron.out`, written each minute by the cron of `do_setup_gh_runner_cpu_budget_cron`. Its `CAP`, `BUDGET`, `GATE` and `PARKED` lines: 14,786 from 2026-10-08T06:03Z to 2026-10-12T06:35Z |
| definitions | queue = job `started_at - created_at`; run = `completed_at - started_at`; minutes; percentiles linearly interpolated |
| reproduce | appendix A: four fetch commands, then `python3 -I seat-a.py <dir>`, which prints every number below |

Cross-check with the repo action: `cd csi-spl-iac && CI_GATE_RUNS=100 ./run -a do_report_ci_gate`
(worktree HEAD `36c185fec`, 06:45Z). It reads the last 100 runs *of any
kind*, which reach back only to 2026-10-11T19:46:55Z (85 cancelled, 8 failure,
3 success, 3 running, 1 timeout). Its headroom therefore has **n=12** per job.
Section 4 quotes it as the recent worst case.

## 2. Per job: queue wait vs run time (n=100 runs)

| job | n | queue p50 | queue p90 | run p50 | run p90 | run max | failed |
|---|---|---|---|---|---|---|---|
| wui e2e 2/3 | 97 | 1.2 | 12.4 | 27.4 | 42.9 | 45.4 | 50 |
| wui e2e 3/3 | 97 | 0.7 | 14.2 | 26.6 | 39.8 | 45.4 | 60 |
| wui e2e 1/3 | 97 | 1.0 | 10.5 | 25.1 | 38.7 | 45.4 | 51 |
| hub go | 100 | 0.1 | 8.3 | 14.8 | 29.2 | 35.7 | 73 |
| orc hermetic 2/2 | 100 | 0.5 | 15.8 | 11.1 | 20.7 | 31.1 | 65 |
| orc hermetic 1/2 | 100 | 0.6 | 12.2 | 10.2 | 20.6 | 29.0 | 67 |
| iac | 100 | 0.6 | 12.5 | 6.4 | 9.5 | 22.0 | 32 |
| wui unit + typecheck | 100 | 0.5 | 11.2 | 6.4 | 9.8 | 16.3 | 2 |
| wui nuxt generate | 100 | 0.0 | 9.7 | 5.3 | 9.1 | 16.5 | 21 |
| orc features | 100 | 0.1 | 13.2 | 4.8 | 8.1 | 15.8 | 20 |
| cnf | 100 | 0.0 | 13.9 | 0.6 | 1.3 | 15.0 | 0 |
| gate health | 88 | 0.0 | 0.9 | 0.3 | 0.6 | 1.9 | 0 |
| classify | 100 | 0.0 | 0.5 | 0.2 | 0.3 | 0.8 | 0 |
| distribution-hygiene | 100 | 0.0 | 0.3 | 0.2 | 0.3 | 0.7 | 0 |
| box-reference ban | 100 | 0.0 | 0.2 | 0.2 | 0.2 | 10.0 | 0 |

`pr-sec-scan` was skipped in all 100 runs: it runs on pull requests only.

The median job starts within a minute, but **every runner job has a queue p90
of 8 to 16 min**. Each run asks for 13 runner jobs at about the same time:
10 after classify, then 3 e2e shards after nuxt generate. One run sums to
**130.2 runner-min p50, 214.9 p90**.

## 3. One run: where its wall time goes (n=82 completed runs)

The critical path runs through classify, then the job that finished last before
gate health (for an e2e shard, nuxt generate comes first), then gate health.
The job that finished last was an e2e shard 70 times, wui unit 5, orc
features 3, iac 2 and hub go 2.

| part | p50 | p90 | mean | share of summed wall |
|---|---|---|---|---|
| wall, push to last job | 43.0 | 63.1 | 39.7 | 100% |
| before any job exists (the previous run still holds the concurrency slot) | 2.3 | 8.6 | 4.6 | 12% |
| runner queue on the critical path | 6.5 | 24.0 | 9.2 | 23% |
| run time on the critical path | 32.9 | 47.7 | 25.0 | 63% |
| gaps between `needs:` | 0.0 | 0.0 | 0.9 | 2% |

Across all 100 runs, cancelled ones included, the wall is **45.1 min p50,
63.4 p90**. That matches the panel's 47 min (a different window, n=629).

## 4. Time-limit headroom

My window, n=100 runs. "At limit" = a run of at least `timeout-minutes`
minus 0.5 min.

| job | limit | run p90 | headroom at p90 | at limit |
|---|---|---|---|---|
| wui e2e 2/3 | 45 | 42.9 | **2.1** | 8 / 97 |
| wui e2e 3/3 | 45 | 39.8 | 5.2 | 4 / 97 |
| wui e2e 1/3 | 45 | 38.7 | 6.3 | 4 / 97 |
| hub go | 35 | 29.2 | 5.8 | 2 / 100 |
| wui unit + typecheck | 15 | 9.8 | 5.2 | 4 / 100 |
| wui nuxt generate | 15 | 9.1 | 5.9 | 3 / 100 |
| orc features | 15 | 8.1 | 6.9 | 3 / 100 |
| orc hermetic 2/2 | 30 | 20.7 | 9.3 | 3 / 100 |
| orc hermetic 1/2 | 30 | 20.6 | 9.4 | 0 / 100 |
| iac | 20 | 9.5 | 10.5 | 1 / 100 |
| cnf | 10 | 1.3 | 8.7 | 1 / 100 |

**33 of the 1,091 job runs in the table reached their limit.**

The recent worst case, `do_report_ci_gate` (n=12, since 2026-10-11T19:46Z),
marks **6 of 13 jobs AT RISK**, meaning their p90 is over 75% of the limit:

- orc hermetic 2/2 at 101% (1819 s of 1800)
- orc hermetic 1/2 at 96%
- e2e 1/3 at 94%
- hub at 93%
- e2e 2/3 at 90%
- e2e 3/3 at 87%

Its failed-run list holds **3 `timeout:` job failures and 1 `runner-lost:`**
(`grep -oE '\|\| [a-z-]+:'` on its output, then `uniq -c`). A timeout red is a
verdict on load, not on code. The reds belong to seat B. This seat cares about
headroom because a loaded box pushes jobs over their limits.

## 5. Push to verdict (n=809 pushes)

For each push, the verdict is the first completed success-or-failure run
created at or after it. Master is linear, so that run tests a tree that
contains the push.

| measure | p50 | p90 | mean |
|---|---|---|---|
| push to verdict | **72.9** | 154.2 | 88.8 |
| in line: push to the first job of that verdict run | 27.0 | 97.4 | 46.7 |
| runner queue on that run's critical path | 7.9 | 33.3 | 12.7 |
| run time on that critical path | 38.2 | 48.9 | 29.4 |
| push to the first **green** that covers it | 1006 (16.8 h) | 2387 | |

- The window has **83 verdicts**. The gap between two verdicts is p50 38.7,
  p90 89.9 and max 312.6 min.
- 809 pushes in 62.8 h is 12.9 an hour; 83 verdicts is 1.32 an hour.

**In line** is cadence, not capacity: a push waits for the run already going.
That wait grows with run time. So every minute cut from the critical path saves
a push about two minutes: one in line, one running.

## 6. Runner capacity on sat

**Online runners over time**, from 3,819 `CAP online=<n> of 6` ticks in the
window:

| online | minutes | share |
|---|---|---|
| 6 | 1,196 | 31% |
| 5 | 716 | 19% |
| 4 | 504 | 13% |
| 3 | 800 | 21% |
| 2 | 331 | 9% |
| 1 | 267 | 7% |
| 0 | 5 | 0% |

The mean is **4.22 online**. Hourly means range from **1.0** (10-09 23Z) to
**6.0** (03Z on 10-10 and on 10-11). From 10-11 22Z, when the fleet was
paused, they stayed near 5.8.

- **Busy vs online.** 12,299 busy runner-min out of 16,103 online runner-min:
  the online runners were **76% utilised**. Over 3,820 min, all 6 runners were
  busy in 516 min (14%) and 3 were busy in 1,370 min (36%).
- **Queue vs parking.** Of 6,073 job-queue minutes, **3,743 (62%)** fell in
  minutes with 3 or fewer runners online (1 online: 1,500; 2: 921; 3: 1,322).
  The budget cron `PARKED` an idle runner **396 times** in the window.
- **The starvation floor is the normal state.** **1,012 of 2,591** `GATE` ticks
  (39%) read `GATE STARVED ... last verdict >= 40 min ago`, which lifts the
  floor to 500%. In those minutes the gate was already past its own 40 min
  stale mark.

**Load on sat vs job time.** `BUDGET ... others=<x> cores` is the box's
non-runner CPU (agents and the rest) over 20 s. In the window it was **p50 6.2,
p90 13.4 and max 15.9 of 16 cores** (n=3,819). Run time of *successful* jobs,
bucketed by the mean `others` while each job ran:

| job | others < 3 cores | 3..6 | >= 6 |
|---|---|---|---|
| wui e2e (all shards) | 27.4 (n=33) | 30.9 (n=51) | **36.0** (n=24) |
| hub go | 19.5 (n=7) | 26.4 (n=12) | 29.2 (n=6) |
| orc hermetic | 14.0 (n=14) | 20.3 (n=24) | 16.0 (n=3) |
| iac | 5.1 (n=9) | 6.1 (n=26) | 6.0 (n=32) |
| nuxt generate | 4.5 (n=12) | 5.5 (n=29) | 5.4 (n=35) |

The CPU-bound jobs on the critical path (e2e, hub) run 30 to 50% slower under
agent load, while iac and generate barely move. Several hub and hermetic cells
hold n<=7, so read those rows as a suggestion, not a demonstration.

**Can 6 runners hold one run?** 130.2 runner-min p50 per run over 6 runners is
21.7 min, less than the 32.9 min critical path. With all 6 online a run is
bound by its path, not by capacity. At the mean of 4.22 online it is
130.2 / 4.22 = 30.9 min, about the length of the path. That is why the runner
queue shows up as 23% of a run.

## 7. What this means for the axis set

1. **The critical path is the biggest lever.** It is 63% of a run and counts
   about twice for a push, and it is the e2e shard plus nuxt generate. Making
   it shorter (seat D, slow suites) or skipping it when nothing it covers
   changed (seat C, selection) is worth more than any runner change.
2. **The runner queue (23%) is mostly parking.** 62% of queue minutes fell in
   minutes with 3 or fewer runners online, and the online ones were 76% busy.
   Keeping all 6 online *while a gate run has queued jobs* would remove most of
   that queue. It still has to hold the owner's rule that CI and agents leave
   20% of the cores free (owner HUM-10, t1 msgs b7917da5 and b3573121:
   `grep -n "leave 20% of the cores free" csi-spl-orc/src/bash/run/apply-gh-runner-cpu-budget.func.sh`
   gives line 5; the box ceiling defaults to 80% and is the hub's fleet-load
   setting `runner_cpu_pct`, which read `ceiling=80% (hub, box sat)` in
   cron.out). That makes it a budget-policy question for the editor, not a
   fix from this seat.
3. **Box load adds ~30% to e2e** and pushes jobs over their limits: 3 timeout
   reds in the last 12 runs. Headroom is the cheapest guard against false
   reds caused by load.
4. **Cadence (53% of push to verdict) falls only when run time falls.** Pushes
   arrive about 9.7 times faster than verdicts.

## 8. Measurable axes (seat A)

Each baseline is the 100-run window of section 1. Each command is the
`python3 -I seat-a.py <dir>` of appendix A; the column names the line to read.

| # | axis | measurement | baseline now | target |
|---|---|---|---|---|
| A1 | **push to verdict**, p50 / p90 min | `push-level` block, line `total` | **72.9 / 154.2** (n=809) | p50 <= 30, p90 <= 60 |
| A2 | **critical-path run time** of a completed run, p50 min | `critical path` block, line `run_on_path` | **32.9** (n=82) | <= 20 |
| A3 | **runner queue on the critical path**: p90 min, and its share of summed wall | `critical path` block, lines `queue_on_path` and `share of summed wall` | **24.0 min, 23%** (n=82) | p90 <= 3, share <= 5% |
| A4 | **job-queue minutes with 3 or fewer runners online**, share of all queue minutes | line `job-queue minutes by online runners` | **62%** (3,743 / 6,073) | <= 10% |
| A5 | **timeout headroom**: jobs AT RISK (p90 over 75% of `timeout-minutes`) | `cd csi-spl-iac && CI_GATE_RUNS=100 ./run -a do_report_ci_gate`, block `timeout headroom` | **6 of 13** (n=12) | 0 of 13 |

## Appendix A. Reproduce

Run in an empty directory, with `GH_TOKEN` set for the repo. The last command
runs on sat as the box user.

1. The runs:

```bash
gh run list -R csitea/csi-spl --workflow 10_ci-quality.yml --branch master --limit 1000 --json databaseId,status,conclusion,createdAt,updatedAt,headSha > runs.json
```

2. The jobs of each run. Each run gets its own file, because parallel writers
   to one file interleave their records:

```bash
mkdir -p jobs && jq -r '.[].databaseId' runs.json | xargs -P8 -I{} sh -c 'gh api "repos/csitea/csi-spl/actions/runs/{}/jobs?per_page=100&filter=latest" --jq "{run:{}, jobs:[.jobs[]|{name,status,conclusion,created_at,started_at,completed_at,runner_name}]}" > jobs/{}.json'
```

3. One line per run:

```bash
for f in jobs/*.json; do tr -d '\n' < "$f"; echo; done > jobs.jsonl
```

4. The runner budget lines, on sat:

```bash
grep -E ' (CAP|BUDGET|GATE|PARKED|UNPARKED) ' /var/csi/csi-spl/gh-runner-cpu-budget/cron.out > cron.txt
```

5. Save the script below as `seat-a.py` and run `python3 -I seat-a.py .`.
   It prints sections 2 to 6. The window is the last 100 runs with jobs, so a
   later fetch moves it.

```python
import json,sys,collections,re,bisect,datetime
from datetime import datetime as D
S=sys.argv[1]
t=lambda s:D.fromisoformat(s.replace('Z','+00:00')) if s else None
txt=open(S+'/jobs.jsonl').read(); dec=json.JSONDecoder(); i=0; J={}
while i<len(txt):
    if txt[i].isspace(): i+=1; continue
    o,i=dec.raw_decode(txt,i); J[o['run']]=o['jobs']
R=sorted(json.load(open(S+'/runs.json')),key=lambda r:r['createdAt'])
def pct(a,p):
    a=sorted(a)
    if not a: return float('nan')
    k=(len(a)-1)*p; f=int(k); c=min(f+1,len(a)-1); return a[f]+(a[c]-a[f])*(k-f)
m=lambda s:s.total_seconds()/60
ran=[r for r in R if J.get(r['databaseId']) and r['status']=='completed']
print('# per job, run-level, push-to-verdict')
win=ran[-100:]
print('window', win[0]['createdAt'], '..', win[-1]['createdAt'], 'n_runs', len(win), collections.Counter(r['conclusion'] for r in win))
allruns=[r for r in R if win[0]['createdAt']<=r['createdAt']<=win[-1]['createdAt']]
print('all runs created in window',len(allruns),collections.Counter(r['conclusion'] for r in allruns), 'no-jobs', sum(1 for r in allruns if not J.get(r['databaseId'])))
hrs=m(t(win[-1]['createdAt'])-t(win[0]['createdAt']))/60; print('hours %.1f pushes/h %.1f'%(hrs,len(allruns)/hrs))
# per job
q=collections.defaultdict(list); rt=collections.defaultdict(list); concl=collections.defaultdict(collections.Counter); mx=collections.defaultdict(float)
for r in win:
    for j in J[r['databaseId']]:
        if not j['started_at'] or not j['completed_at'] or j['conclusion']=='skipped': concl[j['name']][j['conclusion']]+=1; continue
        a=m(t(j['started_at'])-t(j['created_at'])); b=m(t(j['completed_at'])-t(j['started_at']))
        q[j['name']].append(a); rt[j['name']].append(b); concl[j['name']][j['conclusion']]+=1
print('\n| job | n | queue p50 | queue p90 | run p50 | run p90 | run max | conclusions |')
for k in sorted(rt,key=lambda k:-pct(rt[k],.5)):
    print('| %s | %d | %.1f | %.1f | %.1f | %.1f | %.1f | %s |'%(k,len(rt[k]),pct(q[k],.5),pct(q[k],.9),pct(rt[k],.5),pct(rt[k],.9),max(rt[k]),dict(concl[k])))
# run-level decomposition
rows=[]
for r in win:
    js=[j for j in J[r['databaseId']] if j['created_at']]
    c0=t(r['createdAt']); jc=min(t(j['created_at']) for j in js)
    ends=[j for j in js if j['completed_at']]
    if not ends: continue
    last=max(ends,key=lambda j:t(j['completed_at'])); end=t(last['completed_at'])
    # critical chain: last job + its classify (+generate for e2e)
    chain=[last]
    names={j['name']:j for j in js}
    if 'e2e' in last['name'].lower():
        g=[j for j in js if 'generate' in j['name'].lower()]
        chain+=g
    cl=[j for j in js if 'classif' in j['name'].lower()]
    chain+=cl
    cq=sum(m(t(j['started_at'])-t(j['created_at'])) for j in chain if j['started_at'])
    cr=sum(m(t(j['completed_at'])-t(j['started_at'])) for j in chain if j['started_at'] and j['completed_at'])
    sumq=sum(m(t(j['started_at'])-t(j['created_at'])) for j in js if j['started_at'])
    sumr=sum(m(t(j['completed_at'])-t(j['started_at'])) for j in js if j['started_at'] and j['completed_at'])
    rows.append(dict(id=r['databaseId'],c=r['conclusion'],wall=m(end-c0),conc=m(jc-c0),exec=m(end-jc),cq=cq,cr=cr,last=last['name'],sumq=sumq,sumr=sumr))
def P(k,rs=rows): v=[x[k] for x in rs]; return '%.1f / %.1f'%(pct(v,.5),pct(v,.9))
print('\nrun-level n=%d (p50 / p90 minutes)'%len(rows))
for k in ['wall','conc','exec','cq','cr','sumq','sumr']: print(k,P(k))
comp=[x for x in rows if x['c'] in('success','failure')]
print('completed (success/failure) n=%d'%len(comp))
for k in ['wall','conc','exec','cq','cr']: print(' ',k,P(k,comp))
print('last job', collections.Counter(x['last'] for x in comp).most_common(6))
gap=[x['exec']-x['cq']-x['cr'] for x in comp]; print('exec - chain(q+r) p50 %.1f'%pct(gap,.5))
# push-to-verdict
verd=[(t(r['createdAt']),t(r['updatedAt']),r) for r in ran if r['conclusion'] in('success','failure')]
ptv=[];noV=0
for r in allruns:
    c=t(r['createdAt']); v=[u for (cc,u,rr) in verd if cc>=c]
    if v: ptv.append(m(min(v)-c))
    else: noV+=1
print('\npush-to-verdict n=%d p50 %.1f p90 %.1f max %.1f (no verdict yet %d)'%(len(ptv),pct(ptv,.5),pct(ptv,.9),max(ptv),noV))
gv=[(cc,u) for (cc,u,rr) in verd if rr['conclusion']=='success']
ptg=[]
for r in allruns:
    c=t(r['createdAt']); v=[u for (cc,u) in gv if cc>=c]
    if v: ptg.append(m(min(v)-c))
print('push-to-green n=%d p50 %.1f p90 %.1f'%(len(ptg),pct(ptg,.5),pct(ptg,.9)))
# verdict spacing
vt=sorted(u for (_,u,_) in verd if u>=t(win[0]['createdAt'])); gaps=[m(b-a) for a,b in zip(vt,vt[1:])]
print('verdicts in window %d, gap p50 %.1f p90 %.1f max %.1f'%(len(vt),pct(gaps,.5),pct(gaps,.9),max(gaps)))
print('runners', collections.Counter(j['runner_name'] for r in win for j in J[r['databaseId']] if j.get('runner_name')))
t0=t(win[0]["createdAt"]); t1=max(t(j["completed_at"]) for r in win for j in J[r["databaseId"]] if j["completed_at"])
TO=[('classify',5),('hub:',35),('unit tests',15),('nuxt generate',15),('browser e2e',45),('iac:',20),('hermetic',30),('feature tests',15),('cnf:',10),('box reference',5),('gate health',5),('hygiene',5)]
def tmo(n):
    for k,v in TO:
        if k in n: return v
print('## timeout headroom')
for name in sorted({j['name'] for r in win for j in J[r['databaseId']]}):
    v=[m(t(j['completed_at'])-t(j['started_at'])) for r in win for j in J[r['databaseId']] if j['name']==name and j['started_at'] and j['completed_at'] and j['conclusion']!='skipped']
    if not v: print("| %s | all skipped |"%name); continue
    T=tmo(name); hit=sum(1 for x in v if x>=T-0.5)
    print('| %s | %s | p90 %.1f | max %.1f | headroom p90 %.1f | at limit %d/%d |'%(name,T,pct(v,.9),max(v),T-pct(v,.9),hit,len(v)))
# critical path
print('## critical path, completed runs')
agg=collections.defaultdict(list); crit=collections.Counter()
for r in win:
    if r['conclusion'] not in('success','failure'): continue
    js=[j for j in J[r['databaseId']] if j['started_at'] and j['completed_at']]
    by=lambda s:[j for j in js if s in j['name']]
    gh=by('gate health'); body=[j for j in js if 'gate health' not in j['name']]
    cj=max(body,key=lambda j:t(j['completed_at'])); crit[re.sub(r' \d/\d$','',cj['name'])]+=1
    chain=[by('classify')[0]]
    if 'e2e' in cj['name']: chain+=by('nuxt generate')
    if 'classify' not in cj['name'] and cj not in chain: chain.append(cj)
    if gh: chain.append(gh[0])
    c0=t(r['createdAt']); end=max(t(j['completed_at']) for j in js)
    Q=sum(m(t(j['started_at'])-t(j['created_at'])) for j in chain); X=sum(m(t(j['completed_at'])-t(j['started_at'])) for j in chain)
    first=min(t(j['created_at']) for j in J[r['databaseId']])
    W=m(end-c0); C=m(first-c0)
    agg['wall'].append(W); agg['before_jobs'].append(C); agg['queue_on_path'].append(Q); agg['run_on_path'].append(X); agg['sched_gap'].append(W-C-Q-X)
    agg['crit_run'].append(m(t(cj['completed_at'])-t(cj['started_at']))); agg['crit_queue'].append(m(t(cj['started_at'])-t(cj['created_at'])))
print('n',len(agg['wall']),'critical job',crit.most_common())
for k,v in agg.items(): print('%s p50 %.1f p90 %.1f mean %.1f'%(k,pct(v,.5),pct(v,.9),sum(v)/len(v)))
tw=sum(agg['wall']); print('share of summed wall: '+', '.join('%s %.0f%%'%(k,100*sum(agg[k])/tw) for k in ['before_jobs','queue_on_path','run_on_path','sched_gap']))
# utilisation: busy runner minutes vs online runner minutes
busy=sum(m(t(j['completed_at'])-t(j['started_at'])) for r in R for j in J.get(r['databaseId'],[]) if j['started_at'] and j['completed_at'] and t(j['started_at'])>=t0 and t(j['completed_at'])<=t1)
cap=[]; 
for l in open(S+'/cron.txt'):
    mm=re.match(r'(\S+) CAP online=(\d+) of (\d+)',l)
    if mm and t0<=t(mm.group(1))<=t1: cap.append((t(mm.group(1)),int(mm.group(2))))
span=m(t1-t0); avg_on=sum(c for _,c in cap)/len(cap)
print('## utilisation window %s..%s %.0f min; CAP samples %d; online mean %.2f; dist %s'%(t0,t1,span,len(cap),avg_on,collections.Counter(c for _,c in cap)))
print('busy runner-min %.0f; online runner-min %.0f; utilisation %.0f%%'%(busy,avg_on*span,100*busy/(avg_on*span)))
# concurrency of busy runners sampled each minute
ev=[(t(j['started_at']),t(j['completed_at'])) for r in R for j in J.get(r['databaseId'],[]) if j['started_at'] and j['completed_at']]
import datetime
cnt=collections.Counter(); x=t0; waitq=collections.Counter()
qev=[(t(j['created_at']),t(j['started_at'])) for r in R for j in J.get(r['databaseId'],[]) if j['started_at'] and m(t(j['started_at'])-t(j['created_at']))>0.25]
while x<t1:
    cnt[sum(1 for a,b in ev if a<=x<b)]+=1; waitq[sum(1 for a,b in qev if a<=x<b)>0]+=1; x+=datetime.timedelta(minutes=1)
tot=sum(cnt.values()); print('busy runners per minute', sorted(cnt.items()), 'minutes with >=1 job queued >15s: %.0f%%'%(100*waitq[True]/tot))
# load vs run time
bud=[]
for l in open(S+'/cron.txt'):
    mm=re.match(r'(\S+) BUDGET .*others=([\d.]+) cores',l)
    if mm: bud.append((t(mm.group(1)),float(mm.group(2))))
bud.sort(); bt=[a for a,_ in bud]
def load(a,b):
    i=bisect.bisect_left(bt,a); k=bisect.bisect_right(bt,b); v=[c for _,c in bud[i:k]]; return sum(v)/len(v) if v else None
print('## others-load (non-runner cores) vs run time, success only')
for key in ['hub:','hermetic','browser e2e','iac:','nuxt generate']:
    b=collections.defaultdict(list)
    for r in win:
        for j in J[r['databaseId']]:
            if key in j['name'] and j['conclusion']=='success' and j['started_at']:
                L=load(t(j['started_at']),t(j['completed_at']))
                if L is None: continue
                b['<3' if L<3 else '3-6' if L<6 else '>=6'].append(m(t(j['completed_at'])-t(j['started_at'])))
    print(key, {k:'n=%d p50=%.1f'%(len(v),pct(v,.5)) for k,v in sorted(b.items())})
v=[c for a,c in bud if t0<=a<=t1]; print('others cores in window p50 %.1f p90 %.1f max %.1f n=%d'%(pct(v,.5),pct(v,.9),max(v),len(v)))
t1=t(win[-1]["createdAt"])
V=[]
for r in ran:
    if r['conclusion'] not in('success','failure'): continue
    js=[j for j in J[r['databaseId']] if j['started_at'] and j['completed_at']]
    end=max(t(j['completed_at']) for j in js); first=min(t(j['created_at']) for j in J[r['databaseId']])
    body=[j for j in js if 'gate health' not in j['name']]; cj=max(body,key=lambda j:t(j['completed_at']))
    by=lambda s:[j for j in js if s in j['name']]
    chain=by('classify')[:1]+(by('nuxt generate') if 'e2e' in cj['name'] else [])+[cj]+by('gate health')
    Q=sum(m(t(j['started_at'])-t(j['created_at'])) for j in chain); X=sum(m(t(j['completed_at'])-t(j['started_at'])) for j in chain)
    V.append(dict(c=t(r['createdAt']),first=first,end=end,Q=Q,X=X))
V.sort(key=lambda v:v['c'])
pushes=[r for r in R if t0<=t(r['createdAt'])<=t1]
agg=collections.defaultdict(list)
for p in pushes:
    c=t(p['createdAt']); cand=[v for v in V if v['c']>=c]
    if not cand: continue
    v=min(cand,key=lambda v:v['end'])
    tot=m(v['end']-c); line=m(v['first']-c)
    agg['total'].append(tot); agg['line'].append(line); agg['Q'].append(v['Q']); agg['X'].append(v['X']); agg['gap'].append(tot-line-v['Q']-v['X'])
print('push-level n=%d'%len(agg['total']))
for k,v in agg.items(): print(k,'p50 %.1f p90 %.1f mean %.1f'%(pct(v,.5),pct(v,.9),sum(v)/len(v)))
T=sum(agg['total']); print('shares: '+', '.join('%s %.0f%%'%(k,100*sum(agg[k])/T) for k in ['line','Q','X','gap']))
# queue vs online
cap=[]
for l in open(S+'/cron.txt'):
    mm=re.match(r'(\S+) CAP online=(\d+) of (\d+)',l)
    if mm: cap.append((t(mm.group(1)),int(mm.group(2))))
cap.sort(); ct=[a for a,_ in cap]
def on(x):
    i=bisect.bisect_right(ct,x)-1; return cap[i][1] if i>=0 else None
qm=collections.Counter(); 
for r in win:
    for j in J[r['databaseId']]:
        if not j['started_at']: continue
        a=t(j['created_at']); b=t(j['started_at']); x=a
        while x<b: qm[on(x)]+=1; x+=datetime.timedelta(minutes=1)
print('job-queue minutes by online runners at that minute', sorted(qm.items(), key=lambda kv: (kv[0] is None, kv[0])), 'total', sum(qm.values()))
# hourly online and gate starved
hr=collections.defaultdict(list)
for a,c in cap:
    if t0<=a<=t1: hr[a.strftime('%m-%dT%H')].append(c)
print('hourly mean online:', ' '.join('%s=%.1f'%(k[3:],sum(v)/len(v)) for k,v in sorted(hr.items())))
st=sum(1 for l in open(S+'/cron.txt') if 'GATE STARVED' in l and t0<=t(l.split()[0])<=t1); g=sum(1 for l in open(S+'/cron.txt') if ' GATE ' in l and t0<=t(l.split()[0])<=t1)
print('GATE lines',g,'STARVED',st)
pk=sum(1 for l in open(S+'/cron.txt') if ' PARKED ' in l and t0<=t(l.split()[0])<=t1); print('PARKED in window',pk)
```
