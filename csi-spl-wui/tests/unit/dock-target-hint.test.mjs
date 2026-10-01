// SPL-1003 (owner, prd t1 #spool-hub-mobile, 2026-09-27): "When I write to the
// right most pane for the msgs aka threads on mobile it does not add the msg
// to the threads but on the topic pane" - "is parent should be 0" - "Bug it is
// 1". That line (9dea79ac, 12:10:52Z) was stored is_parent 1, a new topic, and
// nothing on the phone said where it would go. The docked composer now says
// it before the send: the open thread (a reply) or a new topic in the feed.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { composerModeChipKey, composerModeLabel, composerSendKey, dockTargetHint } from '../../src/utils/omnibox-topic.mjs'

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

  it('an addressed task dispatch is the explicit new topic with a thread open (SPL-996 B); the hint follows the text', () => {
    assert.equal(dockTargetHint({ reply: true, target: '#alerts' }, '@CLE-07 look').mode, 'new')
    assert.equal(dockTargetHint({ reply: true, target: '#alerts' }, 'ping @CLE-07').mode, 'thread')
    /* e09a72f7: a leading @ that addresses no task stays a thread reply */
    assert.equal(dockTargetHint({ reply: true, target: '#alerts' }, '@test').mode, 'thread')
    assert.equal(dockTargetHint({ reply: true, target: '#alerts' }, '@CLE-07').mode, 'thread')
  })

  it('an open issue on a phone: every line is a comment on it, `@someone` first too', () => {
    assert.deepEqual(dockTargetHint({ reply: true, target: 'SPL-7', comment: true }, 'hello'), { mode: 'comment', target: 'SPL-7' })
    assert.equal(dockTargetHint({ reply: true, target: 'SPL-7', comment: true }, '@CLE-07 look').mode, 'comment')
  })

  it('/issues registers the comment target only while an issue is open on a phone, and GO without a target searches', () => {
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

  it('the line over the box shows on a docked composer - the phone dock, or the bottom dock (topic c6994436); the top bar has its own chip (HUM-24)', () => {
    const c = src('src/components/MessageComposer.vue')
    assert.match(c, /v-if="\(docked \|\| bottom\) && !searchMode && dockHint"/)
    assert.match(src('src/components/TopBar.vue'), /:dock-target="dockTarget"/)
  })
})

// HUM-24 (CLE-77879, 2026-10-01): "creating a new topic must look different
// from writing a reply in the chat" - every mode has its own label, accent,
// placeholder and GO words, on the desktop top bar too.
describe('the composer looks different per mode (HUM-24)', () => {
  const LOCALES = join(WUI, 'i18n/locales')
  const loc = (l) => JSON.parse(readFileSync(join(LOCALES, `${l}.json`), 'utf8'))
  const ALL = readdirSync(LOCALES).filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, ''))

  it('a reply never carries the topic title (owner, t1 7d777e79: "reply : <<the title>> is a bug"); a DM page says "with" the peer', () => {
    assert.deepEqual(dockTargetHint({ reply: true, target: '#alerts', title: 'disk is full' }, 'x'), { mode: 'thread', target: '#alerts' })
    assert.deepEqual(dockTargetHint({ reply: false, target: 'CLE-07@box-a', dm: true }, 'x'), { mode: 'dm', target: 'CLE-07@box-a' })
    /* a DM with its thread open is a reply, like anywhere else */
    assert.equal(dockTargetHint({ reply: true, target: 'CLE-07@box-a', dm: true }, 'x').mode, 'thread')
    /* an addressed line starts a new topic in the DM */
    assert.equal(dockTargetHint({ reply: true, target: 'CLE-07@box-a', dm: true }, '@CLE-07 go').mode, 'dm')
  })

  it('one label per mode for the dock line, and one short word per mode for the desktop chip', () => {
    assert.deepEqual(composerModeLabel({ mode: 'new', target: '#alerts' }), { key: 'composer.target_new', params: { target: '#alerts' } })
    assert.deepEqual(composerModeLabel({ mode: 'dm', target: 'HUM-2' }), { key: 'composer.target_dm', params: { target: 'HUM-2' } })
    assert.deepEqual(composerModeLabel({ mode: 'thread', target: '#a', title: 'T' }), { key: 'composer.target_thread', params: {} })
    assert.equal(composerModeChipKey({ mode: 'new' }), 'composer.mode_new')
    assert.equal(composerModeChipKey({ mode: 'dm' }), 'composer.mode_new')
    assert.equal(composerModeChipKey({ mode: 'thread' }), 'composer.mode_reply')
    assert.equal(composerModeChipKey({ mode: 'comment' }), 'composer.mode_comment')
    assert.equal(composerModeChipKey(null), '')
    assert.deepEqual(composerModeLabel({ mode: 'comment', target: 'SPL-7' }), { key: 'composer.target_comment', params: { target: 'SPL-7' } })
    assert.equal(composerModeLabel(null), null)
  })

  it('the GO button says what it does', () => {
    assert.equal(composerSendKey({ mode: 'new' }), 'composer.go_new')
    assert.equal(composerSendKey({ mode: 'dm' }), 'composer.go_new')
    assert.equal(composerSendKey({ mode: 'thread' }), 'composer.go_reply')
    assert.equal(composerSendKey({ mode: 'comment' }), 'composer.go_comment')
    assert.equal(composerSendKey(null), 'composer.go')
  })

  it('every locale carries the new words, translated', () => {
    const en = loc('en')
    const KEYS = [['composer', 'mode_new'], ['composer', 'mode_reply'], ['composer', 'mode_comment'], ['composer', 'target_dm'], ['composer', 'go_new'], ['composer', 'go_reply'], ['composer', 'go_comment'], ['feed', 'edit', 'mode']]
    const get = (d, path) => path.reduce((o, k) => (o ? o[k] : undefined), d)
    assert.equal(ALL.length, 19)
    for (const l of ALL) {
      const d = loc(l)
      for (const path of KEYS) {
        const v = get(d, path)
        assert.equal(typeof v, 'string', `${l} ${path.join('.')}`)
        assert.ok(v.trim(), `${l} ${path.join('.')}`)
        if (l !== 'en') assert.notEqual(v, get(en, path), `${l} ${path.join('.')} is still English`)
      }
      assert.match(d.composer.target_dm, /\{target\}/, l)
      /* the chip is a word or two, never a placeholder */
      for (const k of ['mode_new', 'mode_reply', 'mode_comment']) assert.ok(!/[{}]/.test(d.composer[k]) && d.composer[k].length <= 20, `${l} ${k}`)
    }
    /* HUM-24 is Bulgarian: the words checked */
    const bg = loc('bg')
    assert.equal(bg.composer.target_new, 'Нова тема в {target}')
    assert.equal(bg.composer.mode_reply, 'Отговор')
    assert.equal(bg.feed.edit.mode, 'Редактиране на това съобщение')
  })

  it('the top bar shows the chip, the form carries the mode, DM pages say dm, the placeholder is the old one', () => {
    const c = src('src/components/MessageComposer.vue')
    assert.match(c, /v-if="global && !docked && !bottom && !searchMode && dockHint"\n\s+class="composer-mode"/)
    assert.match(c, /:data-mode="modeAttr"/)
    assert.match(c, /t\(sendKey\)/)
    assert.match(c, /\.composer\.omnibox--global\[data-mode\] \.omnibox-field \{/)
    assert.match(c, /t\(composerModeChipKey\(dockHint\)\)/)
    assert.doesNotMatch(src('src/components/TopBar.vue'), /threadTitle/)
    assert.match(src('src/pages/dm/[peer].vue'), /dm: true \}\)/)
    /* 4.8.7 regression: "New topic in #x — Enter for a new line · Ctrl+Ent…"
       was cut off next to a long chip; the placeholder is the one before HUM-24 */
    for (const page of ['src/pages/channel/[name].vue', 'src/pages/lobby.vue', 'src/pages/index.vue', 'src/pages/t/[task_id].vue']) {
      assert.match(src(page), /sk\('search\.placeholder_target'\)/, page)
    }
    assert.doesNotMatch(c, /\[data-mode\]:not\(\.omnibox--bottom\) textarea::placeholder/)
    assert.match(src('src/components/MessageCard.vue'), /data-test="msg-edit-mode"/)
  })

  it('each mode accent is defined for the dark default and every light theme', () => {
    const v = src('src/assets/css/variables.css')
    for (const k of ['--color-mode-new', '--color-mode-reply', '--color-mode-edit']) {
      assert.equal((v.match(new RegExp(`${k}:`, 'g')) || []).length, 2, k)
    }
    assert.match(v, /:root\[data-theme\^="light"\] \{/)
  })
})
