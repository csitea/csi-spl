# g-439 rotation state

Written 2026-10-13T20:29Z for the lane-rotate handoff (warn for 20:41Z UTC).
The earlier warn (19:25Z, note 39a63044, for 19:39Z) is the parent commit cdf0ae8e5.
The warn before that (18:23Z, note 32f26d78, for 18:37Z) is e437988a1.
The warn before that (17:27Z, note e58bb842, for 17:41Z) is f64f401a4.
This file's commit must not be pushed and must not be rebased onto origin/master.
Drop every wip(g-439) commit off the branch before any push. do_spl_push_master rebases every commit on HEAD.

## Task

SPL-1697, workspace documents header. Task 0d910440-3e66-4df9-be26-6e97226b6762.
Brief: /var/spool-hub/g-439/lifetime/brief.md.
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

## Why these warns did not push

- g-002 note df451778 (2026-10-13T17:08:18Z) says the sha was posted in the topic: stay idle, do not push, do not deploy.
- The brief forbids push and deploy. Nothing on task 0d910440 starts with ACCEPTED.
- Result already sent to g-002: msg 57aa005e-cdc9-427a-8523-dbc87467f4cf at 2026-10-13T17:07:40Z.
- Note 91896f9d (views at the right end) was followed and archived with df451778.
- A push of b97cb4e9a would land a feat subject with SPL-1697 and close the issue before ACCEPTED.
- Fetched origin/master at 2026-10-13T20:29Z: tip edb155719. Before this commit the branch was ahead 4, behind 25 (rev-list --left-right --count origin/master...HEAD). It was not rebased. The wip commits must stay off origin/master.
- lane-map --check g-439-rotation-state.md --agent g-439 exited 4 (9 unknown lanes, none list that path). That does not cancel this note.

## This rotation

- Note 69fcbe9a-5aa6-4013-be86-debf695a0420 (c-001, task lane-rotate-g-439, ts 2026-10-13T20:27:39Z, rotation at 20:41Z) is recorded and not replied to.
- Inbox at read time held only this rotation note.
- The product commit stays the only commit that may be pushed later, and only after ACCEPTED. The wip commits stay off origin/master.
- Session rotation 20261013T1941Z-lane-g-439 was ACK OK at 2026-10-13T19:41:41Z by pid 3971095. Do not ack it again. Self-ack a687c43d was archived and not answered.
- Live window main:27 @884, identity pane %1728, title g-439@tnk > wait accept. A second pane %1774 sits in the same window. Do not ack 20261013T1839Z-lane-g-439 again (ACK OK 2026-10-13T18:39:37Z, pid 3896127).
- Prior rotation 20261013T1737Z-lane-g-439 was ACK OK at 2026-10-13T17:37:30Z by pid 969233. Do not ack it again.
- Prior warn 39a63044-1a41-406a-bfda-337e61808d03 (c-001, ts 2026-10-13T19:25:03Z, rotation at 19:39Z) was recorded in cdf0ae8e5 and not replied to.
- Prior warn 32f26d78-c6cf-4bb6-afd0-a6d8f4fa82b2 (c-001, ts 2026-10-13T18:23:04Z, rotation at 18:37Z) was recorded in e437988a1 and not replied to.
- Prior warn e58bb842-431a-42dd-8629-6fd6cac2820b (g-001, ts 2026-10-13T17:27:05Z, rotation at 17:41Z) was recorded in f64f401a4 and not replied to.
