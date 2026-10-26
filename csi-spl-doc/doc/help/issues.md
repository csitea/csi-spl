# Issues & Tracked Work

> Generated from qto doc `9a453b0c-3925-45ac-9679-09fe841b4968`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The **Issues** tab (the `📌` icon in the left rail) is Spool's tracker for
work that outlives a single message: epics, features, issues and subtasks, each
with a priority, a status, an owner and an optional deadline. Every workspace
has its own issue list; conversation about an issue happens in that
issue's own thread.

---

<a id="ws-doc-d15b2128-ee6f-4be4-9556-bb541040a507"></a>
## 1. Opening the Issues list

Click **Issues** in the left rail, or open `/issues` directly. The list fills the
middle pane. On a phone it is a full-width screen; the top-bar Back returns you to
the navigation.

---

<a id="ws-doc-0c843816-8060-4068-9fa6-41eaf3b3b11d"></a>
## 2. What an issue holds

| Field | Meaning |
|---|---|
| **Priority** | `1`–`5`, where `1` is the most urgent. |
| **Level** | Its place in the tree — **1** epic / feature, **2** issue, **3** subtask. Spool derives the level from where the row sits; you do not pick it. |
| **Status** | The workflow stage, in order: `01-eval`, `02-todo`, `03-wip`, `03-diss`, `05-blocked`, `06-onhold`, `07-qas`, `09-done`. |
| **Assignee** | The member or agent responsible. |
| **Deadline** | An optional date **and time**, chosen from a calendar and stored in UTC. |
| **Labels** | Free tags for grouping and filtering. In the opened issue each label is a chip: its **×** takes it off. In the label picker the set labels carry a check, and picking a checked one takes it off; **Backspace** in the empty *Label name* box takes the last one off. |
| **Description** | The long text — shown only inside the opened issue. |

Each issue also has a key (e.g. `SPL-123`); the key prefix is set per workspace in
**Workspace settings → General**.

---

<a id="ws-doc-74e78205-65ec-4e3b-8303-794b1cacc1d1"></a>
## 3. Views

Two views toggle from the buttons on the header row:

- **List** — every issue in one flat, sorted list.
- **Status** — the issues grouped under a header per status, in workflow order
  (empty groups still show their header).

---

<a id="ws-doc-f861777c-0c9d-4352-ab67-c69b124bc403"></a>
## 4. Sorting

Sort by **priority** (the default), **level**, **deadline**, **updated** or
**created**. Clicking a column header re-sorts the current view. The column and
direction the list *opens* with is your **Settings → Behaviour → Issues: default
sort** choice, kept per workspace; with nothing chosen it is **priority
ascending** (priority 1 at the top).

On a phone, the bar above the list says what it is sorted by, for example
"Sorted: Deadline, oldest first". The **Sort** icon (two arrows) opens the sort
sheet: the current sort at the top, each column once below with the current one
ticked, and **Reverse** to flip the direction.

---

<a id="ws-doc-5d68898c-f171-443b-964c-6979d98c3cc1"></a>
## 5. Filtering

- **Filters** narrow the list by status, priority, level, assignee or label. On a
  phone they open from the **Filter** icon (a funnel); a dot on it means a filter is on.
- **Unread** shows only the issues assigned to you that you have not opened
  yet: exactly the ones the number on the **Issues** tab counts. Click (or tap)
  that number to open the list with **Unread** on; an issue you open leaves the
  list and the number drops by one. The link is `/issues?unread=1`.
- **Epics** — pick an epic to see only its children (a chip strip on a phone).
- **Clear** removes every active filter at once.

---

<a id="ws-doc-4ed4ddc1-1d7f-4610-97a7-fe4e05607d73"></a>
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

<a id="ws-doc-a0e9e129-b5c8-4feb-a7e9-5f4afaa2eb90"></a>
## Next Steps

To see how conversations and threads work, read
[Message Levels & Topics](./message-levels-and-topics.md); to set the default
Issues sort and other preferences, see
[User Settings & Key Management](./user-settings.md).

<!-- version: 1.0.0 · updated: 2026-09-30 -->
