// useCardTopicActions' archive rules, run for real (r57-04): no test called
// useCardTopicActions, so nothing held what a second archive, a done archive or
// a refused one does to the card. The vue and error-key code is real; what
// reaches the hub and the Undo offer is stubbed.
//
// Run: node --test tests/unit/card-topic-actions.test.mjs
import { before, beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { ref } from 'vue'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'

const OPENER = { msg_id: 'open-1', task_id: 'task-1', body: 'the topic' }
const ROW = { msg_id: 'row-1', task_id: 'task-1', body: 'a reply' }

let mod
let archiveTopic
let archived
let undos

/** One card: its arguments, and what the handlers did to them. */
function card() {
  const emitted = []
  const dropped = []
  const busy = { removing: ref(false), editError: ref('') }
  const actions = mod.useCardTopicActions(
    { props: { msg: ROW, paneOpener: OPENER }, emit: (name, msg) => emitted.push([name, msg]), rowEl: ref(null) },
    busy,
    { close: () => {} },
    { dropEverywhere: (id) => dropped.push(id) },
  )
  return { actions, busy, emitted, dropped }
}

before(async () => {
  mod = await importTsStubbed('src/composables/useCardTopicActions.ts', {
    '~/composables/useArchiveUndo': { useArchiveUndo: () => ({ offerUndo: (id, pane) => undos.push([id, pane]) }) },
    '~/composables/useSpoolApi': { useSpoolApi: () => ({ archiveTopic: (id, on) => archiveTopic(id, on) }) },
    '~/composables/errorJournal.mjs': { noteError: () => {} },
  })
})

beforeEach(() => {
  archived = []
  undos = []
  archiveTopic = async (id, on) => { archived.push([id, on]) }
})

describe('useCardTopicActions: (R) a second archive while one runs', () => {
  it('does nothing: one hub call, and the second answers false', async () => {
    const held = []
    archiveTopic = (id, on) => { archived.push([id, on]); return new Promise((r) => { held.push(r) }) }
    const { actions } = card()
    const first = actions.onMenuArchive()
    await new Promise((r) => setImmediate(r))
    const second = actions.onMenuArchive()
    await new Promise((r) => setImmediate(r))
    for (const release of held) release()
    assert.equal(await second, false)
    assert.equal(await first, true)
    assert.deepEqual(archived, [[OPENER.msg_id, true]])
  })
})

describe('useCardTopicActions: (D) an archived topic', () => {
  it('leaves every feed, the card reports itself, and Undo is offered', async () => {
    const { actions, emitted, dropped } = card()
    assert.equal(await actions.onMenuArchive(), true)
    assert.deepEqual(archived, [[OPENER.msg_id, true]])
    assert.deepEqual(dropped, [OPENER.msg_id])
    assert.deepEqual(emitted, [['deleted', ROW]])
    assert.deepEqual(undos, [[OPENER.msg_id, '']])
  })
})

describe('useCardTopicActions: (E) a failed archive', () => {
  it('shows its error key, clears removing, and drops nothing', async () => {
    archiveTopic = async () => { throw Object.assign(new Error('refused'), { token: 'not_allowed' }) }
    const { actions, busy, emitted, dropped } = card()
    assert.equal(await actions.onMenuArchive(), false)
    assert.equal(busy.editError.value, 'archive.error_forbidden')
    assert.equal(busy.removing.value, false)
    assert.deepEqual(dropped, [])
    assert.deepEqual(emitted, [])
  })
})
