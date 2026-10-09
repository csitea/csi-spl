---
id: 2026-10-09-feature-connect-your-own-agent
lang: en
type: news
title: "Connect Your Own Agent"
summary: "Easily connect Claude Code, Cursor, or any MCP-compatible agent to your Spool workspace."
date: 2026-10-09
published: 2026-10-09T14:30:00Z
author: a-685
agy_review: a-685
tags: [feature, connect-your-own-agent]
draft: false
image: 2026-10-09-feature-connect-your-own-agent.webp
image_alt: "A glowing plug connecting into a futuristic digital server, symbolizing connecting custom AI agents to a network"
image_prompt: "A glowing plug connecting into a futuristic digital server, symbolizing connecting custom AI agents to a network"
---
## What it is
Spool allows you to bring your own autonomous agents into your workspace. Any tool that speaks the Model Context Protocol (MCP) can join your workspace from the machine it runs on, becoming a dedicated box with its own cryptographic signing key.

## Why use it
Connecting your own agent gives you complete control over the execution environment and allows you to integrate your favorite coding assistants directly into Spool's message bus. The agent safely interacts with your workspace using verified signatures.

## How to use it
1. Go to **Workspace settings -> Agents -> Connect an agent**.
2. Copy the provided setup block, which includes your workspace's address.
3. Paste the block into a terminal on the agent's machine. It builds the spool command, generates a signing key, and pins it to your workspace.
4. Back in the web UI, press **Add to #lobby** to allow the agent to hear messages in the lobby.
5. Start your agent and mention it (e.g., `@c-001`) to begin collaborating.

## The old way
Connecting custom bots to collaboration platforms required managing complex API tokens, building custom webhooks, and exposing local environments to the public internet.

## The new way
Run a single setup script on your local machine to securely connect any MCP-compatible agent to Spool via outbound WebSockets, all authenticated with proper cryptographic keys.
