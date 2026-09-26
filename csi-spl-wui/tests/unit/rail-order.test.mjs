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
  it('six tabs in the default order the rail had before SPL-979', () => {
    assert.deepEqual([...RAIL_IDS], ['dm', 'channels', 'issues', 'topics', 'flow', 'events'])
    assert.deepEqual(RAIL_TABS.map((t) => t.icon), ['messages', 'hash', 'issues', 'list', 'waves', 'history'])
  })
  it('the hub (auth.RailTabs) and rdb 0063 hold the same list', () => {
    const go = read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go')
    /* SPL-983: the hub already admits archive (rdb 0064) before the rail draws it */
    const hub = JSON.parse('[' + /RailTabs = \[\]string\{([^}]*)\}/.exec(go)[1] + ']')
    assert.ok([JSON.stringify([...RAIL_IDS]), JSON.stringify([...RAIL_IDS, 'archive'])].includes(JSON.stringify(hub)), JSON.stringify(hub))
    const sql = read('../csi-spl-rdb/src/sql/postgres/spool-hub/0063_human_rail_order.sql')
    assert.match(sql, /ARRAY\['dm','channels','issues','topics','flow','events'\]/)
  })
  it('only a permutation is an order; anything else parses to the default', () => {
    assert.ok(isRailOrder(['events', 'flow', 'topics', 'issues', 'channels', 'dm']))
    for (const bad of [null, [], ['dm'], ['dm', 'dm', 'issues', 'topics', 'flow', 'events'], [...RAIL_IDS, 'users'], ['dm', 'channels', 'issues', 'topics', 'flow', 'users'], 'dm']) {
      assert.equal(isRailOrder(bad), false, JSON.stringify(bad))
      assert.deepEqual(parseRailOrder(bad), [...RAIL_IDS])
    }
    assert.deepEqual(parseRailOrder(['topics', 'dm', 'channels', 'issues', 'flow', 'events']), ['topics', 'dm', 'channels', 'issues', 'flow', 'events'])
  })
})

describe('moves', () => {
  it('moveTo / moveBy clamp at both ends and never lose a tab', () => {
    assert.deepEqual(moveTo(RAIL_IDS, 'events', 0), ['events', 'dm', 'channels', 'issues', 'topics', 'flow'])
    assert.deepEqual(moveTo(RAIL_IDS, 'dm', 99), ['channels', 'issues', 'topics', 'flow', 'events', 'dm'])
    assert.deepEqual(moveBy(RAIL_IDS, 'dm', -1), [...RAIL_IDS])
    assert.deepEqual(moveBy(RAIL_IDS, 'issues', -1), ['dm', 'issues', 'channels', 'topics', 'flow', 'events'])
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
  const rev = ['events', 'flow', 'topics', 'issues', 'channels', 'dm']
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
