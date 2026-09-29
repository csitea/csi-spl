/**
 * The first-run checklist (W15, spec 047, SPL-1172): what a tenant's admin
 * or business owner sees on the home screen until the workspace is set up -
 * the next 3 steps, each done by what the hub already shows:
 *   invite   another member, or an open invite     (GET /v1/members)
 *   agent    an agent seated on a box              (GET /v1/view/roster)
 *   topic    a first topic                         (the home list itself)
 * Hidden once all three are done, or when the viewer hides it (per tenant,
 * this browser). Node tests import this file.
 */

export const FIRST_RUN_STEPS = [
  { id: 'invite', to: '/tenant-settings/members' },
  { id: 'agent', to: '/tenant-settings/agents' },
  { id: 'topic', to: '/lobby' },
]

/** Browser storage key of the viewer's "Hide" for one tenant. */
export const firstRunHiddenKey = (tenant) => 'spl-first-run-hidden:' + String(tenant || '')

/**
 * The steps with their state. members / invites: counts from /v1/members
 * (null = unknown, the step stays open); roster: the /v1/view/roster map;
 * topics: the home list's length.
 */
export function firstRunSteps({ members = null, invites = null, roster = null, topics = 0 } = {}) {
  const agents = Object.entries(roster || {}).some(([box, ids]) => box !== 'box-wui' && Array.isArray(ids) && ids.length > 0)
  const done = {
    invite: (Number(members) || 0) > 1 || (Number(invites) || 0) > 0,
    agent: agents,
    topic: (Number(topics) || 0) > 0,
  }
  return FIRST_RUN_STEPS.map((s) => ({ ...s, done: done[s.id] }))
}

/** Show the card: the viewer may set the tenant up, has not hidden it, and a step is open. */
export function firstRunVisible({ canSetUp, hidden, steps }) {
  return Boolean(canSetUp) && !hidden && Array.isArray(steps) && steps.some((s) => !s.done)
}
