// CLE-3433 / OA-38 — `/dm/<peer>?thread=<id>` did not bind the Omnibox to
// that thread. `stores/channel.ts sendLive()` does
// `task_id: parentTaskId || newId()`, and the DM and channel pages passed no
// parent, so every send from a page whose URL NAMED a thread minted a new
// task. Measured by CLE-3438 on dev (tree f76f648, n=1): 12 messages from one
// such page produced 12 distinct task ids in the peer's inbox — the owner's
// exchange scattered into twelve conversations, and an agent reply into one
// of them did not appear beside the others.
//
// The thread pane's OWN composer was always bound (`:parent-task-id`), which
// is why this looked like it worked: the defect is the big box at the top
// sending somewhere other than where the URL says you are.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { omniboxParentTaskId, omniboxPlaceholderKey } from '../../src/utils/omnibox-thread.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const PAGES = ['src/pages/dm/[peer].vue', 'src/pages/channel/[name].vue']

describe('which conversation the Omnibox writes into (CLE-3433 / OA-38)', () => {
  it('an open thread is the parent; a closed one is not', () => {
    assert.equal(omniboxParentTaskId({ open: true, parentTaskId: 'T-1' }), 'T-1')
    assert.equal(omniboxParentTaskId({ open: false, parentTaskId: 'T-1' }), '')
  })

  /* closing the pane must release the box, or a reader who opened one thread
     could never start a new message again */
  it('nothing is trapped: no thread, no parent', () => {
    assert.equal(omniboxParentTaskId({ open: true, parentTaskId: '' }), '')
    assert.equal(omniboxParentTaskId({ open: true, parentTaskId: null }), '')
    assert.equal(omniboxParentTaskId(null), '')
    assert.equal(omniboxParentTaskId(undefined), '')
    assert.equal(omniboxParentTaskId({}), '')
  })

  it('the box SAYS it is replying — a box that sends somewhere it does not name is the defect', () => {
    assert.equal(omniboxPlaceholderKey('T-1'), 'thread.reply_placeholder')
    assert.equal(omniboxPlaceholderKey(''), '')
  })

  for (const page of PAGES) {
    it(`${page}: the send carries the open thread, and the placeholder follows it`, () => {
      const s = src(page)
      assert.match(s, /omniboxParentTaskId\(thread\)/)
      assert.match(s, /channel\.send\(text, replyTo\.value \|\| undefined\)/)
      assert.match(s, /omniboxPlaceholderKey\(replyTo\.value\)/)
      assert.match(s, /from '~\/utils\/omnibox-thread\.mjs'/)
    })
  }

  /* the key the placeholder resolves to has to exist, or the box renders the
     key itself and the fix reads as a different bug */
  it('thread.reply_placeholder exists in all 19 locales', () => {
    for (const code of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const j = JSON.parse(src(`i18n/locales/${code}.json`))
      assert.equal(typeof (j.thread && j.thread.reply_placeholder), 'string', `${code}: thread.reply_placeholder missing`)
    }
  })

  it('CONTROL: sendLive still mints a new task when there is no parent', () => {
    assert.match(src('src/stores/channel.ts'), /task_id: parentTaskId \|\| newId\(\)/)
  })
})
