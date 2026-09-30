// Topic c6994436: Settings -> Behaviour "Message order" and "Omnibox
// position". The values are pinned equal to the hub's (auth.ViewPrefs) and to
// rdb 0070's CHECKs, the defaults are today's layout, a feed draws its
// newest-first rows reversed only for "newest last", and the newest-last
// scroll anchor is the mirror of the 013 prepend one.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  MESSAGE_ORDERS, COMPOSER_POSITIONS, DEFAULT_MESSAGE_ORDER, DEFAULT_COMPOSER_POSITION,
  parseMessageOrder, parseComposerPosition, displayOrder, applyViewPref,
} from '../../src/utils/view-prefs.mjs'
import { appendedCount, isFreshList, anchorAfterAppend, distanceFromBottom, NEAR_BOTTOM_PX } from '../../src/utils/scroll-anchor.mjs'
import { newestFirst, windowed } from '../../src/utils/feed.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const msg = (n) => ({ msg_id: `m${n}`, ts: `2026-09-28T10:${String(n).padStart(2, '0')}:00Z` })

describe('view pref values', () => {
  it('the hub (auth.ViewPrefs) and rdb 0070 admit the same values, default first', () => {
    assert.deepEqual([...MESSAGE_ORDERS], ['newest-first', 'newest-last'])
    assert.deepEqual([...COMPOSER_POSITIONS], ['top', 'bottom'])
    const go = read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go')
    assert.match(go, /PrefMessageOrder: +\{"newest-first", "newest-last"\}/)
    assert.match(go, /PrefComposerPosition: +\{"top", "bottom"\}/)
    const sql = read('../csi-spl-rdb/src/sql/postgres/spool-hub/0070_human_view_prefs.sql')
    assert.match(sql, /message_order IN \('newest-first','newest-last'\)/)
    assert.match(sql, /composer_position IN \('top','bottom'\)/)
  })
  it('SPL-1028: issues_view is list | status in the hub (auth.ViewPrefs) and rdb 0072, list first', async () => {
    const { ISSUES_VIEWS, parseIssuesView } = await import('../../src/utils/view-prefs.mjs')
    assert.deepEqual([...ISSUES_VIEWS], ['list', 'status'])
    assert.match(read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go'), /PrefIssuesView: +\{"list", "status"\}/)
    assert.match(read('../csi-spl-rdb/src/sql/postgres/spool-hub/0072_human_issues_view.sql'), /issues_view IN \('list','status'\)/)
    for (const raw of [null, undefined, '', 'board', 'Status']) assert.equal(parseIssuesView(raw), 'list')
    assert.equal(parseIssuesView('status'), 'status')
  })
  it('SPL-1133: close_buttons is mac | windows in the hub (auth.ViewPrefs) and rdb 0077, mac (the owner\'s default) first', async () => {
    const { CLOSE_BUTTONS, parseCloseButtons, closeButtonShown } = await import('../../src/utils/view-prefs.mjs')
    assert.deepEqual([...CLOSE_BUTTONS], ['mac', 'windows'])
    assert.match(read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go'), /PrefCloseButtons: +\{"mac", "windows"\}/)
    assert.match(read('../csi-spl-rdb/src/sql/postgres/spool-hub/0077_human_close_buttons.sql'), /close_buttons IN \('mac','windows'\)/)
    for (const raw of [null, undefined, '', 'linux', 'Windows']) assert.equal(parseCloseButtons(raw), 'mac')
    assert.equal(parseCloseButtons('windows'), 'windows')
    /* exactly one of the two placements renders */
    for (const pref of [null, 'mac', 'windows', 'junk']) assert.notEqual(closeButtonShown('start', pref), closeButtonShown('end', pref))
    assert.equal(closeButtonShown('start', null), true)
    assert.equal(closeButtonShown('end', 'windows'), true)
  })
  it('SPL-1133: every close X of a dialog, pane or sheet is the shared UiCloseButton, placed at both ends', () => {
    for (const [file, n] of [['src/components/UiDialog.vue', 2], ['src/components/TopicPane.vue', 2], ['src/components/LiveTopicPane.vue', 2],
      ['src/components/UserEditPane.vue', 2], ['src/pages/issues.vue', 4]]) {
      const src = read(file)
      const starts = (src.match(/<UiCloseButton side="start"/g) || []).length
      const ends = (src.match(/<UiCloseButton side="end"/g) || []).length
      assert.equal(starts + ends, n, `${file}: ${starts} start + ${ends} end`)
      assert.equal(starts, ends, `${file}: one start per end`)
      assert.doesNotMatch(src, /<button[^>]*(?:ui-dialog__close|topic-close|users-pane__close|issues-sheet__x)/, `${file}: a hand-rolled close X`)
    }
    assert.match(read('src/app.vue'), /'data-close-buttons': parseCloseButtons\(session\.claims\?\.close_buttons\)/)
    for (const code of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const s = JSON.parse(read(`i18n/locales/${code}.json`)).settings
      for (const k of ['label', 'mac', 'windows', 'hint']) assert.ok(s.close_buttons?.[k], `${code} close_buttons.${k}`)
    }
  })
  it('never picked = today\'s layout: newest first, Omnibox at the top', () => {
    assert.equal(DEFAULT_MESSAGE_ORDER, 'newest-first')
    assert.equal(DEFAULT_COMPOSER_POSITION, 'top')
    for (const raw of [null, undefined, '', 'oldest-first', 'bottom', 7]) assert.equal(parseMessageOrder(raw), 'newest-first')
    for (const raw of [null, undefined, '', 'left', 'newest-last']) assert.equal(parseComposerPosition(raw), 'top')
    assert.equal(parseMessageOrder('newest-last'), 'newest-last')
    assert.equal(parseComposerPosition('bottom'), 'bottom')
  })
  it('the session carries both claims and the auth client sends only the one key', () => {
    const ts = read('src/stores/session.ts')
    assert.match(ts, /message_order\?: string \| null/)
    assert.match(ts, /composer_position\?: string \| null/)
    const client = read('src/utils/auth-client.mjs')
    assert.match(client, /saveViewPref\(key, value\) \{\n\s+return post\('\/preferences', \{ \[String\(key\)\]: value \? String\(value\) : null \}, 'PUT'\)/)
  })
  it('every locale names both settings and their choices', () => {
    for (const code of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const s = JSON.parse(read(`i18n/locales/${code}.json`)).settings
      for (const k of ['label', 'newest_first', 'newest_last', 'hint']) assert.ok(s.message_order?.[k], `${code} message_order.${k}`)
      for (const k of ['label', 'top', 'bottom', 'hint']) assert.ok(s.composer_position?.[k], `${code} composer_position.${k}`)
    }
  })
  it('Settings -> Behaviour holds both radio groups', () => {
    assert.match(read('src/pages/settings/behaviour.vue'), /<ViewPrefsSetting \/>/)
    const c = read('src/components/ViewPrefsSetting.vue')
    assert.match(c, /MESSAGE_ORDERS/)
    assert.match(c, /COMPOSER_POSITIONS/)
    assert.match(c, /:data-test="`\$\{g\.key\}-\$\{v\}`"/)
  })
})

describe('displayOrder', () => {
  const rows = newestFirst([msg(1), msg(3), msg(2)])
  it('newest first draws the rows as handed (the default is untouched)', () => {
    assert.equal(displayOrder(rows, 'newest-first'), rows)
    assert.equal(displayOrder(rows, null), rows)
  })
  it('newest last reverses a copy, the newest at the end', () => {
    const out = displayOrder(rows, 'newest-last')
    assert.deepEqual(out.map((m) => m.msg_id), ['m1', 'm2', 'm3'])
    assert.deepEqual(rows.map((m) => m.msg_id), ['m3', 'm2', 'm1'])
  })
  it('A4: the window still holds the NEWEST rows in both orders', () => {
    const all = newestFirst(Array.from({ length: 40 }, (_, i) => msg(i)))
    const w = windowed(all, 30)
    const last = displayOrder(w.rows, 'newest-last')
    assert.equal(last[last.length - 1].msg_id, 'm39')
    assert.equal(last[0].msg_id, 'm10')
    assert.equal(w.hasOlder, true)
  })
  it('A11: the reading order is the DOM order, never a CSS column-reverse', () => {
    const feed = read('src/components/LiveFeed.vue')
    assert.doesNotMatch(feed, /column-reverse/)
    /* CLE-77804: the loop is over feedItems (rows + the interleaved divider),
       but its order still comes from `shown`, itself displayOrder(props.rows). */
    assert.match(feed, /v-for="it in feedItems"/)
    assert.match(feed, /shown\.value\.forEach\(\(m, i\)/)
    assert.match(feed, /displayOrder\(props\.rows/)
  })
})

describe('applyViewPref (the optimistic radio save)', () => {
  it('mirrors, saves, and keeps the new value on success', async () => {
    const seen = []
    const r = await applyViewPref('message_order', 'newest-last', { current: null, apply: (v) => seen.push(v), save: async () => ({ ok: true }) })
    assert.deepEqual(r, { ok: true, value: 'newest-last' })
    assert.deepEqual(seen, ['newest-last'])
  })
  it('puts the old value back when the hub refuses', async () => {
    const seen = []
    const r = await applyViewPref('composer_position', 'bottom', { current: 'top', apply: (v) => seen.push(v), save: async () => ({ ok: false }) })
    assert.equal(r.ok, false)
    assert.deepEqual(seen, ['bottom', 'top'])
  })
  it('refuses another key\'s value and saves nothing', async () => {
    let saved = 0
    const r = await applyViewPref('message_order', 'bottom', { current: null, apply: () => {}, save: async () => { saved++; return { ok: true } } })
    assert.equal(r.ok, false)
    assert.equal(saved, 0)
  })
  it('a never-picked account storing the default still saves (the checked-radio trap)', async () => {
    let saved = 0
    await applyViewPref('message_order', 'newest-first', { current: null, apply: () => {}, save: async () => { saved++; return { ok: true } } })
    assert.equal(saved, 1)
  })
})

describe('newest-last scroll anchor', () => {
  it('appendedCount counts the keys below the previous last one', () => {
    assert.equal(appendedCount(['a', 'b'], ['a', 'b', 'c', 'd']), 2)
    assert.equal(appendedCount(['a', 'b'], ['z', 'a', 'b']), 0)
    /* the window dropped its oldest row at the top while one arrived below */
    assert.equal(appendedCount(['a', 'b', 'c'], ['b', 'c', 'd']), 1)
    assert.equal(appendedCount([], ['a']), 0)
  })
  it('isFreshList: first rows, or another topic in the same pane', () => {
    assert.equal(isFreshList([], ['a']), true)
    assert.equal(isFreshList(['a', 'b'], ['x', 'y']), true)
    assert.equal(isFreshList(['a', 'b'], ['b', 'c']), false)
    assert.equal(isFreshList(['a'], []), false)
  })
  it('A2/A5: a reader at the bottom follows new rows; our own send goes there too', () => {
    assert.deepEqual(anchorAfterAppend({ top: 500, atBottom: true, added: 2, pill: 3 }), { bottom: true, top: 500, pill: 0 })
    assert.deepEqual(anchorAfterAppend({ top: 100, atBottom: false, own: true, added: 1 }), { bottom: true, top: 100, pill: 0 })
  })
  it('A1: scrolled up, an older page loaded ABOVE keeps the visible row in place', () => {
    const r = anchorAfterAppend({ top: 200, atBottom: false, anchorBefore: 900, anchorAfter: 2400, added: 0, pill: 0 })
    assert.deepEqual(r, { bottom: false, top: 1700, pill: 0 })
  })
  it('A5: scrolled up, rows appended below are counted in the pill and do not move the view', () => {
    const r = anchorAfterAppend({ top: 200, atBottom: false, anchorBefore: 900, anchorAfter: 900, added: 2, pill: 1 })
    assert.deepEqual(r, { bottom: false, top: 200, pill: 3 })
  })
  it('distanceFromBottom and the bottom band', () => {
    assert.equal(distanceFromBottom({ top: 920, height: 1500, client: 500 }), 80)
    assert.equal(distanceFromBottom({ top: 0, height: 300, client: 500 }), 0)
    assert.equal(NEAR_BOTTOM_PX, 80)
  })
  it('the composable wires the mirror mode, and the default (newest first) path is the 013 one', () => {
    const c = read('src/composables/useScrollAnchor.ts')
    assert.match(c, /newestLast: \(\) => boolean = \(\) => false/)
    assert.match(c, /new ResizeObserver/)
    /* never scroll inside the observer callback (a window error the snackbar shows) */
    assert.match(c, /frame = requestAnimationFrame\(/)
    /* only scrolling UP lets go of the bottom (late growth fires scroll events too) */
    assert.match(c, /else if \(top < lastTop - 1\) stuck = false/)
    assert.match(c, /anchorAfterPrepend\(\{/)
    const feed = read('src/components/LiveFeed.vue')
    assert.match(feed, /\(\) => props\.holdScroll !== true \|\| newestLast\.value,\n\s+\(\) => newestLast\.value,/)
    /* the pill points at the newest end */
    assert.match(feed, /↑ \{\{ t\('feed\.new_pill'/)
    assert.match(feed, /↓ \{\{ t\('feed\.new_pill'/)
    /* A9: a deep link stops the bottom follow */
    assert.match(feed, /if \(el\) hold\(\)/)
  })
})
