// Spec 025 section 13 (SPL-5706): the client of GET /v1/view/members/invited
// and the picker's keys. An invitee whose address is shown is keyed by the
// address (the section 11 add and undo take it); a masked one by its INV- id.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { invitedMembers, inviteeKeys } from '../../src/utils/invited-members-client.mjs'

describe('invited members client', () => {
  it('the mock answers one invitee, masked in t1 like the hub', async () => {
    const shown = await invitedMembers({ mock: true, tenant: 'acme' })
    assert.equal(shown.length, 1)
    assert.equal(shown[0].label, 'invitee@example.com')
    assert.equal(shown[0].masked, false)
    assert.match(shown[0].id, /^INV-[0-9a-f]{16}$/)
    const masked = await invitedMembers({ mock: true, tenant: 't1' })
    assert.equal(masked[0].label, 'i…@example.com')
    assert.equal(masked[0].masked, true)
  })

  it('a live answer is read from the hub, a refusal throws its status and token', async () => {
    const real = globalThis.fetch
    try {
      let asked = ''
      globalThis.fetch = async (url) => {
        asked = String(url)
        return new Response(JSON.stringify({ invited: [{ id: 'INV-0123456789abcdef', label: 'a…@example.com', masked: true }, { id: '', label: 'x' }] }), { status: 200 })
      }
      const rows = await invitedMembers({ base: 'https://api.example.com/', tenant: 'w1', credentials: 'include' })
      assert.equal(asked, 'https://api.example.com/v1/view/members/invited?workspace=w1')
      assert.deepEqual(rows.map((r) => r.id), ['INV-0123456789abcdef'], 'a row with no id is dropped')
      globalThis.fetch = async () => new Response(JSON.stringify({ error: 'person_only' }), { status: 403 })
      await assert.rejects(invitedMembers({ base: 'https://api.example.com', tenant: 'w1' }), (e) => e.status === 403 && e.error === 'person_only')
    } finally {
      globalThis.fetch = real
    }
  })

  it('keys: the address when shown, the id when masked; one label per key', () => {
    const { keys, labels } = inviteeKeys([
      { id: 'INV-0000000000000001', label: 'open@example.com', masked: false },
      { id: 'INV-0000000000000002', label: 'h…@example.com', masked: true },
      { id: 'INV-0000000000000001', label: 'open@example.com', masked: false },
      { id: '', label: 'nobody@example.com', masked: false },
    ])
    assert.deepEqual(keys, ['open@example.com', 'INV-0000000000000002'])
    assert.deepEqual(labels, { 'open@example.com': 'open@example.com', 'INV-0000000000000002': 'h…@example.com' })
    assert.deepEqual(inviteeKeys(undefined), { keys: [], labels: {} })
  })
})
