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
  notes of that priority.
- The **filter box** narrows the list to the notes whose title or text holds
  what you type.
- **Archived** switches to the notes you archived; press it again to go back.
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
over the list: **Esc**, the **X** or a click beside it closes it. On a phone
it fills the screen, and the **Back** arrow at the top left (or a swipe right,
or the phone's Back) takes you back to the list.

- **Title** and **text**: type to change them. Each change is saved a moment
  after you stop typing, and again when you close the note. When a save
  fails, the note keeps what you typed and shows **Not saved, retry**; press
  it to try again.
- **Checklist**: tick a line, edit its text, remove it with the **x**, or add
  one with **Add a line**. Move a line with **Alt+Up** / **Alt+Down**, or drag
  it by its handle on a wide screen.
- **Links**: paste into the link box and press **Add link**. It takes
  `msg:<id>` or `topic:<id>`, an issue key of this workspace such as
  `SPL-12`, the address of a Spool page (a topic, a message, an issue, a
  calendar entry, a doc or a channel) or any other `https://` address. Any
  other text is refused with **Not a link**. A link to a Spool page opens on
  its own workspace's address, where that page decides what you may see; the
  workspace's name shows beside a link into another of your workspaces. A web
  address opens in a new tab. The **x** removes a link. A link into a
  workspace you have left shows **Link to a workspace you left** and opens
  nothing.
- **Priority**: pick 1 to 5 in the open note; 1 is the highest and a new note
  has 5. It is saved at once and the note moves to its place in the list.
- **Pin** puts the note in the Pinned group; **Unpin** takes it out.
- **Archive** hides the note from the list and closes it. Find it again with
  **Archived**, open it and press **Unarchive**.
- **Move up** / **Move down** change the note's place in its group. In the
  list, **Alt+Up** / **Alt+Down** on a row does the same, and on a wide screen
  you can drag a row. A move stays among the notes of the same priority: a
  drop on a note of another priority moves nothing. To change a note's
  priority, use **Priority** in the open note.
- **Delete** removes the note at once and shows **Note deleted** with
  **Undo** for 10 seconds. Undo brings it back as it was. When the message
  goes away, the note is deleted for good; there is no trash.

## From the top bar and the command palette

- Type `/note <text>` (or `/n <text>`) in the top bar and send it: it makes a
  note titled `<text>` (its first 200 characters) and posts nothing. When the
  page shows a topic, an issue or a calendar entry, the note's first link is
  that page. **Note created** shows with **Open**, which opens the new note.
  A `/note` with no text makes nothing and stays in the box.
- In the command palette (**Ctrl + K** / **Cmd + K**, not on a phone), type a note's title: the note is a
  **Note** hit, and choosing it opens the note. Archived notes are not
  listed there.

## Coming next

Spec 155 adds the rest in the next steps: **Add to note** on messages,
issues and rows; and Settings -> Notes to export or erase all your notes.

If an administrator turns Notes off for the whole Spool, the page says so and
your notes are kept.
