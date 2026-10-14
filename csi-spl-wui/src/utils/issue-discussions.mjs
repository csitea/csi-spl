// Every issue links to one or more discussions (SPL-1593, rdb 0194,
// issues-v1 §2.1). The owner (HUM-10, t1 fcf09921): "Issues must be linked to
// one or more discussions." (msg 3e75e13e) "We must create a special part of
// the UI somewhere in the bottom panel where one could click on that one or
// more discussions." (msg 9a8e4764) An archived discussion still opens; a
// deleted one opens the "no longer exists" page (msg 28b479fd).

/** a topic id */
const TOPIC_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
/** a topic's short id: its first 8 hex digits (the hub resolves it) */
const TOPIC_SHORT = /^[0-9a-f]{8}$/
/** a link that carries /t/<id or short id> */
const TOPIC_LINK = /\/t\/([0-9a-f]{8}(?:-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?)(?:[^0-9a-f-]|$)/

export const DISCUSSION_STATES = ['live', 'archived', 'gone']

/**
 * One link as the hub sent it, every field present.
 * @param {unknown} raw
 * @returns {{ task_id: string, state: string, title: string, channel: string, linked_by: string, linked_at: string }}
 */
export function normalizeDiscussion(raw) {
  const r = raw && typeof raw === 'object' ? /** @type {Record<string, unknown>} */ (raw) : {}
  const state = String(r.state || '')
  return {
    task_id: String(r.task_id || ''),
    /* a list read carries no state: the link is shown as live until the single read */
    state: DISCUSSION_STATES.includes(state) ? state : 'live',
    title: String(r.title || ''),
    channel: String(r.channel || ''),
    linked_by: String(r.linked_by || ''),
    linked_at: String(r.linked_at || ''),
  }
}

/** @param {unknown} raw */
export function normalizeDiscussions(raw) {
  return Array.isArray(raw) ? raw.map(normalizeDiscussion).filter((d) => d.task_id) : []
}

/**
 * What a member typed or pasted as a discussion: a topic id, its 8-hex short
 * id or a link carrying /t/<either>, lower-cased; '' when it is none of them.
 * @param {unknown} input
 */
export function discussionRef(input) {
  const v = String(input || '').trim().toLowerCase()
  if (TOPIC_ID.test(v) || TOPIC_SHORT.test(v)) return v
  const m = TOPIC_LINK.exec(v)
  return m ? m[1] : ''
}

/** The topic's short id, as the WUI shows a topic with no title. */
export function shortTopic(id) {
  return String(id || '').slice(0, 8)
}

/**
 * Where a link opens: the topic page, or for a deleted discussion the page
 * that says it no longer exists (the issue it came from rides along).
 * @param {{ task_id: string, state: string }} d
 * @param {string} issueKey
 */
export function discussionPath(d, issueKey = '') {
  if (d.state === 'gone') {
    const q = new URLSearchParams({ topic: d.task_id })
    if (issueKey) q.set('issue', issueKey)
    return `/discussion-gone?${q.toString()}`
  }
  return `/t/${d.task_id}`
}

/**
 * The i18n key of a refused link, unlink or create (issues-v1 §2.2 tokens).
 * @param {{ status?: number, token?: string }} e
 */
export function discussionErrorKey(e) {
  switch (String(e?.token || '')) {
    case 'unknown_discussion': return 'issue_discussions.error_unknown'
    case 'ambiguous_discussion': return 'issue_discussions.error_ambiguous'
    case 'last_discussion': return 'issue_discussions.error_last'
    case 'discussion_required': return 'issue_discussions.required'
    case 'bad_issue': return 'issue_discussions.error_bad'
  }
  return 'issue_discussions.error_failed'
}

/* --- the mock hub (mock mode, no hub) ------------------------------------- */

/** The mock tenant's topics a discussion can be, with their opening line (utils/mock-data.mjs). */
export const MOCK_TOPICS = {
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb': 'Review the spool WUI scaffold and keep tests green.',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa': 'Welcome to #lobby. This is the lde mock feed.',
}
/** a topic the mock says was deleted */
export const MOCK_GONE_TOPIC = '9999dead-0000-4000-8000-000000000001'
/** the mock tenant's default discussion (rdb 0194 issue_discussion_default) */
export const MOCK_DEFAULT_TOPIC = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'

function mockErr(status, token) {
  return Object.assign(new Error(`spool ${status} ${token}`), { status, token })
}

/** a known mock topic id for ref, or throws the hub's refusal */
export function mockResolveTopic(ref) {
  const r = discussionRef(ref)
  if (!r) throw mockErr(400, 'bad_issue')
  const ids = [...Object.keys(MOCK_TOPICS), MOCK_GONE_TOPIC].filter((id) => id === r || id.startsWith(r))
  if (ids.length > 1) throw mockErr(400, 'ambiguous_discussion')
  if (!ids.length || ids[0] === MOCK_GONE_TOPIC) throw mockErr(400, 'unknown_discussion')
  return ids[0]
}

/** a create body's discussions, resolved; refuses none */
export function mockCreateDiscussions(body, me, at) {
  const list = Array.isArray(body?.discussions) ? body.discussions : []
  if (!list.length) throw mockErr(400, 'discussion_required')
  const ids = [...new Set(list.map(mockResolveTopic))]
  return ids.map((task_id) => ({ task_id, linked_by: me, linked_at: at }))
}

/** links as a single read answers them: each one's state and title */
export function mockFullDiscussions(links) {
  return (links || []).map((l) => {
    const gone = l.task_id === MOCK_GONE_TOPIC || !(l.task_id in MOCK_TOPICS)
    return { ...l, state: gone ? 'gone' : 'live', title: gone ? '' : MOCK_TOPICS[l.task_id] }
  })
}

/** issue i with the topic ref linked (no change when it already is) */
export function mockLinkDiscussion(i, ref, me, at) {
  const task_id = mockResolveTopic(ref)
  if (i.discussions.some((d) => d.task_id === task_id)) return i
  return { ...i, discussions: [...i.discussions, { task_id, state: 'live', title: '', channel: '', linked_by: me, linked_at: at }] }
}

/** issue i without the link to task; refuses an unknown link and the last one */
export function mockUnlinkDiscussion(i, task) {
  if (!i.discussions.some((d) => d.task_id === task)) throw mockErr(404, 'not_found')
  if (i.discussions.length <= 1) throw mockErr(409, 'last_discussion')
  return { ...i, discussions: i.discussions.filter((d) => d.task_id !== task) }
}
