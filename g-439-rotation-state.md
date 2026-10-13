# g-439 rotation state

Written 2026-10-13T17:28Z for the lane-rotate handoff (warn for 17:41Z UTC).
This file's commit must not be pushed and must not be rebased onto origin/master.
Drop it off the branch before any push. do_spl_push_master rebases every commit on HEAD.

## Task

SPL-1697, workspace documents header. Task 0d910440-3e66-4df9-be26-6e97226b6762.
Brief: /var/spool-hub/dispatch/g-002-ws-docs-brief.md.
Worktree /opt/csi/csi-spl-wt/g-439, branch g-439-ws-docs-header.
Waiting for a spool body on that task that starts with ACCEPTED. Do not /exit-clean before that.
Do not end the issue while the product commit is unpushed. Do not post in topic 0d910440.
Do not send the result again.

## Product commit (not pushed)

- sha b97cb4e9a80eb0179057bae2bd55ba5126db4486, parent ba5b55217.
- subject: feat(wui, SPL-1697): put the doc controls on one header row.
- Files: WorkspaceDocsPage.vue, QtoFileTree.vue, tests/unit/ws-docs-header.test.mjs, tests/e2e/qto-sidebar-entry.test.mjs.
- The Documents heading is gone. Outline and Grid sit at the right end of the header row. The new-document plus and the new-folder plus are on that same row. The left app-rail plus was not moved.
- On a phone the new-document button stays the floating action and the new-folder button stays above the list. The tree aria-label is still Documents.
- pnpm run typecheck exited 0 before the views-last reorder. The unit test passed 3/3 after that reorder.
- Headless Chrome, n=1, this tree, before the product commit: at 1440 the four controls share the header row and the views are at the right end; at 390 the top level has no Documents heading. The full e2e file was not re-run green. The booting dev server uses the main checkout node_modules, which lacks markdown-it, so a vite overlay swallows clicks. A fresh install here does not boot (simple-git 4). Do not patch that shared tree. The worktree node_modules symlink is gitignored.

## Why this warn did not push

- g-002 note df451778 (2026-10-13T17:08:18Z) says the sha was posted in the topic: stay idle, do not push, do not deploy.
- The brief forbids push and deploy. Nothing on task 0d910440 starts with ACCEPTED.
- Result already sent to g-002: msg 57aa005e-cdc9-427a-8523-dbc87467f4cf at 2026-10-13T17:07:40Z.
- Note 91896f9d (views at the right end) was followed and archived with df451778.

## This rotation

- Note e58bb842-431a-42dd-8629-6fd6cac2820b (g-001, task lane-rotate-g-439, ts 2026-10-13T17:27:05Z, rotation at 17:41Z) is recorded and not replied to.
- Inbox at read time held only this rotation note.
- The product commit stays the only commit that may be pushed later, and only after ACCEPTED. This rotation commit stays off origin/master.
