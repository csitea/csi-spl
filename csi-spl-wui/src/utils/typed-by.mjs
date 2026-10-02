/**
 * specs/036 FR-011 — a line the owner TYPED at an agent's terminal is posted
 * from=<agent> (the box signs it; it cannot mint a human's identity) and the
 * hub adds a VERIFIED `typed_by: HUM-n` beside the envelope, like edited_by.
 * Such a row is shown as the HUMAN (avatar and name), with a small
 * "via terminal <agent>" badge; every other row keeps its sender.
 */
import { BROWSER_BOX } from './view-api.mjs'
import { isParticipantId } from './agent-id.mjs'

const HUMAN_ID = /^HUM-[0-9]+$/

/**
 * Who a row is shown as: { id, box, via } where `via` is the agent whose
 * terminal the human typed into ('' for an ordinary row).
 * @param {{ from?: string, from_box?: string, typed_by?: string } | null | undefined} msg
 * @returns {{ id: string, box: string, via: string, viaBox: string }}
 */
export function typedByAuthor(msg) {
  const m = msg || {}
  const from = String(m.from || '')
  const box = m.from_box ? String(m.from_box) : ''
  const typed = typeof m.typed_by === 'string' ? m.typed_by : ''
  if (HUMAN_ID.test(typed) && typed !== from) {
    return { id: typed, box: BROWSER_BOX, via: from, viaBox: box }
  }
  return { id: from, box, via: '', viaBox: '' }
}

/* an agent id: c-004 or a legacy <PREFIX>-<n> (spec 061), never a member
   HUM-<n> nor a door-off guest GST-<n> */
const PERSON_ID = /^(HUM|GST)-/

/**
 * HUM-24 (csitea ba4696c1): an AI-generated row is marked apart from a
 * person's (a tint and an "AI" badge). AI means the row's SHOWN author is an
 * agent: a line the owner typed at an agent's terminal shows as the human
 * (above), so it stays a person's row; an empty or unknown sender is not
 * claimed as AI.
 * @param {{ from?: string, from_box?: string, typed_by?: string } | null | undefined} msg
 * @returns {boolean}
 */
export function isAiMessage(msg) {
  const id = typedByAuthor(msg).id
  return isParticipantId(id) && !PERSON_ID.test(id)
}

/**
 * CLE-77889 (owner, t1 99905c80: "even if I write some messages in the direct
 * messages - those are shown to me as new ... they should be shown as new for
 * the receiver of those msgs, but not me"): a row is the VIEWER'S OWN when its
 * SHOWN author is the viewer - their own post (any box), or a line they typed
 * at an agent's terminal (from=<agent>, typed_by=<viewer>), which the feed draws
 * as theirs. Every "new" rule (rail badges, the New-messages divider, a topic
 * card's unread replies, alerts) skips it; ids compare without their @box.
 * @param {{ from?: string, typed_by?: string } | null | undefined} msg
 * @param {string} [selfId] the viewer's v:1 id, with or without @box
 * @returns {boolean}
 */
export function isViewersOwn(msg, selfId = '') {
  const self = String(selfId || '').split('@')[0]
  if (!self || !msg) return false
  if (String(msg.from || '').split('@')[0] === self) return true
  const typed = typeof msg.typed_by === 'string' ? msg.typed_by.split('@')[0] : ''
  return HUMAN_ID.test(typed) && typed === self
}
