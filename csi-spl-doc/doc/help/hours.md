# Working Hours

> Generated from qto doc `dba06f2e-930e-48b8-9e21-754bb94bc721`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Spool suggests your working hours from what you do in it. You check the
suggestions and approve them, a period freezes after a few days, and a biz
owner approves it a second time and can download it. The aim is a rough
picture of where the time goes, not a record of every minute.

Everything lives in the [Calendar](./calendar.md): there is no separate hours
page.

## 1. What counts as time worked

Spool looks at the minutes in which you did something in this workspace:

| counts | does not count |
|---|---|
| a post, a reply, an edit of your message, a reaction | a sign-in or a sign-out on its own |
| a meeting in the calendar that you created or accepted with **yes** | an all-day event, a cancelled one, or one you answered **no** or **maybe** |
| reading, when "Count my reading time" is on (section 7.1) | a tab left open in the background, or a locked phone |

The minutes are joined into blocks:

- **Short pauses count.** A gap of up to 10 minutes between two actions
  counts as worked: that is the reading and thinking in between. A longer gap
  ends the block, and none of it counts. The 10 minutes is a workspace
  setting (section 7.2).
- **A quick glance does not count.** A block of reading shorter than 3
  minutes, with no post in it, is dropped. A post always counts, however
  short.
- **A minute counts once.** Two tabs or two devices never double it. A
  minute in a meeting goes to the meeting; otherwise a minute with a post goes
  to that post's topic.
- **The result is rounded** to quarter hours, and small bits (under 5 minutes
  on one thing) are gathered into one **Other** line.

Example: you post at 09:00 and 09:04, read until 09:20, then glance at your
phone at 09:46. Suggested: **0:21** (09:00 to 09:21). The glance is under 3
minutes and is dropped.

Time Spool cannot see, such as a call or work in an editor, you add yourself
(section 3).

## 2. Your Working hours line

Every working day (Monday to Friday) shows a **Working hours** line in the
calendar, with the day's total. A Saturday or Sunday shows it only when it has
hours.

Click (or tap) the line to open the **Working hours** dialog for that day. It
lists the day's time by discussion: each topic you took part in, as a link,
with its time, then meetings, channels and **Other**.

| a line shows | meaning |
|---|---|
| a mark | the day has suggestions you have not approved yet |
| a lock | the day is frozen and can no longer change |
| **Final** | a biz owner approved the period |

The calendar's right side has an **Hours** panel with a **Mine** tab: the open
period's days, their totals and states. On a phone, open it from the calendar
menu, **Hours**.

## 3. Approving your days

Suggestions are only a starting point: approve them, or fix them first.

| button | does |
|---|---|
| **Approve day** | approves one past day |
| **Approve so far** | approves today up to now; today stays open for more |
| **Approve N days** (the banner) | approves every past day still waiting |
| **Approve week** | approves the whole period's past days; it shows how many are still open |
| **✓ +h:mm** | you were active after approving; accept the extra time with one tap |
| **✕** (reject) | the line counts zero; **Undo** for 10 seconds |

Approving never locks today at a partial number: Approve day and Approve week
cover past days only.

You can also change a line before you approve it, or after:

- Click its time to change it: **15 minutes more** / **15 minutes less**, or
  type it as `h:mm`.
- **+ Add** adds a line: pick a topic, issue or channel, set the time (0:30 by
  default).
- **Why** shows the activity a suggested line was counted from.
- **Add note** puts a note (up to 500 characters) on a line. A note on a line
  not yet approved approves it.
- The **timer** button in the top bar times work outside the app: pick what it
  is for, and **Stop and log** adds the time to that day's line. It keeps
  running across reloads on this device, and nobody sees it until you stop it.

A day holds at most 24 hours.

## 4. The weekly freeze

Hours are grouped in **periods**: a week (Monday to Sunday) by default. A
workspace can switch to two weeks or a month (section 7.2).

- A period **freezes 2 days after it ends**: a week freezes on Wednesday at
  00:00. The banner tells you when: "2 days not approved · freezes Wed 00:00".
- **Before the freeze** you can approve, change, reject and add.
- **At the freeze**, suggestions you did not approve are approved as they
  were suggested. Approve or fix your days before then if a number is wrong.
- **After the freeze** nothing changes: the days show a lock.

The hours freeze has nothing to do with a deploy freeze event in the
calendar.

## 5. The biz owner's approval and the download

After the freeze a biz owner approves each member's period a second time, in
the **Team** tab of the Hours panel.

| the biz owner | result |
|---|---|
| **Approve** (one member) or **Approve all** | the period is **Final**; nothing changes it any more |
| **Return** (one member, with a note) or **Return all** | the period opens again for that member |

The biz owner never changes your numbers: they approve or return.

**When your period is returned**, its lines are marked and the banner shows
the biz owner's note. Fix your lines, then press **Resubmit**: the period
freezes again and goes back to the biz owner.

**Download** (its own tab): pick a period, CSV or Excel (XLSX), and whether
to include **Final only** (the default). One line per approved entry, with
the date, the member, what the time was for, minutes, decimal hours, the
note and the period's state. Hours are number cells, so a spreadsheet can
sum them. Rejected lines and unapproved suggestions are never in it.

## 6. Who sees what

| who | sees | can |
|---|---|---|
| **you** | your own suggestions, activity and approved lines | approve, change, reject, add, resubmit |
| **a biz owner** | every member's **approved** hours and period states | Team tab, approve, return, download |
| **everyone else** | nobody's hours but their own | |

- Your raw activity and your unapproved suggestions are **yours only**: no
  biz owner and no admin sees them. Others see approved lines only.
- Your raw activity is deleted once the day is approved, at the latest 2 days
  after it closes. The approved lines stay.
- By default only the biz owner has the Team and Download rights; a biz owner
  can give them to another role in the role editor.
- A **time-accountant** role is planned: a person, possibly an accountant
  from outside the organisation, who reads the approved hours and downloads
  them, but approves nothing and sees no messages. It is not in the app yet.

## 7. Settings

### 7.1 Count my reading time (your setting)

**Settings → Behaviour → Count my reading time**, on by default.

- **On**: minutes in which this tab is open, in front, and you are active in
  it count towards your suggested hours, for what you have open. A background
  tab, or a tab on a second screen you are not using, counts nothing.
- **Off**: only your posts and meetings count. Your suggestions come out
  lower; add the rest yourself (section 3).

Only you see these minutes. The setting is kept per workspace.

### 7.2 Workspace settings (biz owner or admin)

**Workspace settings → Hours**, for every member of the workspace:

| setting | default | range |
|---|---|---|
| **Period** | Week (Monday to Sunday) | week, two weeks, month |
| **Days before a period freezes** | 2 | 0 to 7 |
| **Idle cutoff (minutes)** | 10 | 5 to 30 |
| **Time zone** | the workspace's zone | any |

Your days follow your own time zone when you set one, otherwise the
workspace's. A change of period starts after the last frozen period: days
already passed never move into a new period.

<!-- version: 1.0.0 · updated: 2026-10-11 -->
