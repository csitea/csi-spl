// SPL-5431 (spec 154 section 12): member-card-client.mjs reads the hub's
// member card, the address only on a 200, and the mock answers the same shape.
import { describe, it, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { memberCard, memberCardUrl } from '../../src/utils/member-card-client.mjs'

const HUB = { base: 'http://hub.example.com/', tenant: 't1', credentials: 'include' }
const realFetch = globalThis.fetch
afterEach(() => { globalThis.fetch = realFetch })

function answers(status, body) {
  const sent = []
  globalThis.fetch = async (url, init) => {
    sent.push({ url: String(url), init })
    return new Response(JSON.stringify(body), { status })
  }
  return sent
}

describe('member card client', () => {
  it('reads the session workspace route, with the cookie', async () => {
    const sent = answers(200, { human_id: 'HUM-2', display_name: 'FirstName LastName', email: 'first.last@example.com' })
    const card = await memberCard(HUB, 'HUM-2')
    assert.deepEqual(card, { human_id: 'HUM-2', display_name: 'FirstName LastName', email: 'first.last@example.com' })
    assert.equal(sent[0].url, 'http://hub.example.com/v1/view/members/HUM-2/card?workspace=t1')
    assert.equal(sent[0].init.credentials, 'include')
    assert.equal(sent[0].init.headers.authorization, undefined)
  })
  it('null fields stay null', async () => {
    answers(200, { human_id: 'HUM-3', display_name: null, email: null })
    assert.deepEqual(await memberCard(HUB, 'HUM-3'), { human_id: 'HUM-3', display_name: null, email: null })
  })
  for (const [status, error] of [[404, 'not_found'], [403, 'person_only']]) {
    it(`a ${status} ${error} throws, with no address`, async () => {
      answers(status, { error })
      await assert.rejects(memberCard(HUB, 'HUM-9'), (e) => e.status === status && e.error === error)
    })
  }
  it('off the network is status 0', async () => {
    globalThis.fetch = async () => { throw new TypeError('offline') }
    await assert.rejects(memberCard(HUB, 'HUM-2'), (e) => e.status === 0)
  })
  it('escapes the id in the path', () => {
    assert.equal(memberCardUrl({ base: '' }, 'a/b'), '/v1/view/members/a%2Fb/card')
  })
  it('the mock answers a HUM-<n> with an example.com address, else 404', async () => {
    assert.equal((await memberCard({ mock: true }, 'HUM-2')).email, 'hum-2@example.com')
    await assert.rejects(memberCard({ mock: true }, 'CLE-07'), (e) => e.status === 404)
    assert.equal((await memberCard({ mock: true, tenant: 't1' }, 'HUM-2')).email, null, 't1 is name-only (spec 154 12.4)')
    assert.equal((await memberCard({ mock: true, tenant: 'w2' }, 'HUM-2')).email, 'hum-2@example.com')
  })
})
