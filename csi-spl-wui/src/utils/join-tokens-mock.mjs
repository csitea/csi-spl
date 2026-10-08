/**
 * The mock hub's agent join tokens (spec 073 4.3, NUXT_PUBLIC_USE_MOCK=1).
 * Its own module so a live bundle never loads it. Shapes match the hub:
 * mint answers the token once, list never carries one.
 */

function mockErr(status, token, detail = '') {
  const e = new Error(`spool ${status} ${token}`)
  e.status = status
  e.token = token
  e.detail = detail
  return e
}

const BOX_ID = /^[a-z0-9][a-z0-9-]{0,31}$/

/** A fresh mock store of join tokens; `now` and `ttlMs` are seams for the unit test. */
export function createMockJoinTokens({ now = () => Date.now(), ttlMs = 60 * 60 * 1000 } = {}) {
  const rows = []
  let n = 0
  const hex8 = () => (0x1a2b3c00 + (++n)).toString(16).slice(-8)
  return {
    mint({ label = '', box_id: boxId = '', for_human: forHuman = '' } = {}) {
      if (String(label).length > 80) throw mockErr(400, 'bad_request', 'label is longer than 80 characters')
      if (boxId === 'box-wui') throw mockErr(400, 'reserved_box', 'box-wui is the reserved browser box')
      if (boxId && !BOX_ID.test(boxId)) throw mockErr(400, 'bad_request', 'box_id is not a box id ([a-z0-9-], up to 32)')
      if (forHuman && !/^HUM-[0-9]+$/.test(forHuman)) {
        throw mockErr(400, 'join_token_member', 'for_human is not a current member; pick a current member in Tenant settings -> Members')
      }
      const id = hex8()
      const token = `spj1.mock.mock-secret-${id}`
      const expiresAt = new Date(now() + ttlMs).toISOString()
      rows.push({ id, label: String(label), box_id: boxId, for_human: forHuman, created_by: 'HUM-1', created_at: new Date(now()).toISOString(), expires_at: expiresAt, state: 'open' })
      return { id, token, expires_at: expiresAt, box_id: boxId, for_human: forHuman, join_line: `SPOOL_JOIN_TOKEN=${token} spool join http://mock.invalid` }
    },
    list() {
      return { tokens: rows.filter((r) => Date.parse(r.expires_at) > now()).map((r) => ({ ...r })) }
    },
    revoke(id) {
      const r = rows.find((x) => x.id === id)
      if (!r) throw mockErr(404, 'not_found', 'no such join token')
      if (r.state === 'used') throw mockErr(409, 'join_token_used', 'this token already seated a box')
      r.state = 'revoked'
      return { id, state: 'revoked' }
    },
    revokeSeat(box) {
      if (box === 'box-wui') throw mockErr(400, 'reserved_box', 'box-wui is the reserved browser box')
      return { box_id: box, revoked: 'true' }
    },
  }
}
