/**
 * The mock hub's Tenant settings (NUXT_PUBLIC_USE_MOCK=1, specs/046). Its own
 * module so spool-client loads it only in a mock build (dynamic import): the
 * initial chunk stays inside the 027 budget.
 */
import { issuePrefixOf, validResponderId } from './tenant-settings.mjs'


function mockErr(status, token) {
  const e = new Error(`spool ${status} ${token}`)
  e.status = status
  e.token = token
  return e
}

export function createMockTenant() {
  const cfg = { display_name: 'Mock tenant', default_locale: '', responders: ['CLE-01'], issue_prefix: 'SPL' }
  const channels = [
    { channel: 'lobby', name: 'lobby', visibility: 'default', members: 0, agents: 2, messages: 40, no_fallback: false, archivable: false },
    { channel: 'alerts', name: 'alerts', visibility: 'default', members: 0, agents: 1, messages: 3, no_fallback: false, archivable: false },
    { channel: 'design', name: 'Design', visibility: 'members', members: 3, agents: 1, messages: 12, no_fallback: false, archivable: true, created_by: 'HUM-3' },
    { channel: 'secret', name: 'Secret', visibility: 'members', members: 1, agents: 0, messages: 2, no_fallback: true, archivable: true, created_by: 'HUM-12' },
  ]
  const settings = () => ({ tenant_id: 'mock', ...cfg, responders: cfg.responders.slice(), max_responders: 20 })
  return {
    settings,
    patch(p) {
      if (p.display_name !== undefined) {
        const n = String(p.display_name).trim()
        if (n.length > 200 || /[\r\n]/.test(n)) throw mockErr(400, 'bad_setting')
        cfg.display_name = n
      }
      if (p.default_locale !== undefined) cfg.default_locale = String(p.default_locale)
      if (p.issue_prefix !== undefined) {
        const v = issuePrefixOf(p.issue_prefix)
        if (!v) throw mockErr(400, 'bad_setting')
        cfg.issue_prefix = v
      }
      if (p.responders !== undefined) {
        if (!p.responders.every(validResponderId)) throw mockErr(400, 'bad_responder')
        cfg.responders = [...new Set(p.responders)]
      }
      return settings()
    },
    channels: () => ({ tenant_id: 'mock', channels: channels.map((c) => ({ ...c })) }),
    setNoFallback(id, off) {
      const c = channels.find((x) => x.channel === id)
      if (!c) throw mockErr(404, 'unknown_channel')
      c.no_fallback = Boolean(off)
      return { channel: id, no_fallback: c.no_fallback }
    },
    archive(id) {
      const i = channels.findIndex((x) => x.channel === id)
      if (i < 0) throw mockErr(404, 'unknown_channel')
      if (!channels[i].archivable) throw mockErr(409, 'channel_public')
      channels.splice(i, 1)
      return null
    },
  }
}
