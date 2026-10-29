/**
 * Spec 153 3.9 (SPL-4206; owner HUM-10, t1 fb9b6e4b, msg 78f2071b: "we should
 * see from tis view also different tabs per agent ... the first tab should
 * be - one which lanes this agent is working on"): the tabs of the agent
 * card (pages/monitoring/agents/[id].vue). Lanes is first and the default;
 * the URL keeps the open tab in `?tab=`, so a link opens the right one.
 */

/** The card's tabs, in their order; the first is the default. */
export const AGENT_CARD_TABS = ['lanes', 'details']

/** The tab a `?tab=` value opens: a known tab, else the first. */
export function agentCardTab(q) {
  const v = Array.isArray(q) ? q[0] : q
  return AGENT_CARD_TABS.includes(v) ? v : AGENT_CARD_TABS[0]
}

/** The query that opens `tab`, the other keys kept; the default tab drops the key. */
export function agentCardTabQuery(query, tab) {
  const out = { ...(query || {}) }
  if (tab === AGENT_CARD_TABS[0]) delete out.tab
  else out.tab = tab
  return out
}
