# Notes

The **Notes** section in the left rail (the sheet icon, after Calendar) is
your own list of notes, a small notepad and task list. The sidebar keeps the
icon rail only, and the list fills the page.

## Whose notes they are

A note is yours alone. Nobody else sees it: not another member, not a
workspace admin. You see the same list in every workspace you belong to, and
it stays when you leave a workspace. When your account is erased, your notes
are erased with it.

## The list

- **New note** on top starts an empty note with priority 5, above your other
  notes of that priority. Opening Notes puts the focus on it: press **Enter**.
- The **filter box** narrows the list to the notes whose title or text holds
  what you type.
- **Pinned** notes come first, in their own group; the other notes follow.
- Each row is one line: the title, or the first line of the text when there
  is no title, with the note's priority beside it (**P1** to **P5**). A long
  title is cut with an ellipsis; open the note to read it all, with its text,
  checklist and links.
- Within a group the notes with priority 1 come first, then 2, and so on down
  to 5. Notes of the same priority keep the order you gave them.

Each note has its own address, `/notes?note=<id>`, so a bookmark or the
browser's Back button finds it again. The list is read again when you come
back to the browser tab.

## An open note

Click (or tap) a row to open the note. On a wide screen it opens as a window
over the list: **Esc**, the **X** or a click beside it closes it. After
**Esc** the focus is back on that note's row in the list, so **j** / **k**
(or the arrow keys) move up and down the list at once. On a phone
it fills the screen, and the **Back** arrow at the top left (or a swipe right,
or the phone's Back) takes you back to the list.

- **Title** and **text**: type to change them. Each change is saved a moment
  after you stop typing, and again when you close the note. When a save
  fails, the note keeps what you typed and shows **Not saved, retry**; press
  it to try again.
- **The text editor**: the buttons over the text make the selected text
  **bold** or underlined, or turn the selected lines into a numbered or a
  bulleted list. The note keeps plain wiki text: `**bold**`, `++underline++`,
  `1. ` and `- ` at the start of a line; a `++` inside a word, as in `C++11`,
  stays plain text. A note with text opens formatted;
  click the text, or press **Wiki code**, to edit the raw text, and **View**
  to see it formatted again.
- **Checklist**: tick a line, edit its text, remove it with the **x**, or add
  one with **Add a line**. Move a line with **Alt+Up** / **Alt+Down**, or drag
  it by its handle on a wide screen.
- **Links**: a web address or a Spool address typed in the text is a link
  when you press **View**, the same way as in a discussion. Links added with
  **Add to note** show as a short list under the text, with no heading; a
  note with none shows no list. A link to a Spool page opens on its own
  workspace's address, where that page decides what you may see; the
  workspace's name shows beside a link into another of your workspaces. A web
  address opens in a new tab. The **x** removes a link. A link into a
  workspace you have left shows **Link to a workspace you left** and opens
  nothing.
- **Priority**: pick 1 to 5 in the open note; 1 is the highest and a new note
  has 5. It is saved at once and the note moves to its place in the list.
- **Pin** puts the note in the Pinned group; **Unpin** takes it out.
- **Archive** hides the note from the list and closes it at once, with no
  question, and shows **Note archived** with **Undo** for 10 seconds. Find it
  again in the **Archive** section (the left rail), under **Notes**: open it
  there, or press **Unarchive** on its row, and it is back in your list.
- **Move up** / **Move down** change the note's place in its group. In the
  list, **Alt+Up** / **Alt+Down** on a row does the same, and on a wide screen
  you can drag a row. On a phone, keep your finger on a row until it lifts,
  then drag it up or down. A note moved onto a note of another priority takes that
  note's priority: drag a P5 note onto a P2 note and it becomes P2, in its
  place among the P2 notes. **Priority** in the open note changes it too.
- **Delete** removes the note at once, with no question, and shows **Note
  deleted** with **Undo** for 10 seconds. Undo brings it back as it was. When
  the message goes away, the note is deleted for good; there is no trash.

## The note menu

Every note has a menu with three actions:

- **Archive** (**Unarchive** on an archived note), as above.
- **Turn into a discussion** starts a new discussion in the workspace's
  lobby. Its first post is the note: the title on the first line (it becomes
  the discussion's subject), then the text, then the checklist lines. The
  note stays as it is, in your list, and gains a link to the new discussion.
  A small message shows with **Open**, which takes you there. An empty
  note cannot become a discussion: the action is greyed out and says why.
- **Delete**, as above.

To open it:

- On a wide screen, right-click a row of the list, or right-click the open
  note outside its text boxes and links (there the browser's own menu stays,
  for copy and paste).
- On any screen, press the **...** button at the end of a row, or the **...**
  button at the top of the open note. On a phone the menu opens from the
  bottom of the screen.

Archive and Delete ask no question. The small message with **Undo** shows at
the top of the window on a wide screen, and at the bottom of the screen on a
phone. The archived notes in the **Archive** section have the same menu.

## Delete notes with the keyboard

On a wide screen, the **Delete** key (or **Backspace**) deletes the note whose
row has the focus, the same as **Delete** in its menu: at once, with no
question, and with **Undo** for 10 seconds.

To delete several notes at once, check their rows first. A checked row is
filled darker.

- **Ctrl + click** (**Cmd + click** on a Mac) checks a row, or unchecks it.
- **Shift + click** checks every row from the last one you checked to this one.
- **Shift + J** / **Shift + K** (or **Shift + Down** / **Shift + Up**) checks
  the row and the next (or the previous) one, and moves the focus there.
- **Esc** unchecks them all.

Then press **Delete**: every checked note goes, and one **Undo** brings them
all back. A plain click on a row opens the note and unchecks the others. The
keys do nothing while you type in the filter box or in a note, and nothing on
a phone.

## From the top bar and the command palette

- Type `/note <text>` (or `/n <text>`) in the top bar and send it: it makes a
  note titled `<text>` (its first 200 characters) and posts nothing. When the
  page shows a topic, an issue or a calendar entry, the note's first link is
  that page. **Note created** shows with **Open**, which opens the new note.
  A `/note` with no text makes nothing and stays in the box.
- In the command palette (**Ctrl + K** / **Cmd + K**, not on a phone), type a note's title: the note is a
  **Note** hit, and choosing it opens the note. Archived notes are not
  listed there.

## Add to note

**Add to note** sits in the menu of a message, a topic card, an issue (the
row menu and the notes button of an open issue), a calendar entry and a
channel row. It opens a list of your notes, latest changed first, with
**New note** on top and a box to filter them:

- Click a note: it gains a link to the thing you were on.
- **New note**: a new note holding its link, with no title, so the title of
  a thing in a workspace you later leave does not stay in your notes (a
  note made this way before keeps its title). Text
  you typed in the box becomes the note's text; press **Enter** in the box
  when no note matches to do the same. **Enter** waits until your notes have
  loaded. If the text cannot be saved, the list stays open with your text in
  the box and shows **Not saved, retry**; press **Enter** again.

The note is yours (see above): it shows in **Notes** in every workspace you
belong to. In the open issue, **My notes** under the **Comment** box lists
your own notes that link that issue (not the archived ones); click one to
open it. Nobody else sees your notes there, and you never see theirs. To
write something everyone on an issue sees, use its **Comment** box instead.

## Coming next

Spec 155 adds the rest in the next steps: **Add to note** on messages,
issues and rows; and Settings -> Notes to export or erase all your notes.

If an administrator turns Notes off for the whole Spool, the page says so and
your notes are kept.
