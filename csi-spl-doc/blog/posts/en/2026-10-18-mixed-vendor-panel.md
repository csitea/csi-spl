---
id: 2026-10-18-mixed-vendor-panel
lang: en
type: news
title: "Ask more than one mind: why our AI agents sit on mixed-vendor panels"
summary: "Models from different vendors learn from different data and different feedback, so they miss different things. A panel of them sees more than one model alone."
date: 2026-10-18
published: 2026-10-19T10:22:49Z
author: c-414
agy_review: a-360
tags: [agents, panel, vendors, consensus, open-source]
image: 2026-10-18-mixed-vendor-panel.webp
image_alt: "Five different cartoon robots sit round a table and argue over a plan."
image_prompt: "a funny cartoon of five very different robots sitting round a table discussing a plan: an orange boxy one, a blue round one, a green long-neck one, a purple one on treads, a yellow teapot-shaped drone; one points at the plan, one scratches its head, one objects, one nods, one sips oil; bright flat-colour cartoon; robots only, no logos, no lettering, no text"
draft: false
---
One smart model agreeing with itself is not a second opinion.

## 🧠 How a model learns

A large language model is trained in two broad steps. First comes pre-training: it reads a very large body of text and learns to predict the next word, and from that it picks up language, facts and patterns of reasoning. Then comes fine-tuning: people and automated checks rate its answers, and it is tuned towards the helpful ones (feedback methods such as RLHF), and towards its vendor's own rules on how it should behave.

## 🔀 Why the models are not the same

The models of different vendors share a lot. Much of the public web, books and code is in all of their training data, and the basic recipe is similar. But each vendor picks its own data mix, its own cutoff date, its own training choices and its own feedback and rules. So each model has its own strengths, and its own blind spots.

That is the point. When two models from the same family agree, they may simply share the same blind spot. When models from different vendors, trained differently, reach the same answer on their own, that agreement is stronger evidence.

## 🤖 How a panel works in spool-hub

spool-hub runs a fleet of AI agents from several vendors: Claude, Grok, Antigravity and Mistral. Each kind of task has a main vendor and a backup, and the backup takes over after two failed tries.

Bigger work, such as a round of refactoring or bug fixes, starts with a panel:

1. An editor seat writes a plan: what to do, why, and how to prove it worked.
2. Seats from other vendors read the plan, raise their objections and propose changes.
3. The editor folds the objections in. Each seat signs the plan, and the agreed version becomes v1.0: the consensus.
4. Build lanes then work towards that one agreed goal, row by row.
5. Every row is checked before it lands by a reviewer from a different vendor than its author.

The agents disagree, and that is welcome: a disagreement on the plan is cheap, while a mistake found after the build is not. Once they have agreed, everyone pulls in the same direction.

## ✨ Different views, one goal

A mixed panel is like a good team of people: different backgrounds, different instincts, one shared plan. It also keeps the work going when one vendor is out, because another can step in.

---

spool-hub is open source: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Anybody can install it with the help of AI agents, thanks to its up-to-date docs and its own doc format, Qto.

operated by [Csitea Oy AB](https://csitea.net)
