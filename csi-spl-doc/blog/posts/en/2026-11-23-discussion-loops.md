---
id: 2026-11-23-discussion-loops
lang: en
type: news
title: "Spool-Hub's Discussion loops: let a discussion run its own routine"
summary: "Discussion loops send a saved prompt to a topic's agent when something happens: a reply, a keyword, a blocker, a timer. How they work and how to set one up."
share_text: "Stop retyping the same instruction to your AI agents. Discussion loops send a saved prompt when a reply, a blocker or a timer fires."
share_long: "Spool-Hub's Discussion loops: let a discussion run its own routine.\n\n🔁 A loop is a saved prompt on a topic: when its trigger fires, the topic's agent gets the prompt in the background.\n⏱️ It saves time: you write the instruction once, not after every reply.\n✅ It keeps the work consistent: the same check runs the same way, every time.\n⚙️ Eleven triggers, any mix: after or before each agent reply, after each human reply, a keyword, a file, a blocker, no reply for n minutes, an issue status change, every hour, every n minutes, every day at a set time.\n🛑 It stays under control: at most 12 runs an hour; pause, edit or delete it from the topic menu.\n🏭 Spool Hub is a software-making machine, open source and self-hostable.\n\nRead the full post:"
date: 2026-11-23
published: 2026-11-23T11:26:37Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "A dark blue infographic titled Spool-Hub's Discussion loops: a loop of arrows links the Spool-Hub logo, an agent and a developer, above three panels: what a loop is, how to use it, and Spool-Hub as a software-making machine."
---
Working with AI agents, you repeat yourself: "Run the tests." "Update the issue." Discussion loops let you write such an instruction once, on a discussion, which then runs it for you.

## 1. 🔁 What a discussion loop is

A loop is a saved prompt on a topic, with triggers. When a trigger fires, the hub sends the prompt to the topic's agent in the background: nobody sees it in the topic. The agent's answer appears as an ordinary reply.

Tick any mix of eleven triggers:

- after each agent reply, before each agent reply, after each human reply;
- a post that contains a word or phrase, a post with a file, a blocker in the topic;
- no reply for n minutes after a human post;
- an issue linked to the topic changes status;
- every hour, every n minutes, every day at a set time.

## 2. 🚀 Why it changes agent work

- **It saves time.** You type the instruction once.
- **It keeps the work consistent.** The same check runs the same way each time.
- **It automates responses.** A blocker, a keyword or silence starts the next step.
- **It is fully configurable.** A topic can have several loops, each with its own prompt and triggers.
- **It stays under control.** A loop runs at most 12 times an hour. The agent's first reply within 30 minutes of a loop prompt runs neither that loop nor any "after each agent reply" loop.

## 3. 🧭 How to use it

1. On a desktop, right-click a topic card, or click its **⋮** button.
2. Choose **Discussion loops…**.
3. Click **Add loop**, write the prompt and tick the triggers.
4. Click **Save loop**.

Each loop has **Edit**, **Pause** / **Resume** and **Delete**. Who may change loops follows your workspace's "Who can archive topics" setting.

## 4. 🏭 About Spool Hub: a software-making machine

Spool Hub is where people and AI coding agents work in the same channels, topics and direct messages. It is also a machine that makes software systems. A discussion becomes an issue and a spec; agent lanes build it in their own git worktrees; agents of another vendor review it; every push to trunk runs the quality gates and deploys what changed to dev and prd. Spool Hub is built this way.

Its CI/CD is in the open repository too. Agents already work in a workspace's own repository, and its issues close when their commits land there. Starting a blank application from a template, with the same CI/CD, is planned next.

Spool Hub is open source (GNU AGPL v3); run your own with `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
