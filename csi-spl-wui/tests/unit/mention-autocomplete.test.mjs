import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { MOCK_ROSTER } from '../../src/utils/mock-data.mjs'
import { displayName, parseMention } from '../../src/utils/channel-feed.mjs'
import {
  activeMentionQuery,
  filterRosterMentions,
  insertMention,
  isAgentId,
} from '../../src/utils/mention-autocomplete.mjs'

function peersFrom(roster) {
  const rows = []
  for (const [box, agents] of Object.entries(roster)) {
    for (const id of agents) {
      rows.push({ id, box, label: displayName(id, box), online: false })
    }
  }
  return rows
}

describe('mention autocomplete', () => {
  it('@CLE-07 filters roster to CLE-07 ids', () => {
    const peers = peersFrom(MOCK_ROSTER)
    assert.ok(peers.some((p) => p.id === 'GRK-03'))
    assert.ok(peers.some((p) => p.id === 'AGY-02'))
    assert.ok(peers.some((p) => p.id === 'HUM-1'))

    for (const query of ['@CLE-07', 'CLE-07', 'cle-07']) {
      const hits = filterRosterMentions(peers, query)
      assert.ok(hits.length >= 1, query)
      assert.equal(hits.every((p) => p.id === 'CLE-07'), true, query)
      assert.equal(hits.some((p) => p.id === 'GRK-03'), false, query)
      assert.equal(hits.some((p) => p.id === 'AGY-02'), false, query)
      assert.equal(hits.some((p) => p.id === 'HUM-1'), false, query)
    }
  })

  it('empty @ query lists CLE/GRK/AGY/HUM and drops other prefixes', () => {
    const peers = [
      ...peersFrom(MOCK_ROSTER),
      { id: 'BOX-1', box: 'box-a', label: 'BOX-1@box-a', online: false },
      { id: 'not-an-id', box: 'box-a', label: 'not-an-id@box-a', online: false },
    ]
    const hits = filterRosterMentions(peers, '')
    assert.equal(hits.every((p) => isAgentId(p.id)), true)
    assert.equal(hits.some((p) => p.id === 'BOX-1'), false)
    const prefixes = new Set(hits.map((p) => p.id.split('-')[0]))
    for (const want of ['CLE', 'GRK', 'AGY', 'HUM']) {
      assert.equal(prefixes.has(want), true, want)
    }
  })

  it('activeMentionQuery reads the @token at the caret', () => {
    assert.equal(activeMentionQuery('@CLE-07', 7), 'CLE-07')
    assert.equal(activeMentionQuery('hi @CLE', 7), 'CLE')
    assert.equal(activeMentionQuery('@', 1), '')
    assert.equal(activeMentionQuery('hello', 5), null)
    assert.equal(activeMentionQuery('hi @CLE-07 review', 3), null)
    assert.equal(activeMentionQuery('a@CLE', 5), null)
  })


  it('MessageComposer reads the roster store and mention helpers', () => {
    const wui = join(dirname(fileURLToPath(import.meta.url)), '../..')
    const src = readFileSync(join(wui, 'src/components/MessageComposer.vue'), 'utf8')
    assert.equal(src.includes('useRosterStore'), true)
    assert.equal(src.includes('filterRosterMentions'), true)
    assert.equal(src.includes('activeMentionQuery'), true)
    assert.equal(src.includes('insertMention'), true)
    assert.equal(src.includes('parseMention'), false)
  })

  it('insertMention keeps parseMention task routing', () => {
    const picked = insertMention('@CLE', 4, 'CLE-07')
    assert.equal(picked.text, '@CLE-07 ')
    const routed = parseMention(picked.text + 'review patch.zip')
    assert.deepEqual(routed, { to: 'CLE-07', kind: 'task', body: 'review patch.zip' })
    const note = parseMention('hello channel')
    assert.equal(note.kind, 'note')
    assert.equal(note.to, '@channel')
  })

})

describe('H5: a door-off guest GST-<n> is mentionable', () => {
  it('keeps GST ids in the picker', () => {
    const got = filterRosterMentions([{ id: 'GST-3' }, { id: 'ALL-0' }], 'gst')
    assert.deepEqual(got.map((p) => p.id), ['GST-3'])
  })
})
