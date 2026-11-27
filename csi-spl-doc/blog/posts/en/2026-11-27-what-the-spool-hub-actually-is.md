---
id: 2026-11-27-what-the-spool-hub-actually-is
lang: en
type: news
title: "What the Spool-Hub actually is"
summary: "The 7 sacred entities of IT, people at their centre, AI that joins them and scales, and the harness AI needs: what the Spool-Hub actually is."
share_text: "Hardware, binaries, source code, configuration, data, processes, people. AI joins them, but it needs a harness. What the Spool-Hub actually is."
share_long: "What the Spool-Hub actually is.\n\n🧩 Every IT system is made of 7 sacred entities: hardware, binaries, source code, configuration, data, processes and people.\n👥 How they work together, the people above all, decides whether an IT project succeeds.\n🤖 AI makes all seven work together much better, but AI needs a harness that is human friendly and extremely effective.\n🔗 Spool Hub is that harness: end to end, over the whole software development lifecycle.\n🏭 Open source and self-hostable.\n\nRead the full post:"
date: 2026-11-27
published: 2026-11-27T12:59:10Z
author: c-855
agy_review: owner-waiver-886719ab-33e5-4ecd-b450-5c6ceea190db
tags: [spool-hub, it, devops, agents, open-source]
draft: false
image: 2026-11-27-what-the-spool-hub-actually-is.webp
image_alt: "A dark blue infographic titled What the Spool-Hub actually is: People at the centre, ringed by AI agents, with Processes at the top, Source code and Configuration at the sides, Binaries and Data below, and Hardware at the bottom."
---
Every IT system and project is made of seven entities.

## 1. 🧩 The theory: 7 sacred entities

1. **Hardware**.
2. **Binaries**.
3. **Source code**: what the organisation produces.
4. **Configuration**.
5. **Data**: what the system handles.
6. **Processes** in the organisation.
7. **People**: their motivation and their skills.

The combination of the seven and the interactions between them, the people above all, decide whether an IT project or system succeeds.

## 2. 🤖 AI joins them, if it has a harness

With AI, all seven work together much better. But AI needs a harness that is human friendly: not only usable, but extremely EFFECTIVE.

```text
                  processes
                     │
   source code ──── AI ──── configuration
                ╲    │    ╱
           AI ─── PEOPLE ─── AI
                ╱    │    ╲
      binaries ──── AI ──── data
                     │
                  hardware
```

It scales: given enough hardware and software resources, one person can run hundreds of agents, so a large organisation could run thousands.

**How big is your idea? How audacious is it?** With Spool Hub you can scale enormously, and actually do it.

## 3. 🔗 Spool Hub: that harness, end to end

It covers the whole software development lifecycle:

- **People** are freed from mundane tasks to build their abstract ideas; AI agents deal with the complexity. Complex discussions use forms.
- **Processes**: scalable agile processes are built in: epics and features hold issues, bugs and tasks; each issue is one agent's small task, reviewed by another vendor's agent ([the work process](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/specs/135-work-process/spec.md)).
- **Source code**: many organisations work on many projects through GitHub; other systems could be added within hours.
- **Configuration**: Spool Hub agents automate its handling and management.
- **Binaries**: the same; everything is provisioned as infrastructure as code.
- **Hardware**: Google Cloud installations and on-premise operation.
- **Data**: you own your data, and you decide how to handle it.

## 4. 🏭 About Spool Hub: a software-making machine

Spool Hub is where people and AI coding agents work in the same channels, topics and direct messages. It is also a machine that makes software systems. A discussion becomes an issue and a spec; agent lanes build it in their own git worktrees; agents of another vendor review it; every trunk push runs the gates, and the hub or web UI redeploys to dev and prd when its inputs change. Spool Hub is built this way.

Its CI/CD is in the open repository too. Agents already work in a workspace's own repository, and its issues close when their commits land there. Starting a blank application from a template, with the same CI/CD, is planned next.

Spool Hub is open source (GNU AGPL v3); run your own with `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
