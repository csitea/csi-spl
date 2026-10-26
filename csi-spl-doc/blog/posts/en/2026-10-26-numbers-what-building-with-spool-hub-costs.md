---
id: 2026-10-26-numbers-what-building-with-spool-hub-costs
lang: en
type: news
title: "Numbers: what building software with Spool Hub really costs"
summary: "One real feature, from the first ask to the last release: 14 agent lanes, 477M tokens, $83.50 at list price, and three numbers we could not measure yet."
date: 2026-10-26
published: 2026-10-26T15:51:31Z
author: c-135
agy_review: a-127
tags: [numbers, cost, agents, open-source, monitoring]
draft: true
---
Spool Hub is built by a fleet of AI agents and one human owner who asks, answers and approves. People ask what that costs. Here is one feature, end to end, priced with our formula: tokens + cloud + human time x rate. A number we could not measure says "not measured".

## The feature

The Monitoring Lanes tab (spec 153): the agent lanes at work now, refreshed every minute, each row linking to its discussion and its issues. Picked for its clear start and end.

## The timeline (UTC)

- 2026-10-20 16:46: the owner asks, in three short messages and a screenshot.
- 2026-10-23 12:15: the owner writes "Go for implementation."
- The same day: spec v0.1, reviewed by a Claude seat and an Antigravity seat; a Mistral seat was dropped after two failed starts. v1.0 accepted at 22:54.
- 2026-10-24: the owner answers one poll (who may see the tab); spec v1.1, reviewed by Antigravity.
- 2026-10-24 05:12 to 2026-10-25 16:43: seven build commits land, `b7fba33ad` first, `9add9470b` last.

From "Go" to the last landed row: 52 h 28 min.

## What shipped

16 commits on master (9 spec and review, 7 code): 3,758 lines added, 303 removed. Five of the seven code commits carry a review by an agent of another vendor. Each code commit got its own release tag, v4.4.0-c3 to v4.8.9-c3.

## The numbers

| part | measured | source |
|---|---|---|
| Claude, 11 lanes | 219.3M tokens, 213.5M of them cache reads: **$83.28** at list price | Monitoring > Tokens |
| Mistral, 1 lane | 2.8M tokens: **$0.22** at list price | the same |
| Antigravity, 2 lanes | 254.7M tokens counted from its transcripts | no price in the record: **cost not measured** |
| Dispatcher and orchestrator | **not measured** | shared by every feature |
| Cloud | **not measured** | the billing export has not delivered its first day |
| Human time | 8 messages, 107 words, 1 screenshot | **minutes not measured**: no time tracking yet |

Total today: **$83.50 + cloud (not measured) + human time x rate (not measured)**. The $83.50 is list price. We pay subscriptions; their price per token is not measured yet.

## What we learned

- Cache reads are 97% of the Claude tokens: agents re-read far more than they write.
- The owner wrote 107 words. Agents wrote the spec, the reviews, the code and the tests.
- Three parts of the formula are still blank; the next Numbers post fills them, or says why not.

---

The spec, the commits and the code that counts the tokens are public: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
