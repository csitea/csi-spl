import { isoSeconds } from './iso-seconds.mjs'
import { typedByAuthor } from './typed-by.mjs'

/**
 * t1 b6c742f0 (HUM-10; csitea 41261a3f HUM-24): an "AI actions" group in the
 * menu of a message. HUM-10 643c30a8: "add them to agents' messages as well
 * and actually add them to every card which has right click menu" - any
 * stored message (a person's or an agent's), and every card kind that has a
 * right-click menu through its subject adapter (aiSubject: a topic row, an
 * issue / epic). Loaded lazily, with the menu (MessageMenu.vue) and on a pick
 * (MessageCard.vue), never in the initial JS.
 *
 * `post` actions write a reply in the SAME topic, by the clicking member, that
 * names the source message and carries the instruction: the dispatcher desk
 * reads every post and answers there. `issue` (HUM-10 ad5829e1: "turn into
 * issue"; e9d1f99a: "to point to the issues UI") makes an issue from the
 * message and opens it on /issues. `calendar` (HUM-10 f7d18dfb, 69224b39,
 * 6a855f5f) creates a calendar event from it through the calendar API
 * (POST /v1/calendar/events, spec 089 section 6.1) and opens its week on
 * /calendar.
 *
 * The instruction is English on purpose: the desk reads it, it is not a
 * label. The labels are `feed.msg_menu.ai.*`.
 */
export const AI_ACTIONS = [
  { id: 'ai-debate', icon: 'users', key: 'debate', mode: 'post', name: 'Debate', instruction: 'run an agent panel debate on this message' },
  { id: 'ai-spec', icon: 'file-text', key: 'spec', mode: 'post', name: 'Spec', instruction: 'write a spec from this message' },
  { id: 'ai-implement', icon: 'bot', key: 'implement', mode: 'post', name: 'Implement', instruction: 'build what this message asks for (a lane)' },
  { id: 'ai-analyse', icon: 'search', key: 'analyse', mode: 'post', name: 'Analyse', instruction: 'reply with an analysis of this message' },
  { id: 'ai-issue', icon: 'issues', key: 'issue', mode: 'issue', name: 'Turn into an issue', instruction: '' },
  { id: 'ai-risks', icon: 'alert-triangle', key: 'risks', mode: 'post', name: 'Find risks', instruction: 'reply with the risks of this message' },
  { id: 'ai-calendar', icon: 'calendar', key: 'calendar', mode: 'calendar', name: 'Add to calendar', instruction: '' },
]

const QUOTE_MAX = 600
const TITLE_MAX = 120
/* rdb 0125: a calendar event's description is at most 4000 characters */
const EVENT_TEXT_MAX = 3500
const HOUR_MS = 3600 * 1000

/** The action of a menu item id, or null. */
export function aiAction(id) {
  return AI_ACTIONS.find((a) => a.id === String(id || '')) || null
}

/** the topic the message lives in */
function sourceTopic(m) {
  return String(m.task_id || m.parent_task_id || '')
}

/**
 * HUM-10 643c30a8: the card kinds whose right-click menu ends with the group,
 * each through its adapter (aiSubject). `msg` is a message row as it is.
 */
export const AI_SUBJECT_KINDS = ['msg', 'topic', 'issue']

/**
 * The subject of a card's AI actions: one shape every action reads (the
 * message fields: msg_id, task_id, channel, from, body), plus `ai_kind`.
 * - `msg`: the message row itself.
 * - `topic` ({ task_id, title }): a topic row (the sidebar Topics tab, the
 *   home topic list); a pick opens the topic and runs on its opening message
 *   (composables/useAiListRun.ts runTopic), so it carries no body here.
 * - `issue` (an Issue of utils/issues.mjs, epic / feature too): title and
 *   description as the body, its author, its discussion topic (task_id) and
 *   channel - a post lands in the issue's discussion; `ai_ref` / `ai_link`
 *   name it in the source line.
 * @param {string} kind
 * @param {unknown} card
 * @returns {Record<string, any> | null} null for an unknown kind or card
 */
export function aiSubject(kind, card) {
  const c = card && typeof card === 'object' ? /** @type {Record<string, any>} */ (card) : null
  if (!c) return null
  if (kind === 'msg') return c
  if (kind === 'topic') {
    const taskId = String(c.task_id || '')
    return taskId ? { ai_kind: 'topic', task_id: taskId, title: String(c.title || '') } : null
  }
  if (kind === 'issue') {
    const key = String(c.key || '')
    if (!key) return null
    const top = c.kind === 'epic' || c.kind === 'feature'
    const title = String(c.title || '').trim()
    const description = String(c.description || '').trim()
    return {
      ai_kind: 'issue',
      ai_ref: key,
      ai_link: { path: '/issues', search: `?${top ? 'epic' : 'issue'}=${encodeURIComponent(key)}` },
      msg_id: '',
      task_id: String(c.task_id || ''),
      channel: String(c.channel || ''),
      from: String(c.created_by || ''),
      body: [title, description].filter(Boolean).join('\n\n'),
    }
  }
  return null
}

/**
 * Does `subject` get the AI actions? A stored message with a known author -
 * a person's or an agent's (HUM-10 643c30a8) - a topic row, or an issue /
 * epic. A still-pending (unsent) row never does.
 * @param {unknown} subject
 */
export function offersAiActions(subject) {
  const m = subject && typeof subject === 'object' ? /** @type {Record<string, any>} */ (subject) : null
  if (!m || m.pending) return false
  /* an epic in the sidebar is a summary: its discussion topic is read on the pick */
  if (m.ai_kind === 'issue') return Boolean(String(m.ai_ref || ''))
  if (!sourceTopic(m)) return false
  if (m.ai_kind === 'topic') return true
  return Boolean(String(m.msg_id || '')) && Boolean(typedByAuthor(m).id)
}

/**
 * The menu entries, the group heading on the first one; [] when the subject
 * gets none. An issue does not offer "Turn into an issue".
 * @param {unknown} subject
 * @returns {{ id: string, icon: string, labelKey: string, groupKey?: string }[]}
 */
export function aiMenuItems(subject) {
  if (!offersAiActions(subject)) return []
  const own = /** @type {Record<string, any>} */ (subject).ai_kind === 'issue'
  return AI_ACTIONS.filter((a) => !(own && a.mode === 'issue')).map((a, i) => ({
    id: a.id,
    icon: a.icon,
    labelKey: `feed.msg_menu.ai.${a.key}`,
    ...(i === 0 ? { groupKey: 'feed.msg_menu.ai.group' } : {}),
  }))
}

/** the phone sheet's one entry that turns the sheet into the seven actions */
export const AI_MORE = { id: 'ai-more', icon: 'bot', labelKey: 'feed.msg_menu.ai.group' }

/**
 * t1 b6c742f0 (HUM-10 14dc0232: "add those same actions to every msg card in
 * every view"; 643c30a8: "every card which has right click menu"): a menu's
 * own entries plus the AI actions group - the one rule every card menu uses
 * (MessageMenu, the search row and Flow entry menus, the sidebar / home topic
 * row menu, the issue / epic menu); `msg` is the card's subject (aiSubject). Desktop: the group closes the list. The phone sheet opens WHOLE,
 * Delete last (t1 7a6be5a3): one "AI actions" entry before Delete; `only`
 * (that entry picked) is the seven actions alone.
 * @template {{ id: string }} T
 * @param {T[]} base
 * @param {unknown} msg
 * @param {{ sheet?: boolean, only?: boolean }} [opts]
 */
export function withAiItems(base, msg, opts = {}) {
  const o = opts && typeof opts === 'object' ? opts : {}
  const ai = aiMenuItems(msg)
  if (o.only) return ai.map(({ groupKey: _g, ...it }) => it)
  if (!ai.length) return base
  if (!o.sheet) return [...base, ...ai]
  const del = base.findIndex((it) => it.id === 'delete' || it.id === 'delete-topic')
  return del < 0 ? [...base, AI_MORE] : [...base.slice(0, del), AI_MORE, ...base.slice(del)]
}

function authorOf(m) {
  const a = typedByAuthor(m)
  return a.box ? `${a.id}@${a.box}` : a.id
}

/** "Source: workspace W, topic T, msg M, by A - link", one line */
function sourceLine(m, where) {
  const w = where && typeof where === 'object' ? where : {}
  const parts = []
  if (w.workspace) parts.push(`workspace **${String(w.workspace)}**`)
  if (m.ai_ref) parts.push(`issue \`${String(m.ai_ref)}\``)
  parts.push(`topic \`${sourceTopic(m)}\``)
  if (!m.ai_ref) parts.push(`msg \`${String(m.msg_id || '')}\``)
  parts.push(`by ${authorOf(m)}`)
  const link = String(w.link || '')
  return `Source: ${parts.join(', ')}${link ? ` - ${link}` : ''}`
}

function quoted(body) {
  const text = String(body || '').trim()
  if (!text) return ''
  const cut = text.length > QUOTE_MAX ? `${text.slice(0, QUOTE_MAX - 1)}…` : text
  return cut.split('\n').map((l) => (l ? `> ${l}` : '>')).join('\n')
}

/**
 * Where a `post` action writes: the source message's topic, as a reply, in
 * its channel ('' for a direct message: the page's peer takes it).
 * @param {unknown} msg
 * @returns {{ taskId: string, channel: string }}
 */
export function aiPostTarget(msg) {
  const m = msg && typeof msg === 'object' ? msg : {}
  return { taskId: sourceTopic(m), channel: String(m.channel || '').replace(/^#/, '') }
}

/**
 * The post a `post` action sends: the instruction, the source, the quote.
 * @param {unknown} msg
 * @param {string} actionId
 * @param {{ workspace?: string, link?: string }} [where]
 * @returns {string} '' for an unknown or non-post action
 */
export function aiActionPost(msg, actionId, where = {}) {
  const a = aiAction(actionId)
  const m = msg && typeof msg === 'object' ? msg : null
  if (!a || a.mode !== 'post' || !m) return ''
  return [`**AI action: ${a.name}** (ai-action=${a.key}): ${a.instruction}.`, sourceLine(m, where), quoted(m.body)].filter(Boolean).join('\n\n')
}

/** the message's first line, without its markdown lead, cut to a title */
function titleOf(m) {
  const body = String(m.body || '').trim()
  const first = body.split('\n').map((l) => l.replace(/^\s*(?:#+|>+|[-*]\s)\s*/, '').trim()).find(Boolean) || ''
  if (!first) return `Message ${String(m.msg_id || '').slice(0, 8)}`
  return first.length > TITLE_MAX ? `${first.slice(0, TITLE_MAX - 1)}…` : first
}

/**
 * The issue an `issue` action creates: the message's first line as the
 * title, its text and its source as the description.
 * @param {unknown} msg
 * @param {{ workspace?: string, link?: string }} [where]
 * @returns {{ title: string, description: string }}
 */
export function aiIssueBody(msg, where = {}) {
  const m = msg && typeof msg === 'object' ? msg : {}
  const body = String(m.body || '').trim()
  return { title: titleOf(m), description: [body, '---', sourceLine(m, where)].filter(Boolean).join('\n\n') }
}

/**
 * Where the issues UI opens the new issue.
 * @param {string} key the issue key, e.g. SPL-12
 * @returns {{ path: string, query: Record<string, string> }}
 */
export function aiIssueRoute(key) {
  return { path: '/issues', query: { issue: String(key || '') } }
}

/**
 * The calendar event a `calendar` action creates (spec 089 6.1.2 create
 * body): the message's first line as the title, its text and source as the
 * description, the next whole UTC hour for one hour, linked to the topic.
 * The member moves it to the right time on the calendar.
 * @param {unknown} msg
 * @param {{ workspace?: string, link?: string }} [where]
 * @param {number} [nowMs]
 * @returns {{ title: string, description: string, starts_at: string, ends_at: string, topic_id: string }}
 */
export function aiEventBody(msg, where = {}, nowMs = Date.now()) {
  const m = msg && typeof msg === 'object' ? msg : {}
  const text = String(m.body || '').trim()
  const body = text.length > EVENT_TEXT_MAX ? `${text.slice(0, EVENT_TEXT_MAX - 1)}…` : text
  const start = (Math.floor(nowMs / HOUR_MS) + 1) * HOUR_MS
  const iso = (ms) => isoSeconds(new Date(ms))
  return {
    title: titleOf(m),
    description: [body, '---', sourceLine(m, where)].filter(Boolean).join('\n\n'),
    starts_at: iso(start),
    ends_at: iso(start + HOUR_MS),
    topic_id: sourceTopic(m),
  }
}

/**
 * Where the calendar opens a created event: the week of its UTC day.
 * @param {{ starts_at?: string } | null | undefined} event
 * @returns {{ path: string, query: Record<string, string> }}
 */
export function aiCalendarRoute(event) {
  const day = String((event && event.starts_at) || '').slice(0, 10)
  return { path: '/calendar', query: /^\d{4}-\d{2}-\d{2}$/.test(day) ? { d: day } : {} }
}

/**
 * POST /v1/calendar/events → the created event. The mock workspace keeps it
 * in calendar-mock (this browser only), so /calendar shows it there too.
 * @param {{ mock?: boolean, base?: string, token?: string, credentials?: RequestCredentials }} api
 * @param {ReturnType<typeof aiEventBody>} body
 * @returns {Promise<{ id: string, starts_at: string }>}
 */
export async function createCalendarEvent(api, body) {
  if (api && api.mock) {
    const { mockCalendarCreate } = await import('./calendar-mock.mjs')
    return mockCalendarCreate(body)
  }
  const headers = { accept: 'application/json', 'content-type': 'application/json' }
  if (api && api.token) headers.authorization = `Bearer ${api.token}`
  const r = await fetch(`${String((api && api.base) || '')}/v1/calendar/events`, {
    method: 'POST', credentials: api && api.credentials, headers, body: JSON.stringify(body),
  })
  if (!r.ok) throw Object.assign(new Error(`calendar create ${r.status}`), { status: r.status })
  const out = await r.json()
  if (!out || !out.event || !out.event.id) throw new Error('calendar create: no event')
  return out.event
}
