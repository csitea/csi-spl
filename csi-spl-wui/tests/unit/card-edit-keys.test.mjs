// useEditKeys' rules, run for real (r53-04): no test named it, so nothing held
// that Esc closes the editor, that a second Enter cannot send twice, or that
// another key commits nothing. The vue and msg-edit code is real; the @ picker
// and the poke are stubbed, and the hub's commit is a promise the test settles.
//
// Run: node --test tests/unit/card-edit-keys.test.mjs
import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { ref } from 'vue'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'

const RETURNED = ['cancel', 'closeEdit', 'draft', 'edit', 'editHintId', 'editMp', 'editing', 'emptyAsk', 'onEditKey', 'save', 'saving', 'startEdit']

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

/** A card with its editor open on `old body`, and the commits the hub received. */
function openCard() {
  const commits = []
  const msgEdit = {
    canEdit: () => true,
    commit: (msgId, body) => new Promise((resolve) => { commits.push({ msgId, body, resolve }) }),
  }
  const msg = { msg_id: 'm1', body: 'old body' }
  const editError = ref('')
  const card = mod.useCardEdit({ msg }, () => {}, ref(null), ref(null), editError, msgEdit)
  card.startEdit()
  return { card, commits, editError }
}

function key(card, name) {
  const ev = { key: name, prevented: 0, stopped: 0, preventDefault() { this.prevented += 1 }, stopPropagation() { this.stopped += 1 } }
  card.onEditKey(ev)
  return ev
}

describe('useEditKeys: what the edit box keys do', () => {
  it('(E) Esc closes the editor and clears the error', () => {
    const { card, commits, editError } = openCard()
    assert.equal(card.editing.value, true)
    editError.value = 'a refusal'

    const ev = key(card, 'Escape')
    assert.equal(ev.prevented, 1)
    assert.equal(ev.stopped, 1)
    assert.equal(card.editing.value, false)
    assert.equal(editError.value, '')
    assert.equal(commits.length, 0)
  })

  it('(S) Enter while saving is swallowed and sends no second commit', () => {
    const { card, commits } = openCard()
    card.draft.value = 'new body'
    assert.equal(key(card, 'Enter').prevented, 1)
    assert.equal(card.saving.value, true)
    assert.equal(commits.length, 1)

    const again = key(card, 'Enter')
    assert.equal(again.prevented, 1)
    assert.equal(commits.length, 1)
    assert.equal(commits[0].body, 'new body')
  })

  it('(O) another key commits nothing and leaves the editor open', () => {
    const { card, commits } = openCard()
    card.draft.value = 'new body'

    const ev = key(card, 'a')
    assert.equal(ev.prevented, 0)
    assert.equal(commits.length, 0)
    assert.equal(card.saving.value, false)
    assert.equal(card.editing.value, true)
  })

  it('(R) the card gets exactly these keys, none of the inputs of useEditKeys', () => {
    const { card } = openCard()
    assert.deepEqual(Object.keys(card).sort(), RETURNED)
  })
})
