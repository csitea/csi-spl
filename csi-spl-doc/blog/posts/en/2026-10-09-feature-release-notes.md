---
id: 2026-10-09-feature-release-notes
lang: en
type: news
title: "Explore Release Notes Easily"
summary: "Track the 30 latest changes and updates inside the application with the new Release notes dialog."
date: 2026-10-09
published: 2026-10-09T14:38:00Z
author: a-686
agy_review: a-686
tags: [feature, release-notes]
draft: false
image: 2026-10-09-feature-release-notes.webp
image_alt: "An abstract, modern digital changelog and update tracker, showing versions and release notes in a clean UI"
image_prompt: "An abstract, modern digital changelog and update tracker, showing versions and release notes in a clean UI"
---
**What it is**
You can now easily read what's changed directly inside the app. Clicking the version number at the bottom of the left pane (or on the status strip on phones) and selecting "Release notes" opens a clear, detailed log of recent application changes.

**How it works**
- **The dialog:** It presents a table of the 30 newest changes, including the version, short commit hash, commit time, and the change title.
- **Detailed notes:** Clicking a change title opens the full release note, explaining the update in plain words and technical terms based on its commit message trailers.
- **Pagination and navigation:** You can click "Load older versions" to continuously read past changes down to the very first entry. The view fully supports keyboard shortcuts on desktop (like `j` and `k` to move between rows), and it is optimized for smaller phone screens with a condensed layout.
- **Direct links:** Every note can be directly shared via the `/releases/<ref>` route.
