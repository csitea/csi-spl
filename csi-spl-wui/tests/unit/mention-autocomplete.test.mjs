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

  it('@ finds a person by the display name they chose, and still by id', () => {
    const peers = [
      { id: 'HUM-9', box: 'box-wui', label: 'HUM-9@box-wui' },
      { id: 'HUM-11', box: 'box-wui', label: 'HUM-11@box-wui' },
      { id: 'CLE-120', box: 'box-desk', label: 'CLE-120@box-desk' },
    ]
    const names = { 'HUM-9': 'Yordan Georgiev', 'HUM-11': 'Велико Великов' }
    assert.deepEqual(filterRosterMentions(peers, 'geor', names).map((p) => p.id), ['HUM-9'])
    assert.deepEqual(filterRosterMentions(peers, 'YORDAN', names).map((p) => p.id), ['HUM-9'])
    assert.deepEqual(filterRosterMentions(peers, 'вели', names).map((p) => p.id), ['HUM-11'])
    assert.deepEqual(filterRosterMentions(peers, '120', names).map((p) => p.id), ['CLE-120'])
    // CONTROL: without names, a name does not match
    assert.deepEqual(filterRosterMentions(peers, 'geor'), [])
  })

  it('the @token at the caret may be a name in any script; the tag inserted is the id', () => {
    assert.equal(activeMentionQuery('hi @yor', 7), 'yor')
    assert.equal(activeMentionQuery('@Вели', 5), 'Вели')
    assert.equal(insertMention('hi @yor', 7, 'HUM-9@box-wui').text, 'hi @HUM-9@box-wui ')
    assert.equal(insertMention('@Вели', 5, 'HUM-11@box-wui').text, '@HUM-11@box-wui ')
    const c = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageComposer.vue'), 'utf8')
    assert.match(c, /filterRosterMentions\(roster\.peers, mentionQuery\.value, people\.names\.value\)/)
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
    assert.equal(src.includes('list.scrollTop'), true)
    assert.equal(src.includes('peer.label || peer.id'), true)
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

  it('3994 matches CLE-3994 anywhere in the tag', () => {
    const peers = [
      { id: 'CLE-3994', box: 'box-desk', label: 'CLE-3994@box-desk' },
      { id: 'CLE-3444', box: 'box-desk', label: 'CLE-3444@box-desk' },
      { id: 'GRK-3492', box: 'box-desk', label: 'GRK-3492@box-desk' },
    ]
    assert.deepEqual(filterRosterMentions(peers, '3994').map((p) => p.id), ['CLE-3994'])
    assert.deepEqual(filterRosterMentions(peers, '@3994').map((p) => p.id), ['CLE-3994'])
    assert.deepEqual(filterRosterMentions(peers, 'desk').map((p) => p.id), ['CLE-3994', 'CLE-3444', 'GRK-3492'])
    const typed = '@3994'
    const done = insertMention(typed, typed.length, filterRosterMentions(peers, '3994')[0].label)
    assert.equal(done.text, '@CLE-3994@box-desk ')
    assert.deepEqual(parseMention(done.text + 'please'), { to: 'CLE-3994', kind: 'task', body: 'please' })
  })
})
