# Mobile usability — an independent view (2026-10-05)

Measured in Chrome with touch on, at 390×844 and 360×780, against the mock bundle the e2e harness serves (`NUXT_PUBLIC_USE_MOCK=1`). Taps were real touch taps. Sizes are CSS pixels from the live DOM (`clientWidth`, `scrollWidth`, bounding boxes). Shots from the pass are in `/var/tmp/g-249-shots/`. A figure below holds for both widths unless it says otherwise.

The first 390×844 load sat on the "Loading Spool…" shell for its opening shots, so the path was run again once the shell was up. Those are the numbers. A viewport 320px shorter is only a stand-in for a browser that shrinks the page when the keyboard opens. This Chrome draws no keyboard, so an overlay keyboard was not measured. Dev-server timings were not used as product speed.

Effort: **S** is one screen, mostly copy and CSS. **M** changes navigation and wants its own tests. **L** is a new model.

These already work, and I would leave them: one panel at a time, the 44px header Back and the 44px dock Back, list rows at 48px, body and the composer at 18px (a tap in the field will not make iOS zoom), a card tap opening the thread (level 3, both widths), a send that landed and cleared the field (the channel went from 1 message to 2, both widths), the settings list, the avatar sheet (rows 44–48px), and no document horizontal overflow on the screens measured.

## Part A. What I would change

### A1. Put every section on the screen

**Problem.** The section strip is a sideways scroller. At rest a phone shows four sections and a sliver of a fifth. Help, Docs, and the later sections are off to the right, and a duplicate of the strip peeks in from the left, so the cut-off icon does not read as "there is more".

**Evidence.** The strip's scroll width is 2561px against a client width of 360 and of 390 (both widths, 26 loop copies in the DOM). Real controls fully inside the viewport: Channels, Messages, Issues, Topics. Flow is clipped (it starts at x=353 on a 360px screen and at x=368 on a 390px screen). Off-screen past Flow: Event log, People, Agents, Boxes, Archive, Help, Docs, Workspace settings. A tap on Help did not land, because its center was outside the viewport. The 390px home shot shows a gear sliver on the left edge and the next icon cut off on the right.

**Idea.** A fixed bar of the four sections people open all day (Messages, Channels, Issues, Topics), plus one More that holds Flow, Event log, People, Agents, Boxes, Archive, Help, Docs, and Workspace settings. More is a sheet, the same pattern as the avatar menu. No looping copies.

**Effort.** M.

### A2. Say where the message goes, and show Search

**Problem.** The composer is on every screen, including the message list, and its placeholder is clipped to about one word. On the message list that word is "Topics", which is a different section from the one on screen. Search is typed as `/search` in that same box, and there is no search control anywhere else on the phone.

**Evidence.** The placeholder string is 85 characters: "Message Topics — Enter sends · Shift+Enter adds a line · /search to search everything" on the message list, the channel name in place of Topics once a channel is open, and "Reply — Enter sends …" in a thread. The field is 208px wide at 390 and 178px at 360, at 18px type. The shots show "Message Topics", "Message #alert", and "Reply — Enter s". The search button (`top-bar-search`) had no visible box on the list, the channel, or the thread, and a tap on it failed, both widths. Send itself works: the typed note appeared in the channel and the field cleared.

**Idea.** On a list (level 1), the dock is a search field with the word Search, and it does not offer to post. On a channel or a thread, the field's first visible word is the destination (`#alerts`, or Reply), and the Enter/Shift hint moves to the `?` the field already has. Put the search icon back in the top bar; one tap seeds the search, which is what that button is for when it is rendered.

**Effort.** S.

### A3. Give the name and the thread title their own line

**Problem.** On a channel card the author id is squeezed to a few characters by the type mark, the time, the emoji, and the menu, which all share its row. The thread title is clipped the same way. Two people with the same short prefix cannot be told apart.

**Evidence.** The author text needs 130px. The card gives it 40px at 390×844 and 54px at 360×780. The shots read "G…" at 390 and "GRK…" at 360. After a send, the new card clips the sender the same way. In the thread the title pill reads "box-b CLE-07 i…" at 390 and "box-b CLE-…" at 360. The emoji and menu buttons are already 44×44, so the fix is the row, not the tap size. Inside the thread the author gets 100px at 390 and 70px at 360, still short of 130.

**Idea.** Name on its own line, full width under the avatar. Time, type, emoji, and menu on the line below. The thread title gets the width between Back and the header icons, wrapping to two lines rather than an ellipsis.

**Effort.** S.

### A4. Retire the 21px status strip

**Problem.** Connection, alerts, chime, and the version sit in a strip about 5mm tall, under the composer, on every screen. The same four facts are already in the avatar sheet, at 44px. Two drag grips just above the composer are 24px tall.

**Evidence.** Strip buttons measure 44×21 (connection, alerts, chime) and the version 54×21, at the bottom edge, both widths. The resize grip is 44×24 and the move grip is 48×24. The avatar sheet shows language, theme, notifications, and the hub connection on rows of 44–48px. New channel, on the channel list, is 32×32.

**Idea.** Remove the strip. Connection, alerts, chime, and version stay in the avatar sheet, where they are already large enough. Make the two grips at least 44px tall, or drop them on a phone and keep a single composer-size row in settings. Make New channel 44×44.

**Effort.** S.

### A5. A deep link should open the list, and the empty pane needs a Back

**Problem.** Opening People lands on an empty middle pane that says to select a person. The people are on the other panel. There is no header Back. The only Back is the dock button, which on a list screen reads as part of the composer.

**Evidence.** `/people` at both widths: level 2, header Back absent, dock Back present (44×44), body text "Select a person to see their card." The section strip is on screen and scrolled so People is the selected tab, which is how a person discovers the list is a different panel. Issues, opened from its tab, does show its own screen (filters, a sort chip, an empty line, an add button), so this is the deep-link shape, not every section.

**Idea.** A direct open of People, Agents, Boxes, or Archive starts at level 1, on that section's list. The empty middle pane, if it still appears, gets the same header Back the channel uses.

**Effort.** S.

### A6. Issues: a short sort label, and an empty state that matches an empty list

**Problem.** The sort chip truncates mid-word. The empty line says nothing matches, which reads as a filter that hid every row, while the filter chip says All.

**Evidence.** At 360×780 the sort control's text is 277px in a 223px chip. The shot reads "Sort: Updated, new…". Under it, chips "All" and one epic name, then "No issues match." No issue card was on screen, so opening an issue was not measured. The add button is a large round control and is fine.

**Idea.** The chip says "Updated" (the column), with the direction as the arrow it already has room for. When the list is empty and the filter is All, the line says there are no issues yet and points at the add button.

**Effort.** S.

### A7. The login bar is a language search, and the links are 17px

**Problem.** The signed-out bar is a logo, an environment tag, and a language combobox that takes the rest of the width. The two links on the card, Buy a workspace and Help, are one line of text. A signed-in person who lands on this screen still sees "Sign-in is unavailable right now" above the signed-in line.

**Evidence.** At 390×844, signed out, the card heading is "where people meet with ai". Buy a workspace is 124×17 and Help is 33×17. The mock's provider list came back off, so the email form was not on this pass; that absence is the mock, and the bar and the links are the layout. At 360×780 the same screen, reached once by a history swipe while the session was still signed in, showed "Sign-in is unavailable right now" and a signed-in Continue line together, plus a 44px Sign out. The language combobox ("English", and "Search language" before it settles) is in the bar at both widths.

**Idea.** Language on this screen is an icon that opens the same list the avatar sheet uses. Buy a workspace and Help become 44px rows. When the session is already signed in, the screen is the Continue line and Sign out, and the unavailable line stays off.

**Effort.** S.

### A8. One Back, one level

**Problem.** Header Back and the dock Back pop one level, and that is the control that worked. A right-swipe from the screen edge follows history instead, so it can skip a level or leave the app for the login document.

**Evidence.** Dock Back on the channel returned to the list (360×780, level 2 to level 1). A right-swipe started at x=100 with one move event stayed on the thread, both widths, so that sample does not show the in-app swipe as dead. A right-swipe from x=8 left the thread for the section list at 360 (level 3 to level 1, the channel skipped) and for the channel at 390 (level 3 to level 2). Earlier, a right-swipe from x=24 on the list, with the login document still in history, opened the login screen while the session stayed signed in (the shot in A7). n=1 for each swipe outcome.

**Idea.** The edge swipe pops one level, the same as the two Back buttons, and it does not travel history entries from before the session. Keep both buttons.

**Effort.** M.

## Part B. The ten starter ideas

Part A was written before this list was opened. The list is c-002's starter post 8c8322a1. It says the ten ideas come from the specs and from reports, and not yet from a walk on a phone. The walk is what the verdicts use.

| # | starter idea | verdict |
|---|---|---|
| 1 | Bottom tab bar | change |
| 2 | Swipe actions on topic cards | change |
| 3 | Pull to refresh and a "last updated" clock | change |
| 4 | Jump to first unread | keep |
| 5 | Reply bar that fits the keyboard | change |
| 6 | Push notifications | change |
| 7 | Bigger tap targets | change |
| 8 | Back gesture that follows the app | keep |
| 9 | Offline reading and a send queue | drop |
| 10 | Fast first screen | change |

**1. Bottom tab bar — change.** The diagnosis is right, and it is the same problem as A1. The sections are a sideways strip under the top bar, scroll width 2561px, and at both phone widths only Channels, Messages, Issues, and Topics sit fully on screen. Help, Docs, Flow, People, and the rest are off to the right. I would not put channels, topics, Flow, DMs, and search on that bar. Search is a field, not a fifth tab (A2), and Flow is one of the sections the current strip already fails to show, so promoting it pushes Issues off. The bar is Messages, Channels, Issues, Topics, and More. More is the sheet for everything else. Put it at the bottom if the thumb measurement on a built bar beats the current strip under the top bar; the gain is that every section has a place, not that the bar is low.

**2. Swipe actions on topic cards — change.** Archive, mark read, and pin are three meanings on the same horizontal gesture as Back, and A8 is already a swipe that sometimes leaves the screen. The card menu and the emoji button are 44×44 today, so pin and mark-read belong there, with the undo toast. One swipe direction on the card can stay "archive", which is the one the phone already aims at. I did not measure that card swipe; my swipes were page-level.

**3. Pull to refresh and a clock — change.** Pull to refresh on the message list and the channel is a small, expected gesture, and I would keep that half. A permanent "last updated" clock is another line of chrome on a screen that already clips the author to 40px to make room for chrome. The rows already carry a time.

**4. Jump to first unread — keep.** The message list already shows an unread count on a row and on the Messages tab. A long thread was not in this mock (the channel had one message, the thread two), so I did not see the landing position. The idea matches the way the list already talks about unread. The floating button has to sit above the composer: the dock owns the bottom of the screen (send sits at y=772 on an 844px screen).

**5. Reply bar that fits the keyboard — change.** When the layout height drops by 320px, the composer stays on screen, the field is 18px, and send is 44×44, at both widths. Attach is already the paperclip in that bar. Rebuilding the bar is the wrong work. The bar's failure on this walk is the clipped placeholder and the missing search control (A2). What is still open, and worth a check rather than a redesign, is an overlay keyboard that does not shrink the layout: this pass did not draw one. A draft kept per topic is worth having; I did not switch away and back, so I do not know whether it is already there.

**6. Push notifications — change.** Mention and DM notifications are the part I would keep, and per-channel mute belongs on the channel. "A reply in a topic you follow" plus quiet hours is a flood-control project, and nothing on the screens I walked gets easier when it lands. The avatar sheet already has alerts and chime. This is its own spec, after the three in Part C, and it is L.

**7. Bigger tap targets — change.** A 44px floor is the right rule, and a large part of the phone already meets it: section tabs are 50–52px, list rows 48px, header Back, dock Back, send, emoji, and the card menu are 44px, avatar-sheet rows are 44–48px. A blanket pass would restyle controls that passed. The misses I measured are the status strip at 21px, the composer grips at 24px, New channel at 32×32, and the login links at 17px (A4, A7). Bottom sheets for menus: the avatar menu is already one.

**8. Back gesture that follows the app — keep.** This is A8, and the walk agrees. Dock Back popped one level (channel to list). A right-swipe from the left edge left the thread for the list at 360, skipping the channel, and for the channel at 390. An earlier edge swipe, with the login document still in history, opened login while the session was still signed in. Each of those swipe results is n=1. Scroll restoration was not measured; the lists were short. The two buttons stay.

**9. Offline reading and a send queue — drop.** I never dropped the network, and a send landed, so I have no evidence that a lost connection loses the thread or the reply. It is L, and it does not fix a screen I could see. The connection line in the status strip read offline on the list and the channel while those screens were usable, which is a wrong indicator (A4 removes that strip), not a reason to build a queue.

**10. Fast first screen — change.** The goal is right and the acceptance is wrong if it is argued from the dev server. I am not using those timings as the product's speed. What I did see is the first paint: a full screen that says "Loading Spool…" with Buy a workspace under it, before the shell mounts, including for a signed-in session. Replace that fallback with the last list, or with a skeleton of it, and prove the time on the generated bundle.

## Part C. Build these three first

| order | build | why first |
|---|---|---|
| 1 | A1, starter 1 with the tab set in Part B | Eight sections, including Help and Docs, are off the phone until someone knows to drag a 61px strip. Every other fix is behind that. |
| 2 | A2, the composer label and a visible Search | The field is on every screen and currently names the wrong section, or clips the right name to one word. Search has no control on screen. Send already works. |
| 3 | A3, the author and the thread title on their own line | Every card hides who is speaking (40px of a 130px id at 390). It is S, and it is on the screen you are reading. |

Starter 8 (A8) is the next build, not one of these three. The two Back buttons already pop one level, and the swipe results are one sample each. Starter 4 rides along with ordinary thread work. Starter 5's keyboard check is a test, not a rebuild. Starter 6 and starter 9 wait until the screen itself is readable.
