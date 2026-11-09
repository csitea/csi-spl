// useCardEdit's opening and closing rules, run for real (r55-02): no test ran
// them, so nothing executed that a message the viewer may not edit opens no
// editor, that another msg_id drops the open edit (msg-edit.test.mjs reads that
// watcher only as source text), or that closing hands focus back to the row.
// The vue and msg-edit code is real; the @ picker and the poke are stubbed.
//
// Run: node --test tests/unit/card-edit-open-close.test.mjs
import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { nextTick, reactive, ref } from 'vue'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'

let mod
let saved

before(async () => {
  saved = { useId: globalThis.useId }
  globalThis.useId = () => 'edit-hint'
  mod = await importTsStubbed('src/composables/useCardEdit.ts', {
    '~/composables/useMentionPicker': {
      useMentionPicker: () => ({ decode: (s) => s, encode: (s) => s, onKeydown: () => false }),
    },
    '~/composables/useMentionPoke': { useMentionPoke: () => ({ poke: async () => {} }) },
  })
})

after(() => {
  globalThis.useId = saved.useId
})

/** A card on message m1, and the focus calls its row received. */
function card({ canEdit = true } = {}) {
  const focused = []
  const rowEl = ref({ focus: (opts) => focused.push(opts) })
  const props = reactive({ msg: { msg_id: 'm1', body: 'old body' } })
  const msgEdit = { canEdit: () => canEdit, commit: async () => ({}) }
  const c = mod.useCardEdit({ props, emit: () => {}, rowEl, editEl: ref(null), editError: ref('') }, msgEdit)
  return { c, props, focused }
}

describe('useCardEdit: what opens and closes the editor', () => {
  it('(C) a message the viewer may not edit opens no editor', () => {
    const { c } = card({ canEdit: false })
    c.startEdit()
    assert.equal(c.editing.value, false)
  })

  it('(M) another msg_id drops the open edit', async () => {
    const { c, props, focused } = card()
    c.startEdit()
    assert.equal(c.editing.value, true)

    props.msg = { msg_id: 'm2', body: 'someone else' }
    await nextTick()
    await nextTick() // closeEdit() would focus the row one tick after the watcher ran
    assert.equal(c.editing.value, false)
    assert.equal(focused.length, 0, 'a re-rooted card must not pull the focus to its row')
  })

  it('(F) closing hands focus back to the row', async () => {
    const { c, focused } = card()
    c.startEdit()
    c.closeEdit()
    await nextTick()
    assert.equal(c.editing.value, false)
    assert.deepEqual(focused, [{ preventScroll: true }])
  })
})
