// spec 061 (agent id rename), FR-001: the WUI's ONE agent-id unit. Every
// file that validates or parses an id calls this one; no other file carries
// an id regex.
//
// Wave A = accept only: readers take BOTH forms.
//   new      c-004, a-004, g-004, m-004, q-004   (^[acgmq]-[0-9]{3}$, lower case;
//            m- Mistral, spec 110; FR-005 with the Go agentid grammar)
//   legacy   CLE-77952, AGY-1, GRK-3, QWN-9, ORC-1 ([A-Z]{2,4}-[0-9]+)
//   people   HUM-17, GST-3, and the browser box BOX-1, unchanged
//
// LEGACY_ID_UNTIL is the end of the legacy form on a WRITE path (spec 061
// section 0). It must equal the Go agentid.LegacyUntil (FR-005, pinned by
// tests/unit/agent-id.test.mjs). Rendering stored history keeps accepting a
// legacy id after it: the stored body is history (spec Q5).
//
// The clock is injectable (FR-004): a test that writes a legacy id pins it
// with setAgentIdNow, so CI never turns red at the deadline on its own.

/** The end of legacy agent ids on a write path (spec 061 section 0; owner
    decision 2026-10-02 ~06:52Z moved it one day, to 2026-10-03). */
export const LEGACY_ID_UNTIL = '2026-10-03T20:59:59Z'
const LEGACY_UNTIL_MS = Date.parse(LEGACY_ID_UNTIL)

/** Regex sources, for the parsers that embed an id in a bigger pattern. */
export const AGENT_ID_SRC = '[acgmq]-[0-9]{3}(?![0-9])'
export const LEGACY_ID_SRC = '[A-Z]{2,4}-[0-9]+'
/** Any participant id, new or legacy (an agent, a member, a guest, a box). */
export const PARTICIPANT_ID_SRC = `(?:${AGENT_ID_SRC}|${LEGACY_ID_SRC})`
/** A box name (spec 058): `<ID>@<box>`. */
export const BOX_ID_SRC = '[a-z0-9][a-z0-9-]{0,31}'

const NEW_RE = new RegExp(`^${AGENT_ID_SRC}$`)
const LEGACY_RE = new RegExp(`^${LEGACY_ID_SRC}$`)
const NON_AGENT_RE = /^(HUM|GST|BOX)-[0-9]+$/

/** letter (new) or prefix (legacy) -> kind key; its label is agents.kinds.<key>. */
const KIND = Object.freeze({
  a: 'antigravity', c: 'claude', g: 'grok', m: 'mistral', q: 'qwen',
  AGY: 'antigravity', CLE: 'claude', GRK: 'grok', QWN: 'qwen',
})

/* A browser e2e test cannot reach setAgentIdNow inside the bundle, so it pins
   the clock with globalThis.SPOOL_AGENT_ID_NOW (an ISO instant), set before
   the page loads; the orc's SPOOL_NOW does the same for bash. The hub is the
   authority on a write path, so this only moves the browser's own check. */
const realNow = () => {
  const pin = typeof globalThis !== 'undefined' ? globalThis.SPOOL_AGENT_ID_NOW : undefined
  return pin ? Date.parse(String(pin)) : Date.now()
}
let nowFn = realNow

/** Pin the clock (ms or an ISO string); no argument restores the real clock. */
export function setAgentIdNow(t) {
  if (t === undefined) nowFn = realNow
  else {
    const ms = typeof t === 'number' ? t : Date.parse(String(t))
    nowFn = () => ms
  }
}

/** True while a legacy agent id is still accepted on a write path. */
export function legacyAccepted(now = nowFn()) {
  return now <= LEGACY_UNTIL_MS
}

/** A new-form agent id: c-004. */
export function isNewAgentId(id) {
  return NEW_RE.test(String(id || ''))
}

/** A legacy agent id: CLE-77952 (never HUM/GST/BOX). */
export function isLegacyAgentId(id) {
  const s = String(id || '')
  return LEGACY_RE.test(s) && !NON_AGENT_RE.test(s)
}

/** An agent id in either form, for reading stored rows (never a person or box). */
export function isAgentId(id) {
  return isNewAgentId(id) || isLegacyAgentId(id)
}

/** Any participant id: an agent in either form, HUM-, GST- or BOX-. */
export function isParticipantId(id) {
  const s = String(id || '')
  return NEW_RE.test(s) || LEGACY_RE.test(s)
}

/** An agent id a WRITE path accepts now: the new form, or legacy until LEGACY_ID_UNTIL. */
export function isWritableAgentId(id, now = nowFn()) {
  return isNewAgentId(id) || (isLegacyAgentId(id) && legacyAccepted(now))
}

/**
 * Typed input normalised ONCE, at the edge (spec 061 section 2): `C-004` ->
 * `c-004`, `hum-7` -> `HUM-7`. '' when it is not a participant id.
 */
export function normalizeId(raw) {
  const s = String(raw || '').trim()
  const low = s.toLowerCase()
  if (NEW_RE.test(low)) return low
  const up = s.toUpperCase()
  return LEGACY_RE.test(up) ? up : ''
}

/** The id's kind letter (new) or prefix (legacy); '' when it is not an id. */
export function idPrefix(id) {
  const s = String(id || '')
  if (NEW_RE.test(s)) return s[0]
  const m = s.match(/^([A-Z]{2,4})-[0-9]+$/)
  return m ? m[1] : ''
}

/** 'claude' | 'antigravity' | 'grok' | 'mistral' | 'qwen', or 'agent' for an unknown CLI. */
export function agentKindOf(id) {
  return KIND[idPrefix(id)] || 'agent'
}
