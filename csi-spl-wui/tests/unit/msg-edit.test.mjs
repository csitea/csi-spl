// CLE-3445 row E1 — editing a message in place, the BROWSER half.
//
// The owner asked for this on 2026-09-22:
//
//   "once a msg in the 3rd panel is selected, if one presses the e shortcut
//    the msg becomes once again a textbox and after once writes the new msg
//    (the old msg should be shown there) and hits the enter the msg is sent"
//
// and, minutes later, the register: "both the old and the new msg should be
// stored (for later feature to be able to compare those msgs)".
//
// What is pinned here is the state machine and the gate, which is everything
// that DECIDES. The textarea itself is MessageCard.vue's and is proved in a
// real browser by tests/e2e/msg-edit-live.proof.mjs — `pnpm run typecheck`
// does not drive Chrome, which is this repo's own written lesson.
//
// Two of these assertions are deliberately about the parts most likely to be
// got wrong rather than the parts easiest to test:
//
//   * the editor opens PRE-FILLED. "The old msg should be shown there" is a
//     clause in the middle of a long sentence and is exactly what a hurried
//     implementation drops. `beginEdit` has no path that yields an empty
//     draft, and this file proves it for a body of '' too.
//   * NOTHING is cleared or replaced before the hub confirms. On 2026-09-21
//     the owner lost a message to clear-on-emit with no rollback (CLE-3433,
//     src/utils/send-failure.mjs). `commitEdit` therefore reports what should
//     be sent and never mutates; `cancelEdit` always answers the original.
//
// INFERRED vs ORDERED. The owner named Enter. Escape-cancels and author-only
// are inferences agreed by both seats (CLE-00's ruling, 2026-09-22) and the
// owner can overrule either; they are marked as such in the case names so a
// later reader can tell which line came from where.
//
// Run: node tests/unit/msg-edit.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { BROWSER_BOX } from '../../src/utils/view-api.mjs'
import {
  EDIT_KEY,
  beginEdit,
  canEditMessage,
  cancelEdit,
  commitEdit,
  editFailureKey,
  editIsDirty,
  editKeyAction,
  editWireBody,
  isEdited,
  isOwnMessage,
  revisionOf,
  wantsEdit,
  withDraft,
} from '../../src/utils/msg-edit.mjs'
import { closeOpenFence, enterAction } from '../../src/utils/code-blocks.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

const ME = { id: 'HUM-1', box: BROWSER_BOX }
const mine = (over = {}) => ({
  msg_id: '11111111-1111-4111-8111-111111111111',
  task_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  from: 'HUM-1',
  from_box: BROWSER_BOX,
  body: 'the old msg',
  ...over,
})
/** a keydown as the row's own handler sees it (target === currentTarget) */
const row = {}
const key = (k, over = {}) => ({ key: k, target: row, currentTarget: row, ...over })

describe('who may edit — author-only, no time window (INFERRED: CLE-00 2026-09-22)', () => {
  it("is the viewer's own browser-authored row", () => {
    assert.equal(isOwnMessage(mine(), ME), true)
    assert.equal(canEditMessage(mine(), ME), true)
  })

  it("is NOT somebody else's message", () => {
    assert.equal(canEditMessage(mine({ from: 'CLE-07' }), ME), false)
  })

  it('is NOT a box-signed envelope — the hub answers 409 not_editable for one', () => {
    /* message-edit-v1 §4: a box envelope's Ed25519 signature covers the
       canonical inner bytes and the hub holds no key to re-sign it. The
       client gate has to agree, or `e` opens an editor that cannot save. */
    assert.equal(canEditMessage(mine({ from_box: 'box-a' }), ME), false)
    assert.equal(canEditMessage(mine({ from_box: '' }), ME), false)
    assert.equal(canEditMessage(mine({ from_box: undefined }), ME), false)
  })

  it('is NOT a row still in flight, and NOT a row with no id', () => {
    assert.equal(canEditMessage(mine({ pending: true }), ME), false)
    assert.equal(canEditMessage(mine({ msg_id: '' }), ME), false)
  })

  it('never opens for a viewer the app does not know yet', () => {
    /* signed out, or /v1/view/me not answered: no id, so no editor */
    assert.equal(canEditMessage(mine(), null), false)
    assert.equal(canEditMessage(mine(), { id: '', box: BROWSER_BOX }), false)
  })

  it("has NO time window — an ancient message is still the author's", () => {
    /* the owner said "slack wise" but did not ask for Slack's editing
       window, and a silent expiry produces bug reports, not features */
    assert.equal(canEditMessage(mine({ ts: '2020-01-01T00:00:00Z' }), ME), true)
  })
})

describe('the `e` shortcut', () => {
  it('is the letter e on the focused row itself', () => {
    assert.equal(EDIT_KEY, 'e')
    assert.equal(wantsEdit(key('e'), { editable: true }), true)
  })

  it('is refused where the row is not editable — the gate is not only the template', () => {
    assert.equal(wantsEdit(key('e'), { editable: false }), false)
    assert.equal(wantsEdit(key('e')), false)
  })

  it("does not steal an `e` typed inside a child control", () => {
    /* the same guard the row's existing Enter / Space handler uses: an `e`
       in the reply composer, or in the editor this very key opens, is that
       control's letter and must reach it */
    assert.equal(wantsEdit(key('e', { target: {} }), { editable: true }), false)
  })

  it('leaves every modified e, and every other key, alone', () => {
    for (const mod of ['ctrlKey', 'metaKey', 'altKey', 'shiftKey']) {
      assert.equal(wantsEdit(key('e', { [mod]: true }), { editable: true }), false, mod)
    }
    for (const k of ['E', 'Enter', ' ', 'Escape', 'x']) {
      assert.equal(wantsEdit(key(k), { editable: true }), false, k)
    }
    assert.equal(wantsEdit(key('e', { isComposing: true }), { editable: true }), false)
  })
})

describe('opening the editor — "the old msg should be shown there"', () => {
  it('pre-fills the draft with the stored body', () => {
    const st = beginEdit(mine())
    assert.equal(st.draft, 'the old msg')
    assert.equal(st.original, 'the old msg')
    assert.equal(st.msgId, '11111111-1111-4111-8111-111111111111')
  })

  it('pre-fills a multi-line body verbatim, fence and all', () => {
    const body = 'look:\n```js\nconst a = 1\n```\nsee?'
    assert.equal(beginEdit(mine({ body })).draft, body)
  })

  it('never invents a draft: no id, no edit', () => {
    assert.equal(beginEdit(mine({ msg_id: '' })), null)
    assert.equal(beginEdit(null), null)
  })

  it('an empty stored body opens an empty box, not a null one', () => {
    assert.equal(beginEdit(mine({ body: '' })).draft, '')
    assert.equal(beginEdit(mine({ body: undefined })).draft, '')
  })

  it('keeps `original` fixed while the draft moves', () => {
    /* what Escape restores is read ONCE, at open, so a live frame arriving
       mid-edit cannot move the text we promised to put back */
    const st = withDraft(withDraft(beginEdit(mine()), 'half'), 'the new msg')
    assert.equal(st.original, 'the old msg')
    assert.equal(st.draft, 'the new msg')
  })
})

describe('Enter commits, Shift+Enter makes a newline (ORDERED: the owner named Enter)', () => {
  it('does not follow the composer: a bare Enter still commits an edit', () => {
    /* 2026-09-23 the composer’s bare Enter is a newline (enterAction).
       2026-09-22 an edit commits on Enter. The two are different orders. */
    assert.equal(enterAction({}), 'newline')
    assert.equal(enterAction({ mod: true }), 'send')
    assert.equal(editKeyAction(key('Enter')), 'commit')
    assert.equal(editKeyAction(key('Enter', { ctrlKey: true })), 'commit')
    assert.equal(editKeyAction(key('Enter', { metaKey: true })), 'commit')
  })

  it('a bare Enter commits and Shift+Enter does not', () => {
    assert.equal(editKeyAction(key('Enter')), 'commit')
    assert.equal(editKeyAction(key('Enter', { shiftKey: true })), 'newline')
  })

  it('Enter inside a ``` block makes a newline, as it does in the composer', () => {
    assert.equal(editKeyAction(key('Enter'), { inCode: true }), 'newline')
  })

  it('hands every other key back to the textarea', () => {
    for (const k of ['a', 'e', 'Tab', 'ArrowUp']) assert.equal(editKeyAction(key(k)), '', k)
    assert.equal(editKeyAction(key('Enter', { isComposing: true })), '')
  })

  it('Escape cancels (INFERRED: Slack does it and this app already dismisses on Escape)', () => {
    assert.equal(editKeyAction(key('Escape')), 'cancel')
  })
})

describe('committing', () => {
  const edited = (draft) => commitEdit(withDraft(beginEdit(mine()), draft))

  it('sends the new body', () => {
    assert.deepEqual(edited('the new msg'), { action: 'commit', body: 'the new msg' })
  })

  it('closes an open ``` and trims, exactly as the composer does on send', () => {
    /* MessageComposer.onSend() computes `closeOpenFence(text).trim()`. Asserted
       AGAINST that expression rather than against a literal I typed out: the
       first draft of this case expected the interior trailing spaces to be
       gone, which is not what .trim() does and not what the composer does. A
       literal would have encoded my guess as the contract. */
    for (const draft of ['  ```js\nconst a = 1  ', 'plain  ', '  ```\na\n```  ', '```x```']) {
      assert.equal(editWireBody(draft), closeOpenFence(draft).trim(), JSON.stringify(draft))
    }
    assert.equal(edited('  ```js\nconst a = 1  ').body, '```js\nconst a = 1  \n```')
  })

  it('sends NOTHING when the text did not change — the register records changes, not saves', () => {
    /* the owner asked for "both the old and the new msg" stored; a revision
       whose two bodies are identical is noise in exactly that register */
    assert.equal(edited('the old msg').action, 'unchanged')
    assert.equal(edited('  the old msg  ').action, 'unchanged')
  })

  it('refuses an emptied box — clearing a message is a delete, and nobody asked for one', () => {
    for (const draft of ['', '   ', '\n\t ']) {
      const r = edited(draft)
      assert.equal(r.action, 'empty', JSON.stringify(draft))
      /* carries the same token live-ws uses, so one reporting path serves both */
      assert.equal(r.error.token, 'empty')
      assert.equal(editFailureKey(r.error), 'composer.send_failed_empty')
    }
  })

  it('MUTATES NOTHING — the caller decides what reaches the screen', () => {
    /* this is the CLE-3433 lesson as an assertion: the displayed body may not
       be replaced before the hub has confirmed, so commitEdit can only report */
    const msg = mine()
    const st = withDraft(beginEdit(msg), 'the new msg')
    commitEdit(st)
    assert.equal(msg.body, 'the old msg')
    assert.equal(st.original, 'the old msg')
    assert.equal(st.draft, 'the new msg')
  })

  it('a null state refuses rather than throwing', () => {
    assert.equal(commitEdit(null).action, 'empty')
  })
})

describe('cancelling and rolling back', () => {
  it('Escape answers the original body, however far the draft moved', () => {
    assert.equal(cancelEdit(withDraft(beginEdit(mine()), 'scribble')), 'the old msg')
  })

  it('answers the original after a REJECTED commit too — one rollback path, not two', () => {
    const st = withDraft(beginEdit(mine()), 'the new msg')
    assert.equal(commitEdit(st).action, 'commit')
    assert.equal(cancelEdit(st), 'the old msg')
  })

  it('restores an empty original as empty, not as undefined', () => {
    assert.equal(cancelEdit(beginEdit(mine({ body: '' }))), '')
    assert.equal(cancelEdit(null), '')
  })

  it('knows whether anything was actually typed', () => {
    const st = beginEdit(mine())
    assert.equal(editIsDirty(st), false)
    assert.equal(editIsDirty(withDraft(st, '  the old msg  ')), false)
    assert.equal(editIsDirty(withDraft(st, 'the new msg')), true)
    assert.equal(editIsDirty(null), false)
  })
})

describe('the edited marker (message-edit-v1 §2)', () => {
  it("is `edited_at`'s PRESENCE — the key is omitted until the first edit", () => {
    assert.equal(isEdited(mine()), false)
    assert.equal(isEdited(mine({ edited_at: '2026-09-22T07:40:00Z' })), true)
  })

  it('is not a boolean and not a counter', () => {
    /* pinning the shape: a hub that started sending `edited: true` or only a
       revision count would silently stop the marker rendering, and this says so */
    assert.equal(isEdited(mine({ edited: true })), false)
    assert.equal(isEdited(mine({ revision: 2 })), false)
    assert.equal(isEdited(mine({ edited_at: '' })), false)
    assert.equal(isEdited(mine({ edited_at: 1758527000 })), false)
  })

  it('counts revisions with the original included — the first edit gives 2', () => {
    assert.equal(revisionOf(mine()), 1)
    assert.equal(revisionOf(mine({ revision: 2 })), 2)
    assert.equal(revisionOf(mine({ revision: 7 })), 7)
    assert.equal(revisionOf(mine({ revision: 0 })), 1)
  })
})

describe('reporting a refusal (message-edit-v1 §5)', () => {
  const err = (token) => Object.assign(new Error(token), { token })

  it('names the hub refusals a reader can act on', () => {
    assert.equal(editFailureKey(err('not_author')), 'feed.edit.failed_not_author')
    assert.equal(editFailureKey(err('not_found')), 'feed.edit.failed_not_found')
    assert.equal(editFailureKey(err('not_editable')), 'feed.edit.failed_not_editable')
    assert.equal(editFailureKey(err('too_large')), 'feed.edit.failed_too_large')
  })

  it("maps the hub's empty_body onto the composer's existing empty line", () => {
    /* §5 mirrors the send token on purpose; a second string saying the same
       thing is a second thing to translate into 19 catalogues */
    assert.equal(editFailureKey(err('empty_body')), 'composer.send_failed_empty')
  })

  it('reuses the composer family for a transport failure', () => {
    assert.equal(editFailureKey(err('closed')), 'composer.send_failed_closed')
    assert.equal(editFailureKey(err('timeout')), 'composer.send_failed_timeout')
    assert.equal(editFailureKey(new Error('boom')), 'composer.send_failed')
    assert.equal(editFailureKey(null), 'composer.send_failed')
  })

  it('every key it can answer exists in the English catalogue', () => {
    /* a failure path that renders a raw key is how a rollback gets reported
       as gibberish; the 19-catalogue parity gate covers the other 18 */
    const en = JSON.parse(src('i18n/locales/en.json'))
    const at = (k) => k.split('.').reduce((o, p) => (o == null ? o : o[p]), en)
    for (const token of ['not_author', 'not_found', 'not_editable', 'too_large', 'empty_body', 'closed', 'timeout', '']) {
      const key = editFailureKey(err(token))
      assert.equal(typeof at(key), 'string', `${token} -> ${key}`)
    }
  })
})

describe('the wire body helper', () => {
  it('is what would actually be sent', () => {
    assert.equal(editWireBody('  hi  '), 'hi')
    assert.equal(editWireBody(''), '')
    assert.equal(editWireBody(null), '')
    assert.equal(editWireBody(undefined), '')
  })
})


/*
 * CLE-3446 — the OWNER's bug, 2026-09-22:
 *
 *   "also the editing of the msg appears whenever the bot is sending"
 *   "of course msgs sent by bots should not be editable"
 *
 * The predicate above was never wrong. The row under the card changed.
 *
 * The 3rd panel's pinned root is ONE MessageCard that gets re-rooted rather
 * than remounted -- `stores/live.ts open()` reassigns `taskId` without it ever
 * passing through null, so the <aside> is never torn down. `:editable` is a
 * prop and updated correctly; `edit` / `saving` / `editError` are local refs
 * and did not, so an editor opened on your own message stayed open on
 * whatever landed in the panel next. Measured in Chrome with the textarea
 * sitting on CLE-07@box-a's message still holding HUM-1's body.
 *
 * The browser gate is tests/e2e/msg-edit.test.mjs step 8.1 and it is the one
 * that proves behaviour. These two are the cheap structural guards, in the
 * suite that runs in a second, so the shape cannot quietly come back.
 *
 * CONTROL: drop the `:key` from any one of the three mounts, or delete the
 * watcher from MessageCard.vue, and the matching case here goes red.
 */
describe('CLE-3446 — an edit never rides across onto another row', () => {
  /* every host that pins a single root MessageCard, and the expression it pins */
  const ROOTS = [
    ['ThreadPane', 'src/components/ThreadPane.vue', 'root'],
    ['LiveThreadPane', 'src/components/LiveThreadPane.vue', 'root'],
    ['t/[task_id]', 'src/pages/t/[task_id].vue', 'store.thread.root'],
  ]

  it('every pinned-root MessageCard is keyed by msg_id, so a re-root REPLACES the card', () => {
    for (const [name, rel, root] of ROOTS) {
      const tpl = src(rel)
      const mount = tpl.split('\n').find((l) => l.includes('<MessageCard') && l.includes(`:msg="${root}"`))
      assert.ok(mount, `${name}: no pinned-root <MessageCard :msg="${root}"> found`)
      assert.match(mount, /:key="String\(.*\.msg_id \|\| ''\)"/, `${name} mounts the root card without a :key`)
    }
  })

  it('MessageCard resets its edit state when the row identity changes', () => {
    /* the half that does not depend on every future host remembering the key */
    const card = src('src/components/MessageCard.vue')
    const m = card.match(/watch\(\(\) => String\(props\.msg\?\.msg_id \|\| ''\)[\s\S]{0,400}?\n\}\)/)
    assert.ok(m, 'MessageCard.vue has no watcher on props.msg.msg_id')
    for (const cleared of ['edit.value = null', 'saving.value = false', "editError.value = ''"]) {
      assert.ok(m[0].includes(cleared), `the msg_id watcher does not clear: ${cleared}`)
    }
  })
})
