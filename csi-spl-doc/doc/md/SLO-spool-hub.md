# Hub SLO

**Status: PROPOSAL.** The owner approves the target. This page is that
proposal. It changes no workflow, no cnf, no terraform and no GCP resource.

Plan: [availability-plan-20261004.md](availability-plan-20261004.md), row
R04 (section 2.6.2). Topic `2c74edd5-d87d-4ceb-a5f7-a700085ba461`.

Two indicators, one target, one rule for when prd rollouts batch.

## 1. How the 16 days were scored

| field | value |
|---|---|
| tree | origin/master `b24560367c57d3ea459369b061c64213347bb458` at the read |
| when | 2026-10-04T20:43:21Z, request series and the log cross-check; uptime-config list in the same session, still 2026-10-04 |
| identity | each env's project service account (`csi-spl-prd@csi-spl-prd.iam.gserviceaccount.com`, `csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com`), key activated in a throwaway `CLOUDSDK_CONFIG`, `--account` on every call. Read-only. The config dir was removed after |
| window | 2026-09-18T18:55:00Z inclusive through 2026-10-04T19:00:00Z exclusive. That is the plan's section 3 span: dev service creation through the plan's own read. 16 days 5 minutes, 23 045 minutes |
| services | `csi-spl-hub-prd` in `csi-spl-prd`, `csi-spl-hub-dev` in `csi-spl-dev` |
| request source | Cloud Monitoring `run.googleapis.com/request_count`, summed across revisions |
| cross-check | `gcloud logging read` of every request log with status 429, and every status >= 500, limit 5 000, freshness 30 d. All four counts sit under the cap and equal the metric |
| uptime source | `gcloud monitoring uptime list-configs`, one call per project |
| n | 2 envs. Whole-window reduction: 17 response codes on prd, 20 on dev. Minute buckets: 51 calls per env (17 calendar slices × 3 series), 102 calls. Traffic minutes: prd 22 888, dev 22 919. Log pairs equal to the metric: 4 of 4. Uptime configs: 0 and 0 |

Before this file, the search the plan quotes in section 2.6.2
(`SLO` or `error budget` under `csi-spl-doc`, `csi-spl-iac`, `csi-spl-orc`)
lists 3 files on this tree: the plan, the R04 brief, and spec 053. The
plan's own reading, on an earlier tree, was 1 (spec 053). None of them is
an SLO.

## 2. The two indicators

### 2.1 Request success

The share of hub responses whose HTTP status is anything other than 429 or
5xx, over a rolling 30 days.

| counts as | statuses |
|---|---|
| good | every status other than 429 and 5xx. That includes 101, a WebSocket upgrade that completed, and every 4xx other than 429. A 401 or a 404 is the client. The row's indicator is the outage share |
| spends the budget | 429, and every 5xx |

A minute with no requests is idle. It stays out of this indicator. A silent
hub is what the uptime indicator is for.

### 2.2 Uptime-check success

The share of uptime checks that pass, over the same rolling 30 days, once
row R03's check is live.

Today that check has no samples. `gcloud monitoring uptime list-configs`
returned 0 configs on prd and 0 on dev (n=2). Until R03 lands, the request
indicator is the one with a number, and it is the one that can spend the
budget.

## 3. Proposed target

**99.5 % of each indicator, over a rolling 30 days.**

A miss on either live indicator spends the budget. While the service is
younger than 30 days, the window is the whole life of the service. That is
this 16-day span: there is no earlier history.

The request budget is 0.5 % of responses. The same 0.5 % as pure downtime
is 0.5 % × 30 × 24 × 60 = **216 minutes** of a fully failed hub per 30
days. Over this 23 045-minute window the pro-rated allowance is
216 × 23 045 / 43 200 = **115.2 minutes**.

## 4. The policy, and who decides

When the rolling window is under 99.5 % on either live indicator, the
budget is spent:

- prd rollouts batch
- there is no per-commit prd roll
- the commits that waited ship as one prd rollout once the window is back
  to at least 99.5 % on every live indicator
- dev keeps its per-commit roll

| question | who decides |
|---|---|
| the target number | the owner. 99.5 % / 30 days is the proposal on this page |
| the budget is spent | the measurement, at the moment a prd roll would start |
| the budget has recovered | the measurement, when every live indicator is back to at least 99.5 % |
| a prd roll while the budget is spent | the owner, for that roll. The exception covers that roll. It leaves the budget where the measurement put it |

This page states the rule. The deploy workflow stays as it is. Turning the
batch into a workflow step belongs to the lane that owns that workflow.

## 5. The 16-day history against the target

### 5.1 Request share

| env | responses | good | 429 | 5xx | request indicator | 5xx share | share of the 0.5 % budget used |
|---|---|---|---|---|---|---|---|
| prd | 612 094 | 610 596 | 1 380 | 118 | 610 596 / 612 094 = 99.755 % | 118 / 612 094 = 0.0193 % | 48.9 % |
| dev | 136 361 | 136 221 | 110 | 30 | 136 221 / 136 361 = 99.897 % | 30 / 136 361 = 0.0220 % | 20.5 % |

Budget used is bad responses divided by 0.5 % of responses:
1 498 / (0.005 × 612 094) = 1 498 / 3 060.47 = 48.9 % on prd, and
140 / (0.005 × 136 361) = 140 / 681.805 = 20.5 % on dev.

The largest whole number of bad responses this total can hold and stay at
or above 99.5 % is 3 060 on prd (`3 060 / 612 094 = 0.4999 %`,
`3 061 / 612 094 = 0.5001 %`) and 681 on dev (`681 / 136 361 = 0.4994 %`,
`682 / 136 361 = 0.5001 %`).

Both envs are above the proposed target. On prd, 1 562 further responses
in this same total could have been 429 or 5xx and the indicator would
still have passed (`3 060 − 1 498`); the next one would miss it. Incident
I-01 was 1 209 bad responses, so one more incident of that size stays
inside the target and two spend it. On dev the same headroom is 541
further bad responses (`681 − 140`).

The metric sum, the sum of the per-code table in section 6, and the sum of
the per-minute buckets are the same number on each env (prd 612 094, dev
136 361). The 429 and 5xx counts equal the log read (prd 1 380 and 118,
dev 110 and 30).

### 5.2 Minutes of full outage

A **full-outage minute** is a clock minute in which the hub returned at
least one response and every response was 429 or 5xx. Buckets are 60-second
sums of `request_count`. The label is the minute's end.

| env | minutes in the window | full-outage minutes | responses in those minutes | minutes that contained a 429 | minutes that contained a 5xx |
|---|---|---|---|---|---|
| prd | 23 045 | 8 | 779, all 429 | 24 | 81 |
| dev | 23 045 | 0 | 0 | 42 | 7 |

The eight prd minutes are one run: the minutes ending 2026-10-04T17:33:00Z
through 2026-10-04T17:40:00Z, inside I-01. Eight minutes is 8 / 115.2 =
6.9 % of the pro-rated time allowance.

Section 3 calls I-01..I-03 about 18 minutes of full 429 outage, from the
first and last log line of each burst (10.6 + 2.6 + 4.7 = 17.9 minutes,
1 372 of the 1 380 prd 429s). Scored with the minute rule above, those
three bursts look like this. The 429 counts match section 3 exactly.

| id | section 3 span | 429 in the span | full-outage minutes inside it |
|---|---|---|---|
| I-01 | 2026-10-04 17:30:55Z .. 17:41:31Z, 10.6 min | 1 209 | 8, holding 779 of the 1 209 |
| I-02 | 2026-10-02 05:12:52Z .. 05:15:29Z, 2.6 min | 144 | 0. Each of those minutes also returned successful responses |
| I-03 | 2026-09-28 03:49:00Z .. 03:53:44Z, 4.7 min | 19 | 0. Each of those minutes returned more successes than 429s |
| I-04 | seven sub-minute bursts | the other 8 | 0 |

I-01, responses per minute. The 429 column sums to 1 209, the same count
as section 3, across the minutes ending 17:32Z through 17:42Z. The eight
minutes with zero good responses sum to 779.

| minute ending (UTC) | responses | good | 429 |
|---|---|---|---|
| 2026-10-04T17:31:00Z | 96 | 96 | 0 |
| 2026-10-04T17:32:00Z | 145 | 29 | 116 |
| 2026-10-04T17:33:00Z | 108 | 0 | 108 |
| 2026-10-04T17:34:00Z | 91 | 0 | 91 |
| 2026-10-04T17:35:00Z | 106 | 0 | 106 |
| 2026-10-04T17:36:00Z | 105 | 0 | 105 |
| 2026-10-04T17:37:00Z | 103 | 0 | 103 |
| 2026-10-04T17:38:00Z | 95 | 0 | 95 |
| 2026-10-04T17:39:00Z | 67 | 0 | 67 |
| 2026-10-04T17:40:00Z | 104 | 0 | 104 |
| 2026-10-04T17:41:00Z | 216 | 7 | 209 |
| 2026-10-04T17:42:00Z | 261 | 156 | 105 |

I-02. The 429 column sums to 144.

| minute ending (UTC) | responses | good | 429 |
|---|---|---|---|
| 2026-10-02T05:13:00Z | 74 | 74 | 0 |
| 2026-10-02T05:14:00Z | 89 | 27 | 62 |
| 2026-10-02T05:15:00Z | 61 | 14 | 47 |
| 2026-10-02T05:16:00Z | 81 | 46 | 35 |

I-03. The 429 column sums to 19.

| minute ending (UTC) | responses | good | 429 |
|---|---|---|---|
| 2026-09-28T03:49:00Z | 100 | 100 | 0 |
| 2026-09-28T03:50:00Z | 53 | 43 | 10 |
| 2026-09-28T03:51:00Z | 37 | 37 | 0 |
| 2026-09-28T03:52:00Z | 27 | 27 | 0 |
| 2026-09-28T03:53:00Z | 21 | 21 | 0 |
| 2026-09-28T03:54:00Z | 80 | 71 | 9 |
| 2026-09-28T03:55:00Z | 15 | 15 | 0 |

Adding the three wall-clock spans gives the plan's ~18 minutes. The minute
rule gives 8 minutes on prd and 0 on dev. Both readings sit inside the
115.2-minute allowance (17.9 / 115.2 = 15.5 % of it, 8 / 115.2 = 6.9 %).

On dev the 110 × 429 fall in 42 minutes, and each of those minutes also
returned a successful response. Dev's full-outage count is 0.

### 5.3 The 500 runs

Section 3's 5xx counts match this read. Every 5xx sat in a minute that
also returned a successful response. prd had a 5xx in 81 minutes, dev in
7, and the only full-outage minutes on either env are the eight 429
minutes of I-01.

| id | when (UTC) | 5xx in this read | full-outage minutes |
|---|---|---|---|
| I-06 | 2026-10-01, on and off for about 11 h (`GET /v1/view/topics`) | prd 70, dev 29 | 0 |
| I-07 | 2026-10-04, on and off for about 6 h (`PUT /v1/me/reads`) | prd 47 | 0 |
| I-08 | 2026-09-29, one request | prd 1 | 0 |
| (no row in section 3) | 2026-10-03, dev | 1 × 503 | 0 |

prd 70 + 47 + 1 = 118. Dev 29 + 1 = 30. The 5xx share of all responses is
0.0193 % on prd and 0.0220 % on dev (section 5.1). The long wall-clock
spans are the spread of an intermittent 500. The request indicator scores
the failed responses: 148 of them across both envs.

### 5.4 Where the target stands

On this window the proposal holds. The budget is unspent on both envs, on
the request indicator and on the full-outage minutes, so the policy in
section 4 would have left the per-commit prd roll in place through these
16 days.

Prd's request headroom is the tight figure. One more I-01 (1 209 bad
responses) stays inside 99.5 % on this volume. Two spend it.

The uptime indicator has no samples until R03's check exists.

## 6. The counts behind section 5

Per day, from the 60-second buckets. 2026-09-18 starts at 18:55Z.
2026-10-04 ends at 19:00Z. The columns sum to section 5.1.

| day (UTC) | prd responses | prd 429 | prd 5xx | dev responses | dev 429 | dev 5xx |
|---|---|---|---|---|---|---|
| 2026-09-18 | 3 323 | 0 | 0 | 308 | 0 | 0 |
| 2026-09-19 | 7 090 | 0 | 0 | 11 452 | 1 | 0 |
| 2026-09-20 | 1 021 | 0 | 0 | 2 024 | 0 | 0 |
| 2026-09-21 | 2 941 | 0 | 0 | 9 072 | 13 | 0 |
| 2026-09-22 | 2 676 | 0 | 0 | 3 836 | 41 | 0 |
| 2026-09-23 | 2 107 | 0 | 0 | 3 043 | 0 | 0 |
| 2026-09-24 | 3 552 | 0 | 0 | 1 871 | 0 | 0 |
| 2026-09-25 | 14 527 | 1 | 0 | 13 251 | 44 | 0 |
| 2026-09-26 | 26 932 | 3 | 0 | 16 914 | 8 | 0 |
| 2026-09-27 | 37 793 | 2 | 0 | 10 830 | 2 | 0 |
| 2026-09-28 | 26 646 | 19 | 0 | 5 848 | 0 | 0 |
| 2026-09-29 | 15 162 | 0 | 1 | 3 201 | 0 | 0 |
| 2026-09-30 | 26 626 | 0 | 0 | 4 317 | 0 | 0 |
| 2026-10-01 | 53 755 | 0 | 70 | 8 546 | 0 | 29 |
| 2026-10-02 | 120 998 | 144 | 0 | 18 040 | 1 | 0 |
| 2026-10-03 | 151 675 | 1 | 0 | 18 612 | 0 | 1 |
| 2026-10-04 | 115 270 | 1 210 | 47 | 5 196 | 0 | 0 |

Whole window, by response code. 101 is a completed WebSocket upgrade and
counts as good (prd 100 763, dev 5 664). 401 is the largest other 4xx and
counts as good (prd 33 566, dev 23 731).

| code | prd | dev |
|---|---|---|
| 101 | 100 763 | 5 664 |
| 200 | 184 428 | 69 305 |
| 201 | 1 118 | 251 |
| 202 | 11 | 241 |
| 204 | 242 885 | 23 187 |
| 301 | 0 | 21 |
| 302 | 1 162 | 644 |
| 304 | 37 277 | 6 929 |
| 400 | 24 | 19 |
| 401 | 33 566 | 23 731 |
| 403 | 76 | 154 |
| 404 | 9 221 | 5 956 |
| 405 | 33 | 42 |
| 409 | 30 | 53 |
| 410 | 0 | 12 |
| 415 | 1 | 1 |
| 426 | 1 | 11 |
| 429 | 1 380 | 110 |
| 500 | 118 | 29 |
| 503 | 0 | 1 |

## 7. Repeating the score

Use the env's project service account, a throwaway `CLOUDSDK_CONFIG`, and
`--account` on every call.

1. Sum `run.googleapis.com/request_count` for the hub service over the
   window, grouped by `metric.label.response_code`. Good responses are
   every code other than 429 and 5xx. The indicator is good / all.
2. Sum the same metric in 60-second buckets three ways: every code, code
   429, and `response_code_class` 5xx. A bucket whose total is above zero
   and whose 429 + 5xx equals that total is one full-outage minute.
3. Read the request logs for status 429 and for status >= 500 over the
   same window. The counts match step 1, or the score says they did not
   and which source it used.
4. `gcloud monitoring uptime list-configs` is the sample count for the
   second indicator. Zero configs means the indicator is waiting on R03.

The budget line is 0.5 % of responses, and 216 minutes of full outage per
30 days. While the service is under 30 days old, score the whole life of
the service and pro-rate the 216 minutes by the window length over
43 200.
