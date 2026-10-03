## A cross-lane finding states three fields

Standing rule from 2026-08-28, learned the expensive way.

**What makes a wrong measurement costly is confidence, not error.** An uncertain
finding gets re-measured by whoever receives it. A confident, well-formatted one
gets **routed as work** — and a wrong one then allocates another agent's hours.

**Scope it narrowly or it becomes ceremony.** The trigger is *a finding that
asks someone else to change something* — not status, not a question, not "here
is what I did". The one-line test:

> **If your message would cause another agent to open a worktree, it states the
> version, the tree and the n.**

Where nobody is being asked to act there is no audit to make cheap, and the
fields are pure overhead. Worse, a rule that fires on every message trains
people to skim the header — which is exactly how a `prompt=v1.0` line got read
past twice by two careful agents on the day this rule was written.

So a qualifying measurement carries three fields:

| field | why |
|---|---|
| **the version / config it ran under** | a harness default of `v1.0` against a deployed `v1.3` inverted three case verdicts in one afternoon |
| **the tree or sha it ran on** | the receiver can only audit a claim if they can pin the tree and prove what it did and did not contain |
| **n** | separates *demonstrated* from *suggested*. Six clean samples against a true rate of 2-in-6 happen ~9% of the time — that is evidence of a lower rate, never proof of absence |

With those three, a receiving agent audits a finding in about a minute. Without
them the only way to check is to stand up a worktree and re-measure, which costs
an hour and which most agents will reasonably skip in favour of trusting the
sender. **That skipping is the failure mode** — not that a number was wrong, but
that it was not cheaply auditable enough to be worth auditing.

**Claims about a FILE are not covered by those three fields — cite the command
instead.** Do not write *"the README prints `--dataset-dir`"*; write
*"`grep -c dataset-dir README.md` -> 3"*. You cannot produce the second form
without running it, so the format enforces the check rather than your vigilance,
and it degrades honestly — if you will not run it, write *"I believe, unchecked,
that…"*, which warns the reader. This matters most when **relaying** someone
else's claim: the relayer has no memory of the file, only of someone sounding
sure.

Both rules are one rule: **make claims that carry their own check.**

Corollary: a control that can only detect what someone guessed in advance —
a `must_not_contain` ban list, a path filter, an allow-list — **cannot prove
absence**. Any confident claim that something is NOT happening has to come from
somewhere other than such a control.

