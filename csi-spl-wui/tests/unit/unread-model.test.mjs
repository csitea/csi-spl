// Spec 079 (topic 3a74320e): one unread model, shown on the row. The rows,
// the section sums and the tab title come from one pure function, so they
// can never disagree (owner 92c4b3e8, da315c54).
//
// Run: node tests/unit/unread-model.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { unreadModel } from '../../src/utils/unread-model.mjs'

// AC1's fixed input: 2 unread in t:A, 1 in dm:B, 3 in muted ch:C.
const KEYS = { 't:A': 2, 'dm:B': 1, 'ch:C': 3 }
const LOCAL = {
  cursors: { 't:A': { ts: '2026-10-04T10:00:00Z', id: '', count: 3 } },
  channelUnread: { 'ch:C': 3 },
  dmUnread: { 'dm:B': 1 },
  topics: [{ task_id: 'A', total: 5 }],
}
const MUTED = ['C']

describe('unreadModel AC1: rows, sections, title', () => {
  const m = unreadModel({ keys: KEYS, muted: MUTED })

  it('each place carries its own number, muted included', () => {
    assert.equal(m.rows.get('t:A'), 2)
    assert.equal(m.rows.get('dm:B'), 1)
    assert.equal(m.rows.get('ch:C'), 3)
  })

  it('the title is the row sum without the muted channel', () => {
    assert.equal(m.title, 3)
  })

  it('section sums are the rows of that section, muted shown', () => {
    assert.deepEqual(m.sections, { channels: 3, dms: 1, topics: 2 })
  })

  it('unmuted, the title is every row', () => {
    assert.equal(unreadModel({ keys: KEYS }).title, 6)
  })
})

describe('unreadModel AC2: hub keys and local cursors agree', () => {
  it('the same state as keys and as local inputs yields the same map', () => {
    const hub = unreadModel({ keys: KEYS, muted: MUTED })
    const local = unreadModel({ ...LOCAL, muted: MUTED })
    assert.deepEqual([...local.rows].sort(), [...hub.rows].sort())
    assert.deepEqual(local.sections, hub.sections)
    assert.equal(local.title, hub.title)
  })

  it('topic messages counted against the cursor give the same t: value', () => {
    const cursors = { 't:A': { ts: '2026-10-04T10:00:00Z', id: '' } }
    const messages = [
      { msg_id: 'm1', ts: '2026-10-04T09:00:00Z', from: 'c-002' },
      { msg_id: 'm2', ts: '2026-10-04T11:00:00Z', from: 'c-002' },
      { msg_id: 'm3', ts: '2026-10-04T12:00:00Z', from: 'c-002' },
      { msg_id: 'm4', ts: '2026-10-04T12:30:00Z', from: 'HUM-10' },
    ]
    const m = unreadModel({ cursors, topics: [{ task_id: 'A', messages }], self: 'HUM-10' })
    assert.equal(m.rows.get('t:A'), 2)
  })
})

describe('unreadModel: hub keys win (spec Q3)', () => {
  it('a key the hub sent overrides the local count, a local-only place reads 0', () => {
    const m = unreadModel({ ...LOCAL, keys: { 't:A': 4 } })
    assert.equal(m.rows.get('t:A'), 4)
    assert.equal(m.rows.has('dm:B'), false)
    assert.equal(m.title, 4)
  })

  it('a topic never opened shows no unread (plain total)', () => {
    const m = unreadModel({ topics: [{ task_id: 'Z', total: 9 }] })
    assert.equal(m.rows.size, 0)
    assert.equal(m.title, 0)
  })
})

describe('unreadModel: defensive input', () => {
  it('no input -> empty model', () => {
    const m = unreadModel()
    assert.equal(m.rows.size, 0)
    assert.deepEqual(m.sections, { channels: 0, dms: 0, topics: 0 })
    assert.equal(m.title, 0)
  })

  it('zero, negative and junk counts are left out of rows', () => {
    const m = unreadModel({ keys: { 'ch:a': 0, 'ch:b': -2, 'dm:c': 'x', 't:d': 1.9 } })
    assert.deepEqual([...m.rows], [['t:d', 1]])
  })
})

// AC3 (FR-002): useUnread() is the only reader of the unread inputs. No
// component, page, layout or other composable imports flow-keys.mjs, reads
// tab-title.mjs's unreadTotal, or reads the channel store's unreadFor; the
// stores themselves and src/utils (the model's own inputs) are not scanned.
const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const SCANNED = ['src/components', 'src/pages', 'src/layouts', 'src/composables', 'src/app.vue']
const ALLOWED = new Set(['src/composables/useUnread.ts'])
const RULES = {
  'flow-keys': /flow-keys\.mjs/,
  unreadTotal: /\bunreadTotal\b/,
  unreadFor: /\.unreadFor\b/,
}
// Today's direct callers, each removed by the task that rewires it (tasks.md
// T004..T006). An entry that no longer matches fails too: delete it with the fix.
const TODO = [
  { file: 'src/components/ChannelSidebar.vue', rule: 'flow-keys', task: 'T004/T005' },
  { file: 'src/components/MessageFeed.vue', rule: 'unreadFor', task: 'T006' },
]

function filesUnder(rel) {
  const abs = join(WUI, rel)
  if (!statSync(abs, { throwIfNoEntry: false })) return []
  if (!statSync(abs).isDirectory()) return [rel]
  return readdirSync(abs, { recursive: true })
    .map((f) => join(rel, String(f)))
    .filter((f) => /\.(vue|ts|mjs|js)$/.test(f))
}

function directReads() {
  const hits = []
  for (const file of SCANNED.flatMap(filesUnder)) {
    if (ALLOWED.has(file)) continue
    const src = readFileSync(join(WUI, file), 'utf8')
    for (const [rule, re] of Object.entries(RULES)) if (re.test(src)) hits.push(`${file} ${rule}`)
  }
  return hits.sort()
}

describe('unread gate AC3: only useUnread reads the unread inputs', () => {
  const hits = directReads()
  const todo = new Set(TODO.map((t) => `${t.file} ${t.rule}`))

  it('scans real files (an empty scan is no proof)', () => {
    assert.ok(SCANNED.flatMap(filesUnder).length > 50)
  })

  it('no direct reader outside useUnread and the todo list', () => {
    assert.deepEqual(hits.filter((h) => !todo.has(h)), [], 'read it from useUnread() instead')
  })

  it('every todo entry is still a direct reader (remove it with its fix)', () => {
    assert.deepEqual([...todo].filter((t) => !hits.includes(t)), [])
  })

  it('the gate sees a planted direct read', () => {
    for (const [rule, re] of Object.entries(RULES)) {
      const line = { 'flow-keys': "import { rowUnread } from '~/utils/flow-keys.mjs'", unreadTotal: 'unreadTotal(notes.unread)', unreadFor: 'channel.unreadFor(id)' }[rule]
      assert.ok(re.test(line), rule)
    }
  })

  it('useUnread itself reads the model', () => {
    const src = readFileSync(join(WUI, 'src/composables/useUnread.ts'), 'utf8')
    assert.match(src, /unread-model\.mjs/)
    assert.match(src, /export function useUnread\(/)
  })
})
