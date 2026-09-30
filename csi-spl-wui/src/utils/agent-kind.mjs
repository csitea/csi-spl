// CLE-77794: what kind of agent an id names, so the Agents section can say it
// plainly (owner 2026-09-30, topic 1fc29f99: "for the agents it should be clear
// are they antigravity, claude, grok etc.").
//
// The hub roster carries only the agent id (rdb 0001 roster.agent_id ~
// '^[A-Z]{2,4}-[0-9]+$'), never a CLI/model field, so the kind is derived from
// the id PREFIX — the same convention the spawn registry and the tmux windows
// use (CLE-* Claude, AGY-* Antigravity, GRK-* Grok, QWN-* Qwen). If the hub
// ever exposes a real kind field, prefer it and keep this as the fallback.

/** id prefix -> a stable kind key; its label lives at agents.kinds.<key>. */
const KIND_BY_PREFIX = Object.freeze({
  CLE: 'claude',
  AGY: 'antigravity',
  GRK: 'grok',
  QWN: 'qwen',
})

/** A member id (HUM-<n>) is a person, not an agent. */
export function isHumanId(id) {
  return /^HUM-[0-9]+$/.test(String(id || ''))
}

/** true when id looks like an agent id (a <PREFIX>-<n>, not a human). */
export function isAgentId(id) {
  const s = String(id || '')
  return /^[A-Z]{2,4}-[0-9]+$/.test(s) && !isHumanId(s)
}

/**
 * The kind key of an agent id from its prefix; 'agent' when the prefix is not
 * one we know (a new CLI), so the row still says "Agent" rather than nothing.
 * @param {string} id
 * @returns {'claude' | 'antigravity' | 'grok' | 'qwen' | 'agent'}
 */
export function agentKind(id) {
  const m = String(id || '').match(/^([A-Z]{2,4})-[0-9]+$/)
  return (m && KIND_BY_PREFIX[m[1]]) || 'agent'
}

/** The i18n key for an agent id's kind label (agents.kinds.<key>). */
export function agentKindLabelKey(id) {
  return 'agents.kinds.' + agentKind(id)
}
