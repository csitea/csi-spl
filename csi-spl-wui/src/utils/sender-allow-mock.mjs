/**
 * The mock hub's per-agent sender allow-lists (SPL-1018, NUXT_PUBLIC_USE_MOCK=1).
 * Its own module so a live bundle never loads it. Shapes match the hub:
 * GET {tenant_id, lists}, PUT answers the list, DELETE answers nothing (204).
 */

function mockErr(status, token) {
  const e = new Error(`spool ${status} ${token}`)
  e.status = status
  e.token = token
  return e
}

const AGENT = /^[A-Za-z]{1,4}-[0-9]+(@[a-z0-9][a-z0-9-]{0,31})?$/

/** A fresh mock store of lists; `now` is a seam for the unit test. */
export function createMockSenderAllow({ now = () => new Date().toISOString() } = {}) {
  const lists = new Map()
  const agentOf = (raw) => {
    const id = String(raw || '').split('@')[0]
    if (!AGENT.test(String(raw || '')) || /^(HUM|GST)-/.test(id)) throw mockErr(400, 'bad_agent')
    return /^[ACGMQ]-[0-9]{3}$/.test(id) ? id.toLowerCase() : id
  }
  return {
    list() {
      return { tenant_id: 'mock', lists: [...lists.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([agent, l]) => ({ agent, ...l })) }
    },
    put(raw, members) {
      const agent = agentOf(raw)
      if (!Array.isArray(members) || members.some((h) => !/^HUM-[0-9]+$/.test(String(h)))) throw mockErr(400, 'bad_members')
      const l = { members: [...new Set(members)].sort(), updated_by: 'HUM-1', updated_at: now() }
      lists.set(agent, l)
      return { agent, ...l }
    },
    drop(raw) {
      lists.delete(agentOf(raw))
      return null
    },
  }
}
