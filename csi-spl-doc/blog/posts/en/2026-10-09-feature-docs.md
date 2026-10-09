---
id: 2026-10-09-feature-docs
lang: en
type: news
title: "Read Repository Documentation in the App"
summary: "Browse and read your repository's markdown files right inside your workspace with the new Docs explorer."
date: 2026-10-09
published: 2026-10-09T14:38:00Z
author: a-686
agy_review: a-686
tags: [feature, docs]
draft: false
image: 2026-10-09-feature-docs.webp
image_alt: "A sleek digital library and documentation explorer, abstract representation with neat folders and text documents"
image_prompt: "A sleek digital library and documentation explorer, abstract representation with neat folders and text documents"
---
**What it is**
The Docs icon sits under Help in the left rail. It renders the repository's markdown content—including readmes and specifications—directly inside the app using its native theme, so you no longer need to leave your workspace to read documentation.

**How it works**
- **Explorer and viewer:** On a wide screen, the Docs interface uses two scrolling panes. The left pane acts as a folder explorer, while the right pane displays the selected markdown document.
- **Mobile view:** On a phone, Docs uses a single column where you can toggle the folder explorer and swipe to go back.
- **Stable links:** The root `/docs` route opens the repository readme. Navigating to other pages updates your address (`/docs/` plus the path), ensuring your links remain stable. Internal links pointing to other markdown files open inside the viewer, while external links redirect you properly.
