/**
 * Spec 155 2.10 (SPL-5255, owner HUM-10 t1 b7eb7c9a): every note has a
 * right-click menu and a menu button (a phone has no right-click) with three
 * items: Archive (Unarchive on an archived note), Turn into a discussion and
 * Delete. Archive and Delete act at once, no confirm, and show a small Undo
 * snackbar (owner msgs 79092e0b + ac509205). Pure and import-free, so node
 * tests it; the panel is UiPointMenu (components/NoteMenu.vue).
 *
 *   noteMenuItems(row)       the items for a list row or an open note
 *   noteDiscussionBody(note) the first post of the discussion a note becomes
 *   noteHasText(row)         whether there is anything to post
 */

/* the item ids every note menu uses */
export const NOTE_MENU_ARCHIVE = 'archive'
export const NOTE_MENU_UNARCHIVE = 'unarchive'
export const NOTE_MENU_DISCUSS = 'discuss'
export const NOTE_MENU_DELETE = 'delete'

/* the channel a note's discussion starts in: every member of a workspace has its lobby */
export const NOTE_DISCUSSION_CHANNEL = 'lobby'

/**
 * Anything to post: a title, a text (a list row's snippet) or a checklist line.
 *
 * @param {{ title?: string, body?: string, snippet?: string, items?: unknown[], items_total?: number } | null | undefined} n
 */
export function noteHasText(n) {
  if (!n || typeof n !== 'object') return false
  const text = `${n.title || ''}${n.body ?? n.snippet ?? ''}`.trim()
  const lines = Array.isArray(n.items) ? n.items.length : Number(n.items_total) || 0
  return Boolean(text) || lines > 0
}

/**
 * The menu's items, in order: Archive (or Unarchive), Turn into a
 * discussion, Delete. An empty note cannot become a discussion: the item
 * stays, locked, with its reason.
 *
 * @param {{ archived?: boolean, title?: string, body?: string, snippet?: string, items?: unknown[], items_total?: number } | null | undefined} n
 */
export function noteMenuItems(n) {
  const archived = Boolean(n && n.archived)
  const empty = !noteHasText(n)
  return [
    archived
      ? { id: NOTE_MENU_UNARCHIVE, icon: 'unarchive', labelKey: 'notes.unarchive' }
      : { id: NOTE_MENU_ARCHIVE, icon: 'archive', labelKey: 'notes.archive' },
    { id: NOTE_MENU_DISCUSS, icon: 'messages', labelKey: 'notes.menu.discuss', ...(empty ? { disabled: true, hintKey: 'notes.menu.discuss_empty' } : {}) },
    { id: NOTE_MENU_DELETE, icon: 'trash', labelKey: 'notes.delete', danger: true },
  ]
}

/**
 * The first post of a note's discussion: the title on the first line (it
 * becomes the topic's subject), then the text, then the checklist as
 * `- [x] line` / `- [ ] line`. Blank parts are left out.
 *
 * @param {{ title?: string, body?: string, items?: { text?: string, done?: boolean }[] } | null | undefined} n
 */
export function noteDiscussionBody(n) {
  if (!n || typeof n !== 'object') return ''
  const title = String(n.title || '').trim()
  const body = String(n.body || '').trim()
  const lines = (Array.isArray(n.items) ? n.items : [])
    .filter((i) => i && String(i.text || '').trim())
    .map((i) => `- [${i.done ? 'x' : ' '}] ${String(i.text).trim()}`)
  return [title, body, lines.join('\n')].filter(Boolean).join('\n\n')
}
