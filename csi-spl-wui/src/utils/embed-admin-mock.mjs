/**
 * The mock hub's embed admin API (spec 121 T203, NUXT_PUBLIC_USE_MOCK=1).
 * Its own module so a live bundle never loads it. Shapes match the hub: a
 * new embed is disabled and keyless; the key answer is the only one that
 * carries the private key; a new key replaces the old.
 */
import { EMBED_ID_RE, EMBED_MAX_ORIGINS } from './embed-admin.mjs'

function mockErr(status, token, detail = '') {
  const e = new Error(`spool ${status} ${token}`)
  e.status = status
  e.token = token
  e.detail = detail
  return e
}

const ORIGIN_RE = /^(https:\/\/[a-z0-9.-]+(:[0-9]+)?|http:\/\/localhost(:[0-9]+)?)$/

function checkOrigins(list) {
  if (!Array.isArray(list)) return []
  if (list.length > EMBED_MAX_ORIGINS) throw mockErr(400, 'bad_origin', 'at most 32 allowed_origins')
  const out = []
  for (const raw of list) {
    const o = String(raw).trim().toLowerCase()
    if (!ORIGIN_RE.test(o)) throw mockErr(400, 'bad_origin', `${raw}: an exact https origin (http only for localhost)`)
    if (!out.includes(o)) out.push(o)
  }
  return out
}

/** A fresh mock store of embeds; `enabled` (cnf env.hub.embed.enabled) is a seam for the unit test. */
export function createMockEmbeds({ enabled = true, now = () => Date.now() } = {}) {
  const rows = []
  let n = 0
  const gate = () => { if (!enabled) throw mockErr(404, 'not_found', 'the embed is not enabled on this hub') }
  const find = (id) => {
    const r = rows.find((x) => x.embed_id === id)
    if (!r) throw mockErr(404, 'not_found', 'no such embed in this workspace')
    return r
  }
  const show = (r) => ({ ...r, allowed_origins: [...r.allowed_origins], key_alg: r.public_key ? 'ES256' : '' })
  return {
    list() {
      gate()
      return { embeds: rows.map(show) }
    },
    create({ embed_id: id = '', allowed_origins: origins = [] } = {}) {
      gate()
      if (!EMBED_ID_RE.test(String(id))) throw mockErr(400, 'bad_embed', "embed_id: 3..64 of a-z, 0-9 and '-', not starting with '-'")
      if (rows.some((x) => x.embed_id === id)) throw mockErr(409, 'embed_exists', 'that embed id is taken')
      const at = new Date(now()).toISOString()
      const r = { embed_id: id, allowed_origins: checkOrigins(origins), enabled: false, key_id: '', public_key: '', created_at: at, updated_at: at }
      rows.push(r)
      return show(r)
    },
    patch(id, { allowed_origins: origins, enabled: on } = {}) {
      gate()
      const r = find(id)
      if (origins === undefined && on === undefined) throw mockErr(400, 'bad_embed', 'allowed_origins or enabled is required')
      if (origins !== undefined) r.allowed_origins = checkOrigins(origins)
      if (on !== undefined) r.enabled = on === true
      r.updated_at = new Date(now()).toISOString()
      return show(r)
    },
    newKey(id) {
      gate()
      const r = find(id)
      const keyId = (0x5e0000 + (++n)).toString(16)
      r.key_id = keyId
      r.public_key = `mock-public-${keyId}`
      r.updated_at = new Date(now()).toISOString()
      return { ...show(r), private_key: `mock-private-${keyId}` }
    },
  }
}
