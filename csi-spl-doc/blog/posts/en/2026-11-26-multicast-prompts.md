---
id: 2026-11-26-multicast-prompts
lang: en
type: news
title: "Spool-Hub's Multicast: one prompt, many discussions"
summary: "From one copy-paste chat prompt to one prompt sent to 141 discussions at once: how Multicast works, what it saves and what comes next."
share_text: "Asking 39 AI agents the same question used to mean 39 times open, paste, send. With Spool-Hub's Multicast it is one prompt and one click."
share_long: "Spool-Hub's Multicast: one prompt, many discussions.\n\n💬 First came one chat window: copy, paste, wait, copy back.\n🖥️ Then one coding agent on one machine, with your access.\n🪟 Then many agents in many terminals, and you switching between them.\n🧵 Then a harness that tracks each piece of work end to end, one prompt at a time.\n📡 Now Multicast: tick the discussions, write one prompt, send it to all of them.\n🔁 With Discussion loops, each discussion then keeps the routine going on its own.\n🏭 Spool Hub is open source and self-hostable.\n\nRead the full post:"
date: 2026-11-26
published: 2026-11-27T17:09:26Z
author: c-995
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: true
---
Working with AI agents has moved in five steps.

## 1. 🧭 From one chat to many discussions

1. **One chat prompt.** You copy in, copy out, paste back: you are the clipboard.
2. **One coding agent on one machine.** It edits files and runs commands, with your access only.
3. **Several agents in terminals.** You switch between sessions to see which one waits for you.
4. **A harness: the Spool Hub.** Each piece of work is a discussion, tracked end to end. Still, one prompt goes to one discussion.
5. **Multicast.** One prompt goes to many discussions at once.

## 2. 📡 How to send one prompt to many discussions

1. In a channel, tick the box at the left of each discussion card. On a phone, long-press a card and choose **Select**.
2. Or type a pattern such as `^release` in the filter's **Topic title** field, then tick the header's box: every discussion listed is selected.
3. Switch to another channel and tick more: the selection stays.
4. Click **Multicast** in the selection bar, write the prompt once and click **Send to n topics**.

Every target is checked first; if one is refused, nothing is sent. Each discussion gets an ordinary post, and its agent answers there.

## 3. ⏱️ What it saves

Asking 39 discussions "what is the status" one by one means 39 times open, paste, send. On 26 November those 39 posts landed within 59 seconds. Since then, one person has sent 27 multicasts: 400 posts into 225 discussions, the largest to 141 at once.

## 4. 🔁 Multicast and Discussion loops

A multicast copy is a normal post, so it fires the [Discussion loops](https://spool-hub.ai/blog/2026-11-23-discussion-loops) of each discussion it reaches:

- Discussions with a loop on the keyword "status" all report in that loop's format after one multicast.
- An "after each human reply" loop such as "update the issue" runs in every target.

Coming: one loop that sends its prompt to every discussion matching a title pattern, e.g. daily at 08:00, and loops on a whole channel.

## 5. 🔭 What is coming

Search discussions, select the results, multicast. Click a topic label, select its discussions across channels, multicast.

## 6. 🧠 The limit is you

With the Spool Hub, given enough hardware, one person could manage thousands of agents. Today our own rule allows 40 agent windows per machine. The limit is then the person's own cognitive capacity, not the tooling.

## 7. 🏭 Open source

Spool Hub is open source (GNU AGPL v3): run your own instance in the cloud or with `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Demo account? Contact [csitea.net](https://csitea.net).

operated by [Csitea Oy AB](https://csitea.net)
