/**
 * Spec 155 2.3 (B8, SPL-4578): "Add to note" on an object. Each builder turns
 * the object on screen into the typed link a note stores (stores/notes.ts
 * NoteLinkIn): { kind, workspace_id, ref, day?, label }. The label is the
 * object's title (topic subject, issue title, entry title, channel name, the
 * first 80 characters of a message); the hub caps it at 200.
 *
 *   a topic card      topic    its task id         its first line
 *   any other message msg      its msg id          its first 80 characters
 *   an issue          issue    its key             its title
 *   a calendar entry  event    its id + day        its title (an issue
 *                                                  deadline is that issue)
 *   a channel row     channel  its id (the route)  its name
 *
 * Pure and import-free (SidebarRowMenu is on the first screen): the
 * workspace and an entry's day are arguments; no workspace, no link (the hub
 * refuses a workspace link without one).
 * The picker's list (pickerNotes) and the issue menu's item (withNoteItem)
 * are here too, so node tests them.
 */
/* spec 155 2.4: a label <= 200 characters; a message's label is its first 80 */
export const NOTE_LABEL_MAX = 200
export const NOTE_MSG_LABEL = 80

/** The item id every "Add to note" menu uses. */
export const ADD_TO_NOTE_ID = 'add-to-note'

const oneLine = (text) => String(text ?? '').replace(/\s+/g, ' ').trim()
const cut = (text, max) => Array.from(text).slice(0, max).join('')
const firstLine = (text) => oneLine(String(text ?? '').split('\n').find((l) => l.trim()) || '')

function linkOf(kind, workspace, ref, label, day) {
  const ws = String(workspace || '')
  const r = String(ref || '')
  if (!ws || !r) return null
  const link = { kind, workspace_id: ws, ref: r, label: cut(oneLine(label), NOTE_LABEL_MAX) }
  return day ? { ...link, day } : link
}

/**
 * A message's link: a topic card (`topic`, the menu of a topic's own card)
 * links its topic, any other line the message itself.
 *
 * @param {{ msg_id?: string, task_id?: string, body?: string } | null | undefined} msg
 * @param {{ topic?: boolean, workspace?: string }} [opts]
 */
export function msgNoteLink(msg, opts = {}) {
  const m = msg && typeof msg === 'object' ? msg : {}
  const o = opts && typeof opts === 'object' ? opts : {}
  if (o.topic && m.task_id) return linkOf('topic', o.workspace, m.task_id, firstLine(m.body))
  return linkOf('msg', o.workspace, m.msg_id, cut(oneLine(m.body), NOTE_MSG_LABEL))
}

/**
 * An issue's link, by its key.
 *
 * @param {{ key?: string, title?: string } | null | undefined} issue
 * @param {string} workspace
 */
export function issueNoteLink(issue, workspace) {
  const i = issue && typeof issue === 'object' ? issue : {}
  return linkOf('issue', workspace, i.key, i.title || i.key)
}

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/

/**
 * A calendar entry's link: its id and `day`, the day the grid shows it on
 * (calendar-drag.mjs calEventDay). An issue deadline (source `issue`, its id
 * is the issue key) links the issue.
 *
 * @param {{ id?: string, title?: string, source?: string } | null | undefined} ev
 * @param {string} workspace
 * @param {string} day
 */
export function eventNoteLink(ev, workspace, day) {
  if (!ev || !ev.id) return null
  if (ev.source === 'issue') return linkOf('issue', workspace, ev.id, ev.title || ev.id)
  return DAY_RE.test(String(day || '')) ? linkOf('event', workspace, ev.id, ev.title, day) : null
}

/**
 * A channel row's link: the id its route takes (/channel/<id>), labelled by its name.
 *
 * @param {{ id?: string, name?: string } | null | undefined} channel
 * @param {string} workspace
 */
export function channelNoteLink(channel, workspace) {
  const c = channel && typeof channel === 'object' ? channel : {}
  return linkOf('channel', workspace, c.id, c.name || c.id)
}

/**
 * The picker's rows (D3): the notes not archived, most recently changed
 * first, those whose title or text holds the filter.
 *
 * @template {{ title?: string, snippet?: string, archived?: boolean, updated_at?: string }} T
 * @param {readonly T[]} list
 * @param {string} query
 * @returns {T[]}
 */
export function pickerNotes(list, query) {
  const q = String(query || '').trim().toLowerCase()
  return (Array.isArray(list) ? list : [])
    .filter((n) => n && !n.archived && (!q || `${n.title || ''}\n${n.snippet || ''}`.toLowerCase().includes(q)))
    .sort((a, b) => String(b.updated_at || '').localeCompare(String(a.updated_at || '')))
}

/**
 * A menu's items with "Add to note" right before Archive (spec 1.2 row 17),
 * else at the end; unchanged when `on` is false or it is there already.
 *
 * @template {{ id: string }} T
 * @param {readonly T[]} items
 * @param {boolean} on
 * @param {T} item
 * @returns {T[]}
 */
export function withNoteItem(items, on, item) {
  const list = Array.isArray(items) ? [...items] : []
  if (!on || list.some((i) => i && i.id === ADD_TO_NOTE_ID)) return list
  const at = list.findIndex((i) => i && i.id === 'archive')
  list.splice(at < 0 ? list.length : at, 0, item)
  return list
}
