// CLE-35064: the lde mock's POST /v1/messages/{src}/merge - the hub's rules
// (csi-spl-api internal/hub/merge.go) against the in-memory store. Loaded only
// in mock mode, from spool-client.mjs mergeMessage, so it stays out of the
// initial chunk.

/**
 * @param {{ me: { id: string, box: string }, messages: any[] }} state
 * @param {string} src the row that goes away
 * @param {string} into the row that keeps both bodies
 */
export function mockMerge(state, src, into) {
  const refuse = (status, token) => { throw Object.assign(new Error(token), { status, token }) }
  const a = state.messages.find((m) => m.msg_id === src)
  const b = state.messages.find((m) => m.msg_id === into)
  if (!a || !b) refuse(404, 'not_found')
  if (a.task_id !== b.task_id) refuse(409, 'not_same_thread')
  if (a.from !== b.from) refuse(409, 'not_same_author')
  if (a.from !== state.me.id) refuse(403, 'not_allowed')
  if (a.from_box !== state.me.box || b.from_box !== state.me.box) refuse(409, 'not_editable')
  if (state.messages.some((m) => m.task_id === src && m.msg_id !== src)) refuse(409, 'has_replies')
  const at = (m) => String(m.received_at || m.ts || '')
  /* equal times (two sends in one tick): the one stored first is older,
     not the smaller random msg_id - that made the unit test flake */
  const aFirst = at(a) < at(b) || (at(a) === at(b) && state.messages.indexOf(a) < state.messages.indexOf(b))
  /* msg-menu.mjs joinBodies, inline (the hub's joinBodies) */
  const [older, newer] = aFirst ? [a.body, b.body] : [b.body, a.body]
  const o = String(older || '').replace(/\s+$/, '')
  const n = String(newer || '').replace(/^\s+/, '')
  b.body = o && n ? `${o}\n\n${n}` : o || n
  b.edited_at = new Date().toISOString().replace(/\.\d+Z$/, 'Z')
  b.edited_by = state.me.id
  b.revision = (Number(b.revision) || 1) + 1
  state.messages.splice(state.messages.indexOf(a), 1)
  return { ...b, merged_from: src }
}
