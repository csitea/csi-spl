---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: en
type: news
title: "A bad business owner, a good tax analyst: a private Spool-Hub workspace handled my company's taxes"
summary: "I can't keep track of my company's taxes. A private Spool-Hub workspace and one agent put a year of Vero.fi documents in order in about three hours."
share_text: "I admit it: I'm bad at keeping track of my company's taxes. One agent, my own desktop and Vero.fi, and a year of documents was in order in about three hours."
share_long: "A bad business owner, a good tax analyst.\n\n😅 I have never kept up with my company's tax matters, though I have tried many times.\n🖥️ The agent runs on my own desktop, and I steer it from Spool-Hub's web interface.\n🔐 I log in to Vero.fi myself; the agent never sees my credentials.\n📂 The agent fetched the year's decisions and letters, sorted them by month and wrote a reasoned email to the accountant.\n⏱️ By hand it took 5-7 hours. I spent about 3 hours building the automation and the setup; from now on it should take less than 15 minutes a week.\n💡 Seeing it all in one place, I started to suspect I pay too much tax.\n\nRead the full post:"
date: 2026-11-25
published: 2026-11-25T13:55:48Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "An infographic: a business owner with piles of tax papers, a robot tax analyst, a private Spool-Hub workspace in the centre, an agent opening Vero.fi in a browser through MCP, documents filed in year, tax and payments folders on the cloud drive, an email to the accountant, and the times: by hand 5-7 hours, setup and automation 3 hours, next time 15 minutes."
image_prompt: "the owner's own infographic (made with Gemini), published as-is; centre-cropped to 16:9 by the blog encoder"
---
I'll admit it: I am a bad business owner. I can't keep track of my company's taxes. I tried discipline and automation many times; it never stuck.

Seeing everything in one place made me think: I am probably overpaying my company's taxes. On LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

Next: automation, scripts plus Spool-Hub's scheduling and infrastructure, so the weekly check runs by itself. The scripts are public: [github.com/csitea/csi-tax](https://github.com/csitea/csi-tax).

## 1. 🖥️ My machine, steered from the browser

Run an agent on your own laptop or desktop and steer it from Spool-Hub's web interface. With MCP and Firefox (or any MCP browser) it fetches information from any system you can access. Here: Vero.fi, the Finnish Tax Administration's e-service (vero = tax).

## 2. 📂 What happened

In my company's private workspace I asked about the advance tax, then had the agent open a browser on my desktop.

- I logged in myself; the agent never types, reads or stores credentials.
- It fetched the year's decisions, letters and payment data and filed them, and the older tax documents, on the cloud drive by month and type.
- I asked for an issue per theme; the agents wrote a reasoned email to the accountant.
- I steered with short messages; the documents stayed private.

## 3. ⏱️ Before and after

By hand it took 5-7 hours.

Now: 96 short messages, about six logins and about 3 hours, spent building the automation and the setup (UTC, 24.11.2026):

| phase | time |
|---|---|
| first question | 14.23 |
| agent request, login | 14.59-15.12 |
| own repository, fetch | 15.56-17.22 |
| 30/32 documents on drive | 17.45 |
| email ready | 18.10 |

From now on the same tax run should take less than 15 minutes a week.

## 4. 📅 The weekly report

I asked for a weekly report: new documents, due dates, open questions. The code is ready, not yet scheduled.

## 5. 🏢 Csitea Oy

Csitea Oy, a consulting company, finances and develops Spool-Hub. It offers cloud and DevOps consulting (AWS, Google Cloud, Kubernetes, Terraform, Python backends) and an online store service: [csitea.net](https://csitea.net).

## 6. 🔧 The technical part: the service account

On the cloud drive the agent works as the company's backup service account, not as me. It sees only folders shared with it: for taxes, one root folder for all financial documents, where the agent built year/month/vero/type. The key stays on the machine, not in git; the code reads key and folder from named variables.

## 7. 🏭 Open source

Spool Hub is open source (GNU AGPL v3): run your own instance in the cloud or with `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Demo account? Contact [csitea.net](https://csitea.net).
