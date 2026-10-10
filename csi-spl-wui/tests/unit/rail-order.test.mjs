// SPL-979: Settings -> Behaviour -> "Left panel order". Six rail tabs, one
// stored order, reordered by dragging the rail icons or the Settings list.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  RAIL_TABS,
  RAIL_IDS,
  DRAG_THRESHOLD_PX,
  isRailOrder,
  parseRailOrder,
  sameOrder,
  moveTo,
  moveBy,
  dropIndex,
  isDrag,
  applyRailOrder,
  railLabelKey,
  RAIL_PINNED_LAST,
  DEFAULT_RAIL_ORDER,
  pinRailOrder,
  isRailMovable,
  dragAxis,
} from '../../src/utils/rail-order.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('rail ids', () => {
  it('eleven tabs in the new-member order (spec 089 T007 adds Calendar last)', () => {
    assert.deepEqual([...RAIL_IDS], ['channels', 'dm', 'issues', 'topics', 'flow', 'archive', 'events', 'people', 'agents', 'boxes', 'calendar'])
    assert.deepEqual(RAIL_TABS.map((t) => t.icon), ['hash', 'messages', 'issues', 'list', 'waves', 'archive', 'history', 'users', 'bot', 'server', 'calendar'])
  })
  it('the hub (auth.RailTabs) and rdb 0133 hold the same list', () => {
    const go = read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go')
    /* spec 089 T007: the hub admits the eleven (rdb 0133) as well as the legacy 6 / 7 / 9 / 10 */
    const hub = JSON.parse('[' + /\bRailTabs = \[\]string\{([^}]*)\}/.exec(go)[1] + ']')
    assert.deepEqual(hub, [...RAIL_IDS])
    assert.match(go, /\blegacyRailTabs10 = \[\]string\{"channels", "dm", "issues", "topics", "flow", "archive", "events", "people", "agents", "boxes"\}/)
    const sql = read('../csi-spl-rdb/src/sql/postgres/spool-hub/0133_human_rail_order_calendar.sql')
    assert.match(sql, /ARRAY\['dm','channels','issues','topics','flow','events','archive','people','agents','boxes'\]/)
    assert.match(sql, /ARRAY\['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar'\]/)
  })
  it('only a permutation of the eleven is sent; the drawn order is tolerant', () => {
    assert.ok(isRailOrder(['calendar', 'boxes', 'agents', 'people', 'archive', 'events', 'flow', 'topics', 'issues', 'channels', 'dm']))
    assert.equal(isRailOrder(['boxes', 'agents', 'people', 'archive', 'events', 'flow', 'topics', 'issues', 'channels', 'dm']), false, 'the legacy ten is drawn, never sent')
    for (const bad of [null, [], ['dm'], ['events', 'flow', 'topics', 'issues', 'channels', 'dm'], ['agents', 'people', 'archive', 'events', 'flow', 'topics', 'issues', 'channels', 'dm'], [...RAIL_IDS, 'users'], 'dm']) {
      assert.equal(isRailOrder(bad), false, JSON.stringify(bad))
    }
    for (const none of [null, [], 'dm', ['users']]) assert.deepEqual(parseRailOrder(none), [...DEFAULT_RAIL_ORDER])
    /* SPL-983 / CLE-77794 / CLE-77799: an order stored before a tab existed keeps
       its place, the tabs added since (archive, people + agents, then boxes) appended */
    assert.deepEqual(parseRailOrder(['topics', 'dm', 'channels', 'issues', 'flow', 'events']), ['topics', 'dm', 'channels', 'issues', 'flow', 'events', 'people', 'agents', 'boxes', 'calendar', 'archive'])
    assert.deepEqual(parseRailOrder(['dm', 'dm', 'users', 'flow']), ['dm', 'flow', 'channels', 'issues', 'topics', 'events', 'people', 'agents', 'boxes', 'calendar', 'archive'])
    /* a legacy nine-tab order (before Boxes) keeps its place, Boxes and Calendar appended */
    assert.deepEqual(parseRailOrder(['channels', 'dm', 'issues', 'topics', 'flow', 'archive', 'events', 'people', 'agents']), ['channels', 'dm', 'issues', 'topics', 'flow', 'events', 'people', 'agents', 'boxes', 'calendar', 'archive'])
    /* a legacy ten-tab order (before Calendar) keeps its place, Calendar appended before Archive */
    assert.deepEqual(parseRailOrder(['boxes', 'agents', 'people', 'events', 'flow', 'topics', 'issues', 'channels', 'dm', 'archive']),
      ['boxes', 'agents', 'people', 'events', 'flow', 'topics', 'issues', 'channels', 'dm', 'calendar', 'archive'])
    /* a stored order is kept exactly, whatever the default is (owner 2026-09-27) - but for Archive */
    const owners = ['channels', 'topics', 'issues', 'dm', 'events', 'flow', 'agents', 'people', 'calendar', 'boxes', 'archive']
    assert.deepEqual(parseRailOrder(owners), owners)
  })
})

/* CLE-77916 (owner, t1 topic 5463df22, 2026-10-01): "its place should be ALWAYS
   at the bottom and it must be the only one which is NOT draggable" */
describe('Archive is always last and never moves', () => {
  it('the default order ends with Archive; every other tab keeps its default place', () => {
    assert.equal(RAIL_PINNED_LAST, 'archive')
    assert.equal(DEFAULT_RAIL_ORDER.at(-1), 'archive')
    /* owner HUM-10 (t1 2b61230c, "A"): Calendar sits with the talk tabs */
    assert.deepEqual([...DEFAULT_RAIL_ORDER], ['channels', 'dm', 'issues', 'topics', 'flow', 'calendar', 'events', 'people', 'agents', 'boxes', 'archive'])
    assert.ok(isRailOrder([...DEFAULT_RAIL_ORDER]), 'the hub still admits the default (a permutation)')
    assert.equal(isRailMovable('archive'), false)
    for (const id of RAIL_IDS.filter((x) => x !== 'archive')) assert.equal(isRailMovable(id), true, id)
  })
  it('a stored order with Archive first or in the middle is drawn with it last, the rest untouched', () => {
    /* the two stored orders on prd, measured 2026-10-01 (humans.rail_order) */
    assert.deepEqual(parseRailOrder(['channels', 'issues', 'topics', 'people', 'agents', 'events', 'boxes', 'dm', 'archive', 'flow']),
      ['channels', 'issues', 'topics', 'people', 'agents', 'events', 'boxes', 'dm', 'flow', 'calendar', 'archive'])
    assert.deepEqual(parseRailOrder(['dm', 'issues', 'topics', 'events', 'archive', 'people', 'agents', 'boxes', 'channels', 'flow']),
      ['dm', 'issues', 'topics', 'events', 'people', 'agents', 'boxes', 'channels', 'flow', 'calendar', 'archive'])
    assert.deepEqual(parseRailOrder(['archive', 'dm', 'channels']).at(-1), 'archive')
    assert.deepEqual(parseRailOrder(['archive', 'dm', 'channels']).slice(0, 2), ['dm', 'channels'])
  })
  it('an old saved order plus a tab added since: the new tab is appended, Archive stays after it', () => {
    assert.deepEqual(parseRailOrder(['flow', 'archive', 'dm']), ['flow', 'dm', 'channels', 'issues', 'topics', 'events', 'people', 'agents', 'boxes', 'calendar', 'archive'])
  })
  it('pinRailOrder moves only Archive and never invents it', () => {
    assert.deepEqual(pinRailOrder(['archive', 'dm', 'flow']), ['dm', 'flow', 'archive'])
    assert.deepEqual(pinRailOrder(['dm', 'flow']), ['dm', 'flow'])
  })
  it('a drag or a save that puts Archive anywhere else is saved with it last', async () => {
    const log = []
    const want = ['archive', 'channels', 'dm', 'issues', 'topics', 'flow', 'events', 'people', 'agents', 'boxes', 'calendar']
    const out = await applyRailOrder(want, { current: null, apply: (o) => log.push(o), save: async () => ({ ok: true }) })
    assert.equal(out.value.at(-1), 'archive')
    assert.equal(out.value[0], 'channels')
  })
  it('a stored order with Archive elsewhere is repaired by the next save, even of the same drawn order', async () => {
    const stored = ['channels', 'issues', 'topics', 'people', 'agents', 'events', 'boxes', 'dm', 'archive', 'flow']
    const saved = []
    await applyRailOrder(parseRailOrder(stored), { current: stored, apply: () => {}, save: async (o) => { saved.push(o); return { ok: true } } })
    assert.deepEqual(saved, [parseRailOrder(stored)])
  })
  it('the rail and Settings do not let Archive be dragged or stepped', () => {
    const side = read('src/components/ChannelSidebar.vue')
    assert.match(side, /@pointerdown="item\.movable && railDrag\.down\(/)
    assert.match(side, /normalize: railOrder\.normalize/)
    const set = read('src/components/RailOrderSetting.vue')
    assert.equal((set.match(/v-if="item\.movable"/g) || []).length, 3, 'grip, up and down')
    assert.match(set, /normalize: rail\.normalize/)
    assert.match(set, /:disabled="i === lastMovable/)
  })
})

/* CLE-77916: the phone strip is a ROW; measured on clientY every sideways
   press-and-move dropped the tab at the first or the last index */
describe('dragAxis', () => {
  const box = (left, top) => ({ left, top, width: 60, height: 52 })
  it('a column is y, a row is x, a right-to-left row is x with sign -1', () => {
    assert.deepEqual(dragAxis([box(0, 0), box(0, 52), box(0, 104)]), { axis: 'y', sign: 1 })
    assert.deepEqual(dragAxis([box(0, 0), box(60, 0), box(120, 0)]), { axis: 'x', sign: 1 })
    assert.deepEqual(dragAxis([box(120, 0), box(60, 0), box(0, 0)]), { axis: 'x', sign: -1 })
    assert.deepEqual(dragAxis([box(0, 0)]), { axis: 'y', sign: 1 })
  })
  it('on a row a sideways move by one tab moves one place, not to an end', () => {
    const rects = [0, 60, 120, 180, 240].map((l) => box(l, 0))
    const { axis, sign } = dragAxis(rects)
    const mids = rects.map((r) => sign * (axis === 'x' ? r.left + r.width / 2 : r.top + r.height / 2))
    /* finger on tab 2 (x 150) moves 65 px right, past tab 3's middle: index 3 */
    assert.equal(dropIndex(mids, 2, 215), 3)
    assert.equal(dropIndex(mids, 2, 150), 2)
  })
})

describe('moves', () => {
  it('moveTo / moveBy clamp at both ends and never lose a tab', () => {
    assert.deepEqual(moveTo(RAIL_IDS, 'events', 0), ['events', 'channels', 'dm', 'issues', 'topics', 'flow', 'archive', 'people', 'agents', 'boxes', 'calendar'])
    assert.deepEqual(moveTo(RAIL_IDS, 'channels', 99), ['dm', 'issues', 'topics', 'flow', 'archive', 'events', 'people', 'agents', 'boxes', 'calendar', 'channels'])
    assert.deepEqual(moveBy(RAIL_IDS, 'channels', -1), [...RAIL_IDS])
    assert.deepEqual(moveBy(RAIL_IDS, 'issues', -1), ['channels', 'issues', 'dm', 'topics', 'flow', 'archive', 'events', 'people', 'agents', 'boxes', 'calendar'])
    assert.deepEqual(moveBy(RAIL_IDS, 'calendar', 1), [...RAIL_IDS])
    assert.ok(isRailOrder(moveBy(RAIL_IDS, 'flow', 1)))
    assert.deepEqual(moveTo(RAIL_IDS, 'users', 0), [...RAIL_IDS])
  })
  it('dropIndex counts the other items whose middle the pointer passed', () => {
    const mids = [10, 30, 50, 70, 90, 110]
    assert.equal(dropIndex(mids, 0, 5), 0)
    assert.equal(dropIndex(mids, 0, 55), 2)
    assert.equal(dropIndex(mids, 0, 500), 5)
    assert.equal(dropIndex(mids, 5, 0), 0)
    assert.equal(dropIndex(mids, 2, 50), 2)
  })
  it('a press is a drag only past the threshold, so a click never reorders', () => {
    assert.ok(DRAG_THRESHOLD_PX >= 4)
    assert.equal(isDrag(0, 0), false)
    assert.equal(isDrag(3, 3), false)
    assert.equal(isDrag(0, DRAG_THRESHOLD_PX), true)
    assert.equal(sameOrder(RAIL_IDS, [...RAIL_IDS]), true)
  })
})

describe('applyRailOrder', () => {
  const rig = (ok) => {
    const log = []
    return {
      log,
      io: (current) => ({
        current,
        apply: (o) => log.push(['apply', o]),
        save: async (o) => { log.push(['save', o]); if (ok === 'throw') throw new Error('net'); return { ok } },
      }),
    }
  }
  const rev = ['calendar', 'boxes', 'agents', 'people', 'events', 'flow', 'topics', 'issues', 'channels', 'dm', 'archive']
  it('mirrors at once, then saves', async () => {
    const r = rig(true)
    assert.deepEqual(await applyRailOrder(rev, r.io(null)), { ok: true, value: rev })
    assert.deepEqual(r.log, [['apply', rev], ['save', rev]])
  })
  it('a refusal or a network error puts the old order back', async () => {
    for (const how of [false, 'throw']) {
      const r = rig(how)
      const out = await applyRailOrder(rev, r.io(null))
      assert.equal(out.ok, false)
      assert.deepEqual(r.log.at(-1), ['apply', null])
    }
  })
  it('a refused save puts a legacy six-id order back as it was', async () => {
    const legacy = ['events', 'flow', 'topics', 'issues', 'channels', 'dm']
    const r = rig(false)
    await applyRailOrder(rev, r.io(legacy))
    assert.deepEqual(r.log.at(-1), ['apply', legacy])
  })
  it('null goes back to the default; an invalid or unchanged order saves nothing', async () => {
    const r = rig(true)
    assert.equal((await applyRailOrder(null, r.io(rev))).ok, true)
    assert.deepEqual(r.log, [['apply', null], ['save', null]])
    const q = rig(true)
    assert.equal((await applyRailOrder(['dm'], q.io(null))).ok, false)
    assert.equal((await applyRailOrder(rev, q.io(rev))).ok, true)
    assert.equal((await applyRailOrder(null, q.io(null))).ok, true)
    assert.deepEqual(q.log, [])
  })
})

describe('wiring', () => {
  it('Archive (SPL-983) is a page tab: /archive picks it, a click opens /archive', async () => {
    const { tabForPath, ARCHIVE_TAB } = await import('../../src/utils/sidebar-tabs.mjs')
    assert.equal(ARCHIVE_TAB, 'archive')
    assert.equal(tabForPath('/archive'), 'archive')
    assert.equal(tabForPath('/fi/archive'), 'archive')
    const src = read('src/components/ChannelSidebar.vue')
    assert.match(src, /next === ARCHIVE_TAB && tabForPath\(route\.path\) !== ARCHIVE_TAB\) await navigateTo\(localePath\('\/archive'\)\)/)
    assert.match(src, /id !== ARCHIVE_TAB && id !== PEOPLE_TAB && id !== AGENTS_TAB && id !== BOXES_TAB && id !== CALENDAR_TAB\) sidePane\.setCurrent\(id\)/)
    assert.ok(read('src/pages/archive.vue').length > 0)
  })
  it('Calendar (spec 089 T007) is a page tab: /calendar picks it, a click opens /calendar, the sidebar keeps the rail only', async () => {
    const { tabForPath, routeForTab, CALENDAR_TAB } = await import('../../src/utils/sidebar-tabs.mjs')
    const { isSectionPage } = await import('../../src/utils/section-strip.mjs')
    assert.equal(CALENDAR_TAB, 'calendar')
    assert.equal(tabForPath('/calendar'), 'calendar')
    assert.equal(tabForPath('/fi/calendar'), 'calendar')
    assert.equal(routeForTab('calendar'), '/calendar')
    assert.equal(isSectionPage('/calendar'), true)
    const src = read('src/components/ChannelSidebar.vue')
    assert.match(src, /next === CALENDAR_TAB && tabForPath\(route\.path\) !== CALENDAR_TAB\) await navigateTo\(localePath\('\/calendar'\)\)/)
    assert.match(src, /const calendarRailOnly = computed\(\(\) => tab\.value === CALENDAR_TAB\)/)
    assert.match(src, /'sidebar--rail': issuesRailOnly \|\| calendarRailOnly/)
    assert.ok(read('src/pages/calendar.vue').length > 0)
  })
  it('the rail draws the stored order and drags through useDragReorder; no Users icon (owner 2026-09-28)', () => {
    const src = read('src/components/ChannelSidebar.vue')
    assert.match(src, /useRailOrder\(\)/)
    assert.match(src, /useDragReorder<RailId>\(/)
    assert.match(src, /@pointerdown="item\.movable && railDrag\.down\(\$event, item\.id as RailId\)"/)
    // rail is RAIL, minus the DM tab while acting as a member (specs/054)
    assert.match(src, /const rail = computed\(\(\) => \(acting\.value \? RAIL\.value\.filter\(\(item\) => item\.id !== 'dm'\) : RAIL\.value\)\)/)
    assert.doesNotMatch(src, /id: USERS_TAB/)
  })
  it('Settings -> Behaviour lists the same order with up / down and a reset', () => {
    assert.match(read('src/components/settings/behaviour.vue'), /<RailOrderSetting/)
    const s = read('src/components/RailOrderSetting.vue')
    assert.match(s, /useRailOrder\(\)/)
    assert.match(s, /useDragReorder<RailId>\(/)
    assert.match(s, /rail-order-up-/)
    assert.match(s, /rail-order-down-/)
    assert.match(s, /store\(null\)/)
  })
  it('the drag swallows only the click that ends a drag', () => {
    const s = read('src/composables/useDragReorder.ts')
    assert.match(s, /if \(!dragged\) return\s+swallowClick\(\)/)
  })
})

// CLE-77904 (owner, t1 topic cb12574f): "Change the name of the mobile app
// from Direct Messages to just Messages." Phones only; desktop keeps its name.
describe('railLabelKey', () => {
  const dm = RAIL_TABS.find((t) => t.id === 'dm')
  it('names the DM section "Messages" on a phone and "Direct messages" above 820 px', () => {
    assert.equal(railLabelKey(dm, true), 'sidebar.messages')
    assert.equal(railLabelKey(dm, false), 'sidebar.direct_messages')
  })
  it('leaves every other tab its one name', () => {
    for (const tab of RAIL_TABS.filter((t) => t.id !== 'dm')) {
      assert.equal(railLabelKey(tab, true), tab.labelKey, tab.id)
      assert.equal(railLabelKey(tab, false), tab.labelKey, tab.id)
    }
  })
  it('every catalogue has a phone name shorter than its desktop name', () => {
    const codes = ['en', 'bg', 'el', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']
    for (const code of codes) {
      const side = JSON.parse(readFileSync(join(WUI, 'i18n/locales', code + '.json'), 'utf8')).sidebar
      assert.equal(typeof side.messages, 'string', code)
      assert.ok(side.messages.length > 0 && side.messages.length < side.direct_messages.length, code)
    }
    const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8')).sidebar
    assert.equal(en.messages, 'Messages')
  })
  it('the sidebar and the Settings list name the tab through it', () => {
    const side = readFileSync(join(WUI, 'src/components/ChannelSidebar.vue'), 'utf8')
    assert.match(side, /railLabelKey\(/)
    assert.match(side, /\{\{ t\(dmLabelKey\) \}\}/)
    assert.doesNotMatch(side, /\{\{ t\('sidebar\.direct_messages'\) \}\}/)
    assert.match(readFileSync(join(WUI, 'src/components/RailOrderSetting.vue'), 'utf8'), /railLabelKey\(/)
  })
})
