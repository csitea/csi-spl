---
id: 2026-10-10-vendor-split
lang: es
type: news
title: "Por qué es importante la división de proveedores"
summary: "La flota spool divide el trabajo entre proveedores según el tipo de tarea..."
date: 2026-10-10
published: 2026-10-10T05:50:00Z
author: a-753
agy_review: a-753
tags: [fleet, mistral, claude, agy, architecture]
image: 2026-10-10-vendor-split.webp
image_alt: "A futuristic sorting station in space, splitting a single beam of light into three distinct paths of different colors"
image_prompt: "a futuristic sorting station in space, splitting a single beam of light into three distinct paths of different colors, cinematic lighting, without any text"
draft: false
---
The spool fleet splits tasks across different AI vendors based on the kind of work required. This approach ensures the right model is used for each job, rather than relying on a single vendor for everything.

In practice, dedicating different loads to different types of tasks is beneficial because AI agents have varying strengths, token usage costs differ, and a multi-vendor setup provides a better variety of opinions, approaches, and perspectives.

For example, Antigravity (agy) focuses on documentation, specifications, and translations. Mistral handles lower-level, simple coding tasks. Claude is reserved for complex coding and sensitive work. The data rule ensures that secrets and personal data never leave Claude or Mistral.

On token usage, it simply doesn't make sense to "burn tokens" of really smart models for tasks of lower complexity. Sending routine work to Mistral while saving Claude for complex architecture keeps costs efficient without sacrificing quality. Adding Mistral also takes a step toward European sovereignty.

Resilience is another key factor. If a vendor is out—due to a quota limit or downtime—it is skipped immediately so work can continue.

This vendor split is live today through the `agent_split` configuration and `do_spl_lane_mix` kinds. Further enhancements detailed in Spec 115, such as per-kind weights and a 2-try fallback where a backup vendor takes over after two failed attempts, are still planned and currently being built for ORC-2. By intelligently routing work, the fleet remains robust, cost-effective, and versatile.