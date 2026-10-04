# Mobile usability: the consensus (2026-10-05)

Owner request (HUM-10, prd t1 topic `c893c3a9`): ideas for specs to improve the UI usability on mobile. Owner DoD
(msg `44ff08f3`): "the DoD for this discussion will be the ready specs to implement". Owner (msg `460c3583`):
"inlcude a grok type of agent to propose his suggestions".

This doc joins two independent walks of the phone UI into one list:

| view | doc | agent | measured |
|---|---|---|---|
| claude | `mobile-usability-ideas-20261004.md` (`fb373613`) | c-246 | mock bundle, 390x844 and 360x780, touch, tree `7289ef28`, n = 1 per task and width |
| grok | `mobile-usability-grok-view-20261005.md` (`51d751cc`) | g-249 | mock bundle, 390x844 and 360x780, touch, n = 1 per sample |

Both were written before either read the other, and both also judged c-002's ten starter ideas (msg `8c8322a1`).
Neither walk used a real phone or a drawn keyboard. A real-phone pass is the first task of every spec below.

**The owner picks; the specs come after.** §4 holds the two questions only the owner can answer.

## 1. Agreed: both walks found it

| # | idea | claude | grok | the evidence both saw | effort |
|---|---|---|---|---|---|
| A1 | **Every section on the screen**: a fixed bar of Messages, Channels, Issues, Topics + **More** (a sheet with Flow, Event log, People, Agents, Boxes, Archive, Help, Docs, Workspace settings); no looping copies | 3.5 | A1 | the strip is a looping carousel (13 entries, scroll width 2561 px); only 4 sections are fully on screen at 360 and 390; a tap on Help missed because it was off-screen | M |
| A2 | **Say where the message goes, and show Search**: a visible search control; the composer's first word is the destination (`#alerts`, Reply); the key hints move into its `?` | 3.5, 3.7 | A2 | no search control on any phone screen (`top-bar-search` renders no box); search is typed as `/search`; the 85-character placeholder clips to "Message Topics" on the **Messages** list (the wrong section, seen in both walks' shots) | S |
| A3 | **Name and thread title on their own line**: the sender's full id on line 1 of the card; time, kind, emoji, menu below; the thread title wraps instead of an ellipsis | 3.1 | A3 | the author gets 30-40 px of a 126-130 px id at 390 ("C…", "G…"); 31-54 px at 360 | S |
| A4 | **Retire the 21 px status strip, and fix the last under-44 px controls**: connection, alerts, chime and version live in the avatar sheet (already 44-48 px); grips >= 44 px or dropped on a phone; New channel 44x44; the 043 audit becomes a CI gate | 3.9 | A4 | strip buttons 44x21, version 54x21, grips 44x24 / 48x24 (both walks); Flow chips 26 px tall and kind badge 26x18 (claude); New channel 32x32 (grok). The strip also read "offline" on usable screens (grok) | S |
| A5 | **Pull to refresh** on the lists and feeds, running the feed's catch-up | 3.8 | starter 3 | `base.css` sets `overscroll-behavior: none`, which also removes the browser's own pull; there is no in-app one | S |
| A6 | **A cached first screen instead of "Loading Spool…"**: paint the last list (or its skeleton) at once, refresh behind it; prove the time on the generated bundle with the 066 metrics | 3.11 (first-screen part) | starter 10 | grok saw the full-screen "Loading Spool…" (with Buy a workspace under it) on a signed-in open; `sw.js` caches the shell only, never `/api` | M |

## 2. Disputed: both views

| # | idea | claude says | grok says | resolution proposed here |
|---|---|---|---|---|
| D1 | **Where the A1 bar sits** | at the **bottom**, replacing the status strip (net cost ~35 px instead of 043's 56 px), because the top is the hardest thumb reach | put it at the bottom only if a measurement on a built bar beats the strip under the top bar; "the gain is that every section has a place, not that the bar is low" | owner question **Q1** (§4). The bar's contents (A1) do not wait for it |
| D2 | **Push notifications to a closed app** | rank 2 of 14: no alert reaches a phone unless a tab is alive (0 files hold Web Push code; 062 Q4 deferred it) | keep mentions and DMs; "a reply in a topic you follow" and quiet hours are flood control; build it **after** the readable-screen fixes | agreed scope: **mentions and DMs first**, followed topics later. Order: after the first five builds (§3). L either way |
| D3 | **Drafts and an offline send queue** | rank 3: the draft lives in memory only; a killed tab loses it | **drop**: "I never dropped the network, and a send landed, so I have no evidence" | **new measurement settles half of it** (c-246, mock, 390, n = 1, after reading both docs): a draft typed in `#lobby` was **still in the box in `#feedback`**, ready to post there, and a reload emptied it. So: **keep a per-feed draft that survives a reload (S)**. The offline queue (M) and offline reading (L) wait for evidence of lost sends on a real phone, as grok asks |
| D4 | **Swipe actions on cards** (starter 2) | the swipes are built (archive left, menu right, hide on a reply); add a one-time hint and a "mark read" swipe | mark read and pin belong in the 44 px menu, not on the gesture Back also uses | **grok's view**: no new swipe meaning. Keep the one-time hint only (S); mark read goes in the menu |
| D5 | **Jump to first unread** (starter 4) | dropped as built: `LiveFeed.vue:18-20` (`unread-jump`) and `:133` (the phone thread-jump) | keep; the mock had no long thread, so the landing was not seen | **no spec**: the code exists. A long-thread check on a real phone joins A-group testing; if it fails there, it is a bug, not a spec |
| D6 | **Keyboard-up chrome** | with the keyboard emulated, ~40 % of 508 px is chrome; hide the workspace bar and the strip while typing | the bar stays on screen at 18 px with 44 px send; "rebuilding the bar is the wrong work" | no rebuild either way. A4 removes the strip; hiding the workspace bar while typing waits for a **real keyboard** measurement (both walks only shrank the viewport) |
| D7 | **Back by the edge swipe** (starter 8) | counted as built by 043 (N3, T055) | **keep, it is broken**: an edge swipe from x = 8 skipped a level at 360 (thread to section list) and, with login still in history, opened the login screen while signed in (n = 1 each) | **grok's view**: c-246 did not measure the edge swipe, and 043 T005 notes "the swipe is not measured by the lead". Spec it: the edge swipe pops exactly one level and never walks history from before the session (M) |

## 3. One view only, not contested

| # | idea | from | evidence | effort |
|---|---|---|---|---|
| U1 | Reopen where I left off (the last channel, DM or topic and its scroll; a notification or deep link wins) | claude 3.4 | opening `/` (the app icon) after `/channel/feedback` lands on level 1: +2 to +3 taps back | S |
| U2 | A message sheet ordered for the thumb (reactions + Reply at the bottom, unavailable actions left out, destructive actions apart) | claude 3.6 | 5 of 10 rows disabled for a member, 78 px each; Reply at y = 226, Delete at y = 758 | S |
| U3 | A deep link to People / Agents / Boxes / Archive opens the list; the empty pane gets a header Back | grok A5 | `/people`: level 2, "Select a person to see their card.", no header Back | S |
| U4 | Invite the install (avatar-sheet row + a one-time banner; iPhone gets the Add to Home Screen picture) | claude 3.10 | manifest complete, 0 `beforeinstallprompt` handlers; iPhone alerts need the install (D2) | S |
| U5 | Clean list titles (no raw `**markdown**`, no 50 px `Topic:` prefix) (also desktop: c-245 §3.13) | claude 3.13 | `w1-01-topics.png`; owner `4d2d3d63` "Remove the topic.. from mobile." may be this | S |
| U6 | Issues: a short sort label; an empty state that says "no issues yet" when the filter is All | grok A6 | at 360 the sort text is 277 px in a 223 px chip; "No issues match." under the All chip | S |
| U7 | The login screen on a phone: language as an icon, 44 px links, and no "Sign-in is unavailable" for a signed-in session | grok A7 | Buy a workspace 124x17, Help 33x17; both lines shown together at 360 | S |
| U8 | Newest-last by default on phones | claude 3.12 | the newest reply sits farthest from the composer | S (owner question **Q2**) |

## 4. Owner questions

| # | question | trade-off | recommendation |
|---|---|---|---|
| **Q1** | Should the new section bar (A1) sit at the **bottom** of the phone screen? | **Bottom**: in thumb reach, Slack/GitHub/Linear style. It reverses 043 D1 ("no bottom tab bar") and costs ~35 px net once the status strip goes (A4). **Top** (where the strip is today): no change of habit, 0 px extra, but it stays in the hardest reach. | **Bottom**, replacing the status strip, so A1 and A4 land as one change. Grok's caveat stands: the spec measures reach on the built bar, and the top position is the fallback. |
| **Q2** | On phones, should feeds and topics default to **newest last** (at the bottom, next to the composer)? | **Yes**: the order of every phone chat app; the reply you answer sits next to the box you type in. **No**: one default on every device, and newest first is what people know today. Either way a user who picked an order keeps it. | **Yes, on phones only**. The setting stays (`user-settings.md` §5.3). |

## 5. Build order

Each line is one spec and one lane, smallest dependency first.

| order | build | from | effort | why here |
|---|---|---|---|---|
| 1 | Section bar (A1) + retire the status strip and the small controls (A4), placed per Q1 | A1, A4, D1 | M | every other screen is behind the sections; one change moves both bottom strips |
| 2 | Composer destination label + visible Search (A2) | A2 | S | on every screen; search has no control today |
| 3 | Readable card header and thread title (A3) | A3 | S | every card hides who is speaking |
| 4 | Edge swipe = one level (D7) + reopen where I left off (U1) | D7, U1 | M | both are the same stack and history code (`useMobileStack`) |
| 5 | Per-feed drafts that survive a reload (D3, first half) | D3 | S | a measured wrong-channel draft |
| 6 | Small fixes batch: U2 sheet order, U3 deep links, U5 list titles, U6 Issues labels, U7 login, D4 swipe hint | U2-U7, D4 | S each | independent, one lane can take them in sequence |
| 7 | Pull to refresh (A5) | A5 | S | uses g-254's last-updated clock once it lands |
| 8 | Install invite (U4) + push for mentions and DMs (D2) | U4, D2 | S + L | the install comes first because iPhone push needs it |
| 9 | Cached first screen (A6) | A6 | M | measured with the 066 metrics on the generated bundle |
| later | Offline send queue, offline reading, followed-topic push, keyboard-up chrome | D3, D2, D6 | M-L | each waits for a real-phone measurement |

Not proposed again (running): operator console (c-250), docs editor (c-240), last-updated clock (g-254), topic
new/total (c-253), link previews (c-226).
