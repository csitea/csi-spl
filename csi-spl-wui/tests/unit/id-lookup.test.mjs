// HUM-10 (topic cd357c76): an id the tab has not loaded is asked from the
// hub once per body, and then links like a loaded one. Controls: an id the
// catalog already links is never asked, an id in code is never asked, and an
// id the hub does not answer stays text.
import { describe, it, afterEach } from 'node:test'
import assert from 'node:assert/strict'

import { parseBody } from '../../src/utils/code-blocks.mjs'
import { indexCatalog, linkifyText, resolveId, resetIdCatalogProvider, setIdCatalogProvider } from '../../src/utils/id-links.mjs'
import { idLinksReady, registerIdLookup } from '../../src/utils/id-link-gate.mjs'
import { bodyTokens, createIdLookup, hitRows, LOOKUP_MAX, mockLookupIds } from '../../src/utils/id-lookup.mjs'

const LOADED = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const FAR_TOPIC = 'abababab-abab-4bab-8bab-abababababab'
const FAR_REPLY = '44444444-4444-4444-8444-444444444444'
const FAR_PARENT = 'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd'
const DM_TOPIC = '99999999-9999-4999-8999-999999999999'
const GONE = '12121212-1212-4212-8212-121212121212'
const UNKNOWN = '00000000-0000-4000-8000-000000000099'

const loadedRow = { msg_id: '55555555-5555-4555-8555-555555555555', task_id: LOADED, channel: 'lobby', from: 'HUM-1', to: '@channel' }

const HUB = {
  [FAR_TOPIC]: { kind: 'topic', task_id: FAR_TOPIC, channel: 'dev-ops', archived: false },
  [FAR_REPLY]: { kind: 'message', task_id: FAR_PARENT, msg_id: FAR_REPLY, channel: 'dev-ops', archived: false },
  [DM_TOPIC]: { kind: 'topic', task_id: DM_TOPIC, peer: 'c-001@box-a', archived: false },
  [GONE]: { kind: 'topic', task_id: GONE, channel: 'dev-ops', archived: true },
}

function fakeHub() {
  const calls = []
  return {
    calls,
    fetchIds: async (ids) => {
      calls.push(ids)
      return { ids: ids.filter((id) => HUB[id]).map((id) => ({ id, ...HUB[id] })) }
    },
  }
}

const tick = () => new Promise((r) => setTimeout(r, 0))

describe('bodyTokens', () => {
  it('finds uuids and 8-hex starts, lower case, once, outside code and links', () => {
    const toks = bodyTokens(`see ${FAR_TOPIC.toUpperCase()} and ${FAR_TOPIC} and abcd1234\n\`${DM_TOPIC}\`\n[x](https://h/${GONE}) https://h/${UNKNOWN}`)
    assert.deepEqual(toks, [FAR_TOPIC, 'abcd1234'])
  })
  it('a body with no id has no token', () => {
    assert.deepEqual(bodyTokens('no id here'), [])
  })
})

describe('createIdLookup', () => {
  it('asks only for what the catalog cannot link, in one request for the bodies of one tick', async () => {
    const hub = fakeHub()
    const index = indexCatalog({ messages: [loadedRow] })
    let repaint = 0
    const lk = createIdLookup({ fetchIds: hub.fetchIds, resolves: (t, i) => Boolean(resolveId(t, i)), onHits: () => { repaint++ }, schedule: (fn) => setTimeout(fn, 0) })
    lk.note(`loaded ${LOADED}`, index)
    await tick()
    assert.equal(hub.calls.length, 0, 'CONTROL: every id is held, no request')
    lk.note(`dm quotes ${FAR_TOPIC} and ${FAR_REPLY}`, index)
    lk.note(`another body ${DM_TOPIC} ${UNKNOWN} ${LOADED}`, index)
    await tick()
    await tick()
    assert.deepEqual(hub.calls, [[FAR_TOPIC, FAR_REPLY, DM_TOPIC, UNKNOWN]])
    assert.equal(repaint, 1)
    lk.note(`again ${FAR_TOPIC} ${UNKNOWN}`, index)
    await tick()
    assert.equal(hub.calls.length, 1, 'a known hit and a known miss are not asked again')
    assert.equal(lk.version, 1)
  })

  it('splits more than LOOKUP_MAX ids, and a failed request is not retried', async () => {
    const ids = Array.from({ length: LOOKUP_MAX + 3 }, (_, i) => `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`)
    const calls = []
    const lk = createIdLookup({ fetchIds: async (a) => { calls.push(a.length); throw new Error('503') }, resolves: () => false, onHits: () => assert.fail('no hits'), schedule: (fn) => fn() })
    lk.note(ids.join(' '), null)
    await tick()
    assert.deepEqual(calls, [LOOKUP_MAX, 3])
    lk.note(ids.join(' '), null)
    await tick()
    assert.equal(calls.length, 2)
  })
})

describe('hub answers link like loaded rows', () => {
  const rows = hitRows(Object.entries(HUB).map(([id, h]) => ({ id, ...h })), 'HUM-1')
  const index = indexCatalog({ topics: rows.topics, messages: [loadedRow, ...rows.messages], self: 'HUM-1', labels: { topic: 'Topic', 'channel-message': 'Message', 'direct-message': 'Direct message', archived: 'archived' } })
  const link = (id) => linkifyText(`x ${id}`, index).find((p) => p.type === 'link')
  const prefix = (id) => linkifyText(`x ${id}`, index)[0].text

  it('a topic of a channel the tab never opened: that channel, card selected', () => {
    assert.equal(link(FAR_TOPIC).href, `/channel/dev-ops?topic=${FAR_TOPIC}`)
    assert.equal(prefix(FAR_TOPIC), 'x Topic: ')
  })
  it('a reply: its channel, its topic open, the reply as the hash', () => {
    assert.equal(link(FAR_REPLY).href, `/channel/dev-ops?topic=${FAR_PARENT}#${FAR_REPLY}`)
    assert.equal(prefix(FAR_REPLY), 'x Message: ')
  })
  it('a DM topic: that conversation', () => {
    assert.equal(link(DM_TOPIC).href, `/dm/${encodeURIComponent('c-001@box-a')}?topic=${DM_TOPIC}`)
    assert.equal(prefix(DM_TOPIC), 'x Direct message: ')
  })
  it('an archived topic: /m/<task> (never the Topics view), marked archived', () => {
    assert.equal(link(GONE).href, `/m/${GONE}`)
    assert.equal(prefix(GONE), 'x Topic (archived): ')
  })
  it('CONTROL: an id the hub did not answer stays text', () => {
    assert.equal(link(UNKNOWN), undefined)
  })
})

describe('the render path', () => {
  afterEach(() => {
    registerIdLookup(null)
    resetIdCatalogProvider()
  })

  it('a DM body quoting an unloaded topic links after one hub answer', async () => {
    // The plugin's wiring (id-catalog-install.ts), without the stores.
    const hub = fakeHub()
    const lk = createIdLookup({ fetchIds: hub.fetchIds, resolves: (t, i) => Boolean(resolveId(t, i)), onHits: () => idLinksReady(), schedule: (fn) => setTimeout(fn, 0) })
    registerIdLookup((src, index) => lk.note(src, index))
    setIdCatalogProvider(() => {
      const asked = lk.rows('HUM-1')
      return indexCatalog({ topics: asked.topics, messages: [loadedRow, ...asked.messages], self: 'HUM-1' })
    })
    const body = `look at ${FAR_TOPIC}`
    const first = JSON.stringify(parseBody(body))
    assert.ok(!first.includes('"link"'), 'before the answer the id is text')
    await tick()
    await tick()
    assert.equal(hub.calls.length, 1)
    const after = parseBody(body)
    const links = after.flatMap((b) => b.parts || []).filter((p) => p.type === 'link')
    assert.deepEqual(links.map((p) => p.href), [`/channel/dev-ops?topic=${FAR_TOPIC}`])
    await tick()
    assert.equal(hub.calls.length, 1, 'the repaint asks nothing')
  })
})

describe('mockLookupIds', () => {
  it('answers as the hub: topic over message, a reply under its parent, short starts, archived', () => {
    const rows = [
      { msg_id: FAR_REPLY, task_id: '31313131-3131-4131-8131-313131313131', parent_task_id: FAR_PARENT, channel: 'dev-ops', from: 'HUM-2', to: '@channel' },
      { msg_id: '61616161-6161-4161-8161-616161616161', task_id: DM_TOPIC, channel: null, from: 'HUM-1', to: 'c-001', to_box: 'box-a' },
      { msg_id: GONE, task_id: GONE, channel: 'dev-ops', from: 'HUM-1', to: '@channel' },
    ]
    const out = mockLookupIds(rows, [rows[2]], [FAR_REPLY, DM_TOPIC.slice(0, 8), GONE, UNKNOWN], 'HUM-1').ids
    assert.deepEqual(out.map((h) => [h.id, h.kind, h.task_id, h.channel, h.peer, h.archived]), [
      [FAR_REPLY, 'message', FAR_PARENT, 'dev-ops', undefined, false],
      [DM_TOPIC.slice(0, 8), 'topic', DM_TOPIC, undefined, 'c-001@box-a', false],
      [GONE, 'topic', GONE, 'dev-ops', undefined, true],
    ])
  })
})
