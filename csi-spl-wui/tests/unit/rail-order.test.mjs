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
} from '../../src/utils/rail-order.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('rail ids', () => {
  it('ten tabs in the new-member order (CLE-77799 adds Boxes last)', () => {
    assert.deepEqual([...RAIL_IDS], ['channels', 'dm', 'issues', 'topics', 'flow', 'archive', 'events', 'people', 'agents', 'boxes'])
    assert.deepEqual(RAIL_TABS.map((t) => t.icon), ['hash', 'messages', 'issues', 'list', 'waves', 'archive', 'history', 'users', 'bot', 'server'])
  })
  it('the hub (auth.RailTabs) and rdb 0090 hold the same list', () => {
    const go = read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go')
    /* CLE-77799: the hub admits the ten (rdb 0090) as well as the legacy 6 / 7 / 9 */
    const hub = JSON.parse('[' + /\bRailTabs = \[\]string\{([^}]*)\}/.exec(go)[1] + ']')
    assert.deepEqual(hub, [...RAIL_IDS])
    const sql = read('../csi-spl-rdb/src/sql/postgres/spool-hub/0090_human_rail_order_boxes.sql')
    assert.match(sql, /ARRAY\['dm','channels','issues','topics','flow','events','archive','people','agents','boxes'\]/)
  })
  it('only a permutation of the ten is sent; the drawn order is tolerant', () => {
    assert.ok(isRailOrder(['boxes', 'agents', 'people', 'archive', 'events', 'flow', 'topics', 'issues', 'channels', 'dm']))
    for (const bad of [null, [], ['dm'], ['events', 'flow', 'topics', 'issues', 'channels', 'dm'], ['agents', 'people', 'archive', 'events', 'flow', 'topics', 'issues', 'channels', 'dm'], [...RAIL_IDS, 'users'], 'dm']) {
      assert.equal(isRailOrder(bad), false, JSON.stringify(bad))
    }
    for (const none of [null, [], 'dm', ['users']]) assert.deepEqual(parseRailOrder(none), [...RAIL_IDS])
    /* SPL-983 / CLE-77794 / CLE-77799: an order stored before a tab existed keeps
       its place, the tabs added since (archive, people + agents, then boxes) appended */
    assert.deepEqual(parseRailOrder(['topics', 'dm', 'channels', 'issues', 'flow', 'events']), ['topics', 'dm', 'channels', 'issues', 'flow', 'events', 'archive', 'people', 'agents', 'boxes'])
    assert.deepEqual(parseRailOrder(['dm', 'dm', 'users', 'flow']), ['dm', 'flow', 'channels', 'issues', 'topics', 'archive', 'events', 'people', 'agents', 'boxes'])
    /* a legacy nine-tab order (before Boxes) keeps its place, Boxes appended */
    assert.deepEqual(parseRailOrder(['channels', 'dm', 'issues', 'topics', 'flow', 'archive', 'events', 'people', 'agents']), [...RAIL_IDS])
    /* a stored order is kept exactly, whatever the default is (owner 2026-09-27) */
    const owners = ['channels', 'topics', 'issues', 'dm', 'events', 'flow', 'archive', 'agents', 'people', 'boxes']
    assert.deepEqual(parseRailOrder(owners), owners)
  })
})

describe('moves', () => {
  it('moveTo / moveBy clamp at both ends and never lose a tab', () => {
    assert.deepEqual(moveTo(RAIL_IDS, 'events', 0), ['events', 'channels', 'dm', 'issues', 'topics', 'flow', 'archive', 'people', 'agents', 'boxes'])
    assert.deepEqual(moveTo(RAIL_IDS, 'channels', 99), ['dm', 'issues', 'topics', 'flow', 'archive', 'events', 'people', 'agents', 'boxes', 'channels'])
    assert.deepEqual(moveBy(RAIL_IDS, 'channels', -1), [...RAIL_IDS])
    assert.deepEqual(moveBy(RAIL_IDS, 'issues', -1), ['channels', 'issues', 'dm', 'topics', 'flow', 'archive', 'events', 'people', 'agents', 'boxes'])
    assert.deepEqual(moveBy(RAIL_IDS, 'boxes', 1), [...RAIL_IDS])
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
  const rev = ['boxes', 'agents', 'people', 'archive', 'events', 'flow', 'topics', 'issues', 'channels', 'dm']
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
    assert.match(src, /id !== ARCHIVE_TAB && id !== PEOPLE_TAB && id !== AGENTS_TAB && id !== BOXES_TAB\) sidePane\.setCurrent\(id\)/)
    assert.ok(read('src/pages/archive.vue').length > 0)
  })
  it('the rail draws the stored order and drags through useDragReorder; no Users icon (owner 2026-09-28)', () => {
    const src = read('src/components/ChannelSidebar.vue')
    assert.match(src, /useRailOrder\(\)/)
    assert.match(src, /useDragReorder<RailId>\(/)
    assert.match(src, /@pointerdown="railDrag\.down\(\$event, item\.id as RailId\)"/)
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
