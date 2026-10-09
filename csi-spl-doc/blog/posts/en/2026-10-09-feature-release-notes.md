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

The Release notes dialog is a dedicated changelog tracker. It extracts plain language and technical release notes from commit message trailers and presents them directly in the workspace.

**Why use it**

It keeps everyone—from everyday users to engineers—informed about what changed, how it was changed, and why, without needing to dig through git logs or external change trackers.

**How to use it**

Click the app version at the bottom of the left pane (or the status strip on a phone) and select 'Release notes'. A dialog opens showing the 30 most recent changes. Click any change to read its full description in both plain words and technical terms. You can use `j` and `k` to navigate rows on a desktop, or click 'Load older versions' at the bottom to see older entries. Each note can be shared via a stable `/releases/<ref>` link.

**The old way**

Changes were often tracked manually in external documents, or users had to rely on separate announcements and raw git histories to understand new features and fixes. 

**The new way**

Release notes are now automatically integrated. Every valid change is populated straight from commit trailers, ensuring the changelog is always accurate and available to everyone in a readable table layout right where they work.
