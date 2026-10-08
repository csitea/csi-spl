// CLE-77794: what kind of agent an id names, so the Agents section can say it
// plainly (owner 2026-09-30, topic 1fc29f99: "for the agents it should be clear
// are they antigravity, claude, grok etc.").
//
// The hub roster carries only the agent id, never a CLI/model field, so the
// kind is derived from the id: its letter (spec 061: c- Claude, a-
// Antigravity, g- Grok, m- Mistral (spec 110), q- Qwen) or its legacy prefix (CLE-, AGY-, GRK-,
// QWN-). The one map lives in agent-id.mjs. If the hub ever exposes a real
// kind field, prefer it and keep this as the fallback.

import { agentKindOf, isParticipantId } from './agent-id.mjs'

/** A member id (HUM-<n>) is a person, not an agent. */
export function isHumanId(id) {
  return /^HUM-[0-9]+$/.test(String(id || ''))
}

/** true when id looks like an agent id (c-004 or a legacy <PREFIX>-<n>, not a human). */
export function isAgentId(id) {
  const s = String(id || '')
  return isParticipantId(s) && !isHumanId(s)
}

/**
 * The kind key of an agent id from its prefix; 'agent' when the prefix is not
 * one we know (a new CLI), so the row still says "Agent" rather than nothing.
 * @param {string} id
 * @returns {'claude' | 'antigravity' | 'grok' | 'mistral' | 'qwen' | 'agent'}
 */
export function agentKind(id) {
  return agentKindOf(id)
}

/** The i18n key for an agent id's kind label (agents.kinds.<key>). */
export function agentKindLabelKey(id) {
  return 'agents.kinds.' + agentKind(id)
}
