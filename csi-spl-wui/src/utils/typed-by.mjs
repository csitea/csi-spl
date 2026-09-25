/**
 * specs/036 FR-011 — a line the owner TYPED at an agent's terminal is posted
 * from=<agent> (the box signs it; it cannot mint a human's identity) and the
 * hub adds a VERIFIED `typed_by: HUM-n` beside the envelope, like edited_by.
 * Such a row is shown as the HUMAN (avatar and name), with a small
 * "via terminal <agent>" badge; every other row keeps its sender.
 */
import { BROWSER_BOX } from './view-api.mjs'

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
