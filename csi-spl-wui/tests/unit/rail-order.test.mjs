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
} from '../../src/utils/rail-order.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('rail ids', () => {
  it('seven tabs in the new-member order (owner 2026-09-27): Channels first, the Event log last', () => {
    assert.deepEqual([...RAIL_IDS], ['channels', 'dm', 'issues', 'topics', 'flow', 'archive', 'events'])
    assert.deepEqual(RAIL_TABS.map((t) => t.icon), ['hash', 'messages', 'issues', 'list', 'waves', 'archive', 'history'])
  })
  it('the hub (auth.RailTabs) and rdb 0064 hold the same list', () => {
    const go = read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go')
    /* SPL-983: the hub already admits archive (rdb 0064) before the rail draws it */
    const hub = JSON.parse('[' + /RailTabs = \[\]string\{([^}]*)\}/.exec(go)[1] + ']')
    assert.deepEqual(hub, [...RAIL_IDS])
    const sql = read('../csi-spl-rdb/src/sql/postgres/spool-hub/0064_human_rail_order_archive.sql')
    assert.match(sql, /ARRAY\['dm','channels','issues','topics','flow','events','archive'\]/)
  })
  it('only a permutation of the seven is sent; the drawn order is tolerant', () => {
    assert.ok(isRailOrder(['archive', 'events', 'flow', 'topics', 'issues', 'channels', 'dm']))
    for (const bad of [null, [], ['dm'], ['events', 'flow', 'topics', 'issues', 'channels', 'dm'], [...RAIL_IDS, 'users'], 'dm']) {
      assert.equal(isRailOrder(bad), false, JSON.stringify(bad))
    }
    for (const none of [null, [], 'dm', ['users']]) assert.deepEqual(parseRailOrder(none), [...RAIL_IDS])
    /* SPL-983: an order stored before Archive keeps its place, Archive appended */
    assert.deepEqual(parseRailOrder(['topics', 'dm', 'channels', 'issues', 'flow', 'events']), ['topics', 'dm', 'channels', 'issues', 'flow', 'events', 'archive'])
    assert.deepEqual(parseRailOrder(['dm', 'dm', 'users', 'flow']), ['dm', 'flow', 'channels', 'issues', 'topics', 'archive', 'events'])
    /* a stored order is kept exactly, whatever the default is (owner 2026-09-27) */
    const owners = ['channels', 'topics', 'issues', 'dm', 'events', 'flow', 'archive']
    assert.deepEqual(parseRailOrder(owners), owners)
  })
})

describe('moves', () => {
  it('moveTo / moveBy clamp at both ends and never lose a tab', () => {
    assert.deepEqual(moveTo(RAIL_IDS, 'events', 0), ['events', 'channels', 'dm', 'issues', 'topics', 'flow', 'archive'])
    assert.deepEqual(moveTo(RAIL_IDS, 'channels', 99), ['dm', 'issues', 'topics', 'flow', 'archive', 'events', 'channels'])
    assert.deepEqual(moveBy(RAIL_IDS, 'channels', -1), [...RAIL_IDS])
    assert.deepEqual(moveBy(RAIL_IDS, 'issues', -1), ['channels', 'issues', 'dm', 'topics', 'flow', 'archive', 'events'])
    assert.deepEqual(moveBy(RAIL_IDS, 'events', 1), [...RAIL_IDS])
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
  const rev = ['archive', 'events', 'flow', 'topics', 'issues', 'channels', 'dm']
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
    assert.match(src, /id !== ARCHIVE_TAB\) sidePane\.setCurrent\(id\)/)
    assert.ok(read('src/pages/archive.vue').length > 0)
  })
  it('the rail draws the stored order and drags through useDragReorder; Users is not movable', () => {
    const src = read('src/components/ChannelSidebar.vue')
    assert.match(src, /useRailOrder\(\)/)
    assert.match(src, /useDragReorder<RailId>\(/)
    assert.match(src, /@pointerdown="item\.id !== USERS_TAB && railDrag\.down\(/)
    assert.match(src, /\.\.\.RAIL\.value, \{ id: USERS_TAB/)
  })
  it('Settings -> Behaviour lists the same order with up / down and a reset', () => {
    assert.match(read('src/pages/settings/behaviour.vue'), /<RailOrderSetting/)
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
