// Spec 153 3.18 (SPL-4786; owner HUM-10, a customer workspace topic d60646d9,
// msg 0443824f: "it must be seen too .. as part of the cluster"): the
// operator workspace's Agents and Boxes also list the boxes and agents the
// other workspaces have on their own, from GET /v1/operator/fleet-roster
// (403 for anyone but the operator workspace's admin). The hub sends one row
// per box: a box the operator workspace has is no row, only also_seated
// names the workspaces it is also seated in (dispatch c-002, msg a3d9b5c9).
// A foreign agent is keyed id@box like an own one, with its workspace beside
// it, so c-001@sat and c-001@<customer-box> are two rows.

import { mockFleetOperator } from './fleet-load.mjs'

/** The mock's customer workspace (no real name: dist hygiene). */
export const MOCK_FLEET_WORKSPACE = { id: 'tcust01', name: 'Customer Space' }

/**
 * One foreign agent row.
 * @typedef {{ id: string, box: string, label: string, online: boolean, state: string,
 *   lastHello: string, workspace: string, workspaceName: string }} ForeignAgent
 */
/**
 * One foreign box row.
 * @typedef {{ id: string, online: boolean, revoked: boolean, lastHello: string,
 *   workspace: string, workspaceName: string, agents: ForeignAgent[] }} ForeignBox
 */

const str = (v) => (typeof v === 'string' ? v : '')

/**
 * The hub's answer as the pages read it; anything malformed is left out.
 * @param {unknown} body
 * @returns {{ boxes: ForeignBox[], alsoSeated: Record<string, { workspace: string, workspaceName: string }[]> }}
 */
export function normalizeFleetRoster(body) {
  const b = body && typeof body === 'object' ? /** @type {Record<string, unknown>} */ (body) : {}
  const boxes = (Array.isArray(b.boxes) ? b.boxes : []).filter((x) => x && str(x.box_id) && str(x.workspace)).map((x) => {
    const ws = str(x.workspace)
    const wsName = str(x.workspace_name) || ws
    const presence = x.agent_presence && typeof x.agent_presence === 'object' ? x.agent_presence : {}
    const lastHello = str(x.last_hello_at)
    const agents = (Array.isArray(x.agents) ? x.agents : []).filter((a) => str(a)).map((id) => {
      const state = str(presence[id] && presence[id].state) || (x.online ? 'online' : 'offline')
      return { id, box: x.box_id, label: id + '@' + x.box_id, online: state === 'online', state, lastHello, workspace: ws, workspaceName: wsName }
    })
    return { id: x.box_id, online: x.online === true, revoked: x.revoked === true, lastHello, workspace: ws, workspaceName: wsName, agents }
  })
  const alsoSeated = {}
  const seats = b.also_seated && typeof b.also_seated === 'object' ? b.also_seated : {}
  for (const [box, list] of Object.entries(seats)) {
    if (!Array.isArray(list)) continue
    const rows = list.filter((s) => s && str(s.workspace)).map((s) => ({ workspace: s.workspace, workspaceName: str(s.workspace_name) || s.workspace }))
    if (rows.length) alsoSeated[box] = rows
  }
  return { boxes, alsoSeated }
}

/**
 * Rows grouped by workspace, in the order the hub sent them (by workspace id).
 * @template {{ workspace: string, workspaceName: string }} T
 * @param {T[]} rows
 * @returns {{ workspace: string, name: string, rows: T[] }[]}
 */
export function byWorkspace(rows) {
  const out = []
  const at = new Map()
  for (const r of rows) {
    let g = at.get(r.workspace)
    if (!g) {
      g = { workspace: r.workspace, name: r.workspaceName, rows: [] }
      at.set(r.workspace, g)
      out.push(g)
    }
    g.rows.push(r)
  }
  return out
}

/** Every foreign box's agents, one row each. @param {ForeignBox[]} boxes */
export function foreignAgents(boxes) {
  return boxes.flatMap((b) => b.agents)
}

/**
 * The foreign agent `label` (id@box) of workspace `ws`, or null.
 * @param {ForeignBox[]} boxes @param {string} label @param {string} ws
 */
export function foreignAgent(boxes, label, ws) {
  return foreignAgents(boxes).find((a) => a.label === label && a.workspace === ws) || null
}

/**
 * The Boxes filter on a foreign box: its id or its workspace's name or id.
 * @param {ForeignBox[]} boxes @param {string} q
 */
export function filterForeignBoxes(boxes, q) {
  const s = String(q || '').trim().toLowerCase()
  if (!s) return boxes
  return boxes.filter((b) => [b.id, b.workspaceName, b.workspace].some((v) => v.toLowerCase().includes(s)))
}

/** The card link of a foreign agent: its label and its workspace in ?ws=. @param {ForeignAgent} a */
export function foreignAgentLink(a) {
  return { path: '/monitoring/agents/' + encodeURIComponent(a.label), query: { ws: a.workspace } }
}

/**
 * The mock hub's answer: one customer-only box whose agent shares an id with
 * box-a's (two rows), and box-a also seated in the customer workspace.
 */
function mockFleetRosterBody() {
  const { id, name } = MOCK_FLEET_WORKSPACE
  return {
    boxes: [{
      workspace: id, workspace_name: name, box_id: 'mac-01', revoked: false, last_hello_at: '2026-09-20T10:00:00Z', online: true,
      agents: ['CLE-07'], agent_presence: { 'CLE-07': { state: 'online', last_seen: '2026-09-20T10:00:00Z' } },
    }],
    also_seated: { 'box-a': [{ workspace: id, workspace_name: name }] },
  }
}

/** Mock GET: 403 operator.workspaces unless the e2e opted into the operator. */
export function mockFleetRoster(store) {
  if (!mockFleetOperator(store)) {
    const err = new Error('only an admin of the operator workspace reads the fleet roster')
    Object.assign(err, { status: 403, token: 'forbidden', detail: err.message, permission: 'operator.workspaces' })
    throw err
  }
  return mockFleetRosterBody()
}
