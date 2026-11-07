// useCardMessageActions' rules, run for real (r52-02): only a source reader held
// onMerge, and nothing ran remove or onMakeIssue, so nothing held which merge
// goes out, what a refused delete leaves, or what a refused issue shows. The vue
// and failure-key code is real; what reaches the hub or a router is stubbed.
//
// Run: node --test tests/unit/card-message-actions.test.mjs
import { after, before, beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { ref } from 'vue'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'

const ROW = { msg_id: 'row-1', task_id: 'task-1', body: 'a reply' }
const OTHER = { msg_id: 'row-2', task_id: 'task-1', body: 'the one before' }
const MERGED = { msg_id: 'row-2', task_id: 'task-1', body: 'the one before\n\na reply' }

let mod
let real
let makeBlockerIssue
let pushes

/** One card: its arguments, and what the handlers did to them. */
function card(props, msgEdit = {}) {
  const emitted = []
  const merges = []
  const closed = []
  const busy = { removing: ref(false), editError: ref('') }
  const actions = mod.useCardMessageActions(
    { msg: ROW, ...props },
    (name, msg) => emitted.push([name, msg]),
    busy,
    ref(false),
    { close: () => closed.push('menu') },
    {
      canEdit: () => true,
      removeMessage: async () => {},
      mergeInto: async (drop, keep) => { merges.push([drop, keep]); return MERGED },
      ...msgEdit,
    },
  )
  return { actions, busy, emitted, merges, closed }
}

before(async () => {
  real = { useRouter: globalThis.useRouter, useLocalePath: globalThis.useLocalePath }
  /* Nuxt auto-imports: the composable names them without an import */
  globalThis.useRouter = () => ({ push: async (to) => { pushes.push(to) } })
  globalThis.useLocalePath = () => (to) => to
  mod = await importTsStubbed('src/composables/useCardTopicActions.ts', {
    '~/composables/useArchiveUndo': { useArchiveUndo: () => ({}) },
    '~/composables/useSpoolApi': { useSpoolApi: () => ({ makeBlockerIssue: (id) => makeBlockerIssue(id) }) },
    '~/composables/errorJournal.mjs': { noteError: () => {} },
  })
})

after(() => {
  for (const [name, value] of Object.entries(real)) {
    if (value === undefined) delete globalThis[name]
    else globalThis[name] = value
  }
})

beforeEach(() => {
  pushes = []
  makeBlockerIssue = async () => ({ issue: { key: 'SPL-1' } })
})

describe('useCardMessageActions: (M) a merge', () => {
  it('into a row of the same id sends nothing', async () => {
    const { actions, busy, merges, closed } = card({ mergePrev: { ...OTHER, msg_id: ROW.msg_id } })
    await actions.onMerge('previous')
    assert.deepEqual(merges, [])
    assert.deepEqual(closed, [])
    assert.equal(busy.removing.value, false)
  })
  it('into another row sends mergeInto(drop, keep) once, and the card reports both rows', async () => {
    const { actions, merges, emitted } = card({ mergeNext: OTHER })
    await actions.onMerge('next')
    assert.deepEqual(merges, [[ROW.msg_id, OTHER.msg_id]])
    assert.deepEqual(emitted, [['edited', MERGED], ['deleted', ROW]])
  })
})

describe('useCardMessageActions: (R) a refused delete', () => {
  it('leaves removing false and the failure key in editError', async () => {
    const { actions, busy, emitted } = card({}, {
      removeMessage: async () => { throw Object.assign(new Error('refused'), { token: 'not_allowed' }) },
    })
    await actions.remove()
    assert.equal(busy.removing.value, false)
    assert.equal(busy.editError.value, 'feed.edit.failed_not_author')
    assert.deepEqual(emitted, [])
  })
})

describe('useCardMessageActions: (I) a refused Make an issue', () => {
  it('sets aiError to its key and opens nothing', async () => {
    makeBlockerIssue = async () => { throw new Error('refused') }
    const { actions, closed } = card({})
    await actions.onMakeIssue()
    assert.equal(actions.aiError.value, 'feed.msg_menu.make_issue_failed')
    assert.deepEqual(closed, ['menu'])
    assert.deepEqual(pushes, [])
  })
})
