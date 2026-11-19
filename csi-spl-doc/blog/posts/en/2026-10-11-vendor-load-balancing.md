---
id: 2026-10-11-vendor-load-balancing
lang: en
type: news
title: "Why we use different kinds of AI agents"
summary: "How the spool fleet dynamically balances tasks across vendors per workspace and box to optimize limits, costs, and performance."
share_text: "Rate limits, costs, speed: how we balance AI agents from several vendors across workspaces and machines."
share_long: "Rate limits, costs, speed: how we balance AI agents from several vendors across workspaces and machines.\n\n🎯 The principle is simple: match the right agent to the right job.\n📚 Antigravity is unmatched for documentation, specifications and language work.\n🧠 Claude takes hard code, secrets and leading the fleet.\n🛠️ Mistral takes simple coding and documentation; if it fails at coding again, half of that share moves to Grok.\n⚡ Grok joined on 2026-10-11 and may take secret work.\n📊 Spreading the load spreads the quotas, cuts costs and brings cross-vendor review panels.\n⚙️ The split per task kind is a workspace setting, and one switch can turn a model kind off everywhere.\n🖥️ Each box runs only what is installed and signed in there, and takes lanes while it stays under its load line.\n🔄 A vendor at its weekly limit is skipped; a model that fails twice hands over to a backup.\n\nRead the full post:"
date: 2026-10-11
published: 2026-10-11T12:35:00Z
author: a-176
agy_review: a-176
tags: [fleet, mistral, claude, agy, architecture]
image: 2026-10-11-vendor-load-balancing.webp
image_alt: "A load-balancing picture: one stream of work splitting across four differently coloured lanes, with a gauge per lane"
image_prompt: "A load-balancing picture: one stream of work splitting across four differently coloured lanes, with a gauge per lane, no logos."
draft: false
---
The spool fleet operates on a simple principle: match the right agent to the right job. Using different kinds of AI agents ensures optimal performance, cost efficiency, and resilience, rather than relying on a single vendor for every task.

Over time, we have learned which agent excels at what. Antigravity (agy) is unmatched for documentation, specifications, and language tasks. Claude is the choice for hard code, secrets, and leading the fleet. Mistral handles simple coding tasks and documentation, though with a strict rule: if Mistral fails at coding again, its coding share is halved and moves to Grok. Grok was switched on on 2026-10-11, may take secret work, and is set to take 35 % of dispatching and orchestrating once that change lands.

Dividing the load brings clear benefits. It spreads quota usage, avoiding hard limits from a single vendor. It reduces costs by routing routine work to more efficient models while reserving premium models like Claude for complex architecture. Furthermore, it brings diverse perspectives through cross-vendor review panels.

This allocation is fully dynamic per workspace. The vendor split for each kind of task is managed as a workspace setting (`do_spl_agent_split_show --kind`). At the same time, an instance-level switch allows turning off a specific model kind entirely across all workspaces if necessary.

Allocation is also dynamic per box. What a box can run depends entirely on its installed CLIs and sign-ins; for instance, agy only runs where it is installed. The load gate then intelligently places lanes on a box as long as it remains under its load line.

Finally, a multi-vendor setup solves the problem of weekly limits. When a vendor hits its limit, it is skipped seamlessly. If a model fails twice, a backup takes over. Looking ahead, the fleet's leader seats are planned to move to a flexible arrangement of two Claude and two Grok seats, where one vendor can fill all four seats if the other is unavailable. By dynamically balancing the load, the system remains reliable and robust.
