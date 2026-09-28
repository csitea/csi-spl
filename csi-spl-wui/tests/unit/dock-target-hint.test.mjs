// SPL-1003 (owner, prd t1 #spool-hub-mobile, 2026-09-27): "When I write to the
// right most pane for the msgs aka threads on mobile it does not add the msg
// to the threads but on the topic pane" - "is parent should be 0" - "Bug it is
// 1". That line (9dea79ac, 12:10:52Z) was stored is_parent 1, a new topic, and
// nothing on the phone said where it would go. The docked composer now says
// it before the send: the open thread (a reply) or a new topic in the feed.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { dockTargetHint } from '../../src/utils/omnibox-topic.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const PAGES = ['src/pages/channel/[name].vue', 'src/pages/dm/[peer].vue', 'src/pages/index.vue', 'src/pages/lobby.vue', 'src/pages/t/[task_id].vue']

describe('the phone dock names its target (SPL-1003)', () => {
  it('an open thread: the post is a reply there', () => {
    assert.deepEqual(dockTargetHint({ reply: true, target: '#alerts' }, 'hello'), { mode: 'thread', target: '#alerts' })
    assert.deepEqual(dockTargetHint({ reply: true, target: '#alerts' }), { mode: 'thread', target: '#alerts' })
  })

  it('no thread open: a new topic in the feed', () => {
    assert.deepEqual(dockTargetHint({ reply: false, target: '#alerts' }, 'hello'), { mode: 'new', target: '#alerts' })
  })

  it('`@someone` first is the explicit new topic even with a thread open (SPL-996 B), and the hint follows the text', () => {
    assert.equal(dockTargetHint({ reply: true, target: '#alerts' }, '@CLE-07 look').mode, 'new')
    assert.equal(dockTargetHint({ reply: true, target: '#alerts' }, 'ping @CLE-07').mode, 'thread')
  })

  it('an open issue on a phone: every line is a comment on it, `@someone` first too (CLE-35066)', () => {
    assert.deepEqual(dockTargetHint({ reply: true, target: 'SPL-7', comment: true }, 'hello'), { mode: 'comment', target: 'SPL-7' })
    assert.equal(dockTargetHint({ reply: true, target: 'SPL-7', comment: true }, '@CLE-07 look').mode, 'comment')
  })

  it('/issues registers the comment target only while an issue is open on a phone, and GO without a target searches (CLE-35066)', () => {
    const s = src('src/pages/issues.vue')
    assert.match(s, /const dockComment = computed\(\(\) => Boolean\(phone\.value && detail\.value && detail\.value\.task_id && !creating\.value\)\)/)
    assert.match(s, /dock: \(\) => \(\{ reply: true, target: detail\.value\?\.key \|\| '', comment: true \}\)/)
    assert.match(s, /onBeforeUnmount\(\(\) => omniboxStore\.unregister\(commentOwner\)\)/)
    const c = src('src/components/MessageComposer.vue')
    assert.match(c, /if \(docked\.value && q\) \{\n\s+emit\('search', q\)/)
    assert.match(c, /data-mode="search"/)
  })

  it('a page with no send target shows nothing', () => {
    assert.equal(dockTargetHint(null, 'x'), null)
    assert.equal(dockTargetHint(undefined), null)
  })

  it('every page that registers a send target also says where it goes', () => {
    for (const page of PAGES) {
      const s = src(page)
      assert.match(s, /useOmniboxTarget\(/, page)
      assert.match(s, /dock: \(\) => \(\{ reply: Boolean\(/, page)
    }
  })

  it('the hint shows only on a docked composer - the phone dock, or the bottom dock (topic c6994436) - so the default desktop is unchanged', () => {
    const c = src('src/components/MessageComposer.vue')
    assert.match(c, /v-if="\(docked \|\| bottom\) && !searchMode && dockHint"/)
    assert.match(src('src/components/TopBar.vue'), /:dock-target="dockTarget"/)
  })
})
