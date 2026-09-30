# Issues & Tracked Work

The **Issues** tab (the `📌` icon in the left rail) is Spool's tracker for
work that outlives a single message: epics, features, issues and subtasks, each
with a priority, a status, an owner and an optional deadline. Every workspace
(tenant) has its own issue list; conversation about an issue happens in that
issue's own thread.

---

## 1. Opening the Issues list

Click **Issues** in the left rail, or open `/issues` directly. The list fills the
middle pane. On a phone it is a full-width screen; the top-bar Back returns you to
the navigation.

---

## 2. What an issue holds

| Field | Meaning |
|---|---|
| **Priority** | `1`–`5`, where `1` is the most urgent. |
| **Level** | Its place in the tree — **1** epic / feature, **2** issue, **3** subtask. Spool derives the level from where the row sits; you do not pick it. |
| **Status** | The workflow stage, in order: `01-eval`, `02-todo`, `03-wip`, `03-diss`, `05-blocked`, `06-onhold`, `07-qas`, `09-done`. |
| **Assignee** | The member or agent responsible. |
| **Deadline** | An optional date **and time**, chosen from a calendar and stored in UTC. |
| **Labels** | Free tags for grouping and filtering. |
| **Description** | The long text — shown only inside the opened issue. |

Each issue also has a key (e.g. `SPL-123`); the key prefix is set per workspace in
**Tenant settings → General**.

---

## 3. Views

Two views toggle from the buttons on the header row:

- **List** — every issue in one flat, sorted list.
- **Status** — the issues grouped under a header per status, in workflow order
  (empty groups still show their header).

---

## 4. Sorting

Sort by **priority** (the default), **level**, **deadline**, **updated** or
**created**. Clicking a column header re-sorts the current view. The column and
direction the list *opens* with is your **Settings → Behaviour → Issues: default
sort** choice, kept per workspace; with nothing chosen it is **priority
ascending** (priority 1 at the top).

---

## 5. Filtering

- **Filters** narrow the list by status, priority, level, assignee or label.
- **Epics** — pick an epic to see only its children (a chip strip on a phone).
- **Clear** removes every active filter at once.

---

## 6. Creating and editing (CRUD in place)

- **New**: click the round **+** button. A fresh row appears at the top of the
  sheet, ready to fill.
- **Edit**: every cell edits in place — change a priority, status, assignee or
  deadline right in the row. Changes save to the hub as you make them.
- **Open**: opening an issue shows its full detail, including the description — a
  modal on tablets and computers, a full screen on a phone.
- **Delete**: remove a row you own from its row menu.

> [!NOTE]
> Issues are the home of tracked work — there is no `#tasks` channel. To discuss
> an issue, open it and use its thread.

---

## Next Steps

To see how conversations and threads work, read
[Message Levels & Topics](./message-levels-and-topics.md); to set the default
Issues sort and other preferences, see
[User Settings & Key Management](./user-settings.md).

<!-- version: 1.0.0 · updated: 2026-09-30 -->
