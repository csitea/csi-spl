// SPL-1034 (specs/045 §3.8): a person's own Channels order, kept on the hub.
// Run: node tests/unit/channel-order.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { CHANNEL_ORDER_MAX, normalizeChannelOrder } from '../../src/utils/channel-order.mjs'
import { mergeChannelOrder, sameChannelOrder, stepChannelOrder } from '../../src/utils/channel-order-edit.mjs'
import { normalizeMe } from '../../src/utils/access.mjs'
import { pinRows, rowMenuItems } from '../../src/utils/sidebar-row-menu.mjs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const rows = (ids) => ids.map((channel_id) => ({ channel_id }))
const ids = (list) => list.map((c) => c.channel_id)

describe('seeding from GET /v1/view/me', () => {
  it('channel_order null = never set; a list is kept, normalized and deduped', () => {
    assert.equal(normalizeMe({ role: 'admin' }).channelOrder, null)
    assert.equal(normalizeMe({ channel_order: null }).channelOrder, null)
    assert.deepEqual(normalizeMe({ channel_order: ['ops', '#Devel', 'ops', 3, ''] }).channelOrder, ['ops', 'devel'])
    assert.deepEqual(normalizeMe({ channel_order: [] }).channelOrder, [])
  })

  it('normalizeChannelOrder drops junk and keeps the first of duplicates', () => {
    assert.deepEqual(normalizeChannelOrder(null), [])
    assert.deepEqual(normalizeChannelOrder('ops'), [])
    assert.deepEqual(normalizeChannelOrder(['b', 'a', 'B', ' a ']), ['b', 'a'])
  })

  it('rendering: stored ids first, a new channel at the END, a stored id that is gone is not drawn', () => {
    const shown = pinRows(rows(['lobby', 'alerts', 'feedback', 'new-one']), ['feedback', 'gone', 'lobby', 'alerts'], (c) => c.channel_id)
    assert.deepEqual(ids(shown), ['feedback', 'lobby', 'alerts', 'new-one'])
    const never = pinRows(rows(['lobby', 'alerts']), [], (c) => c.channel_id)
    assert.deepEqual(ids(never), ['lobby', 'alerts'], 'never set = today\'s order')
  })
})

describe('the whole displayed list is stored', () => {
  it('a reorder of what is on screen stores every displayed id', () => {
    assert.deepEqual(mergeChannelOrder(['b', 'a', 'c'], []), ['b', 'a', 'c'])
    assert.deepEqual(mergeChannelOrder(['b', 'a', 'c'], ['a']), ['b', 'a', 'c'])
  })

  it('a stored id that is not listed now stays stored, after the id it followed', () => {
    assert.deepEqual(mergeChannelOrder(['b', 'a'], ['x', 'a', 'y', 'b']), ['x', 'b', 'a', 'y'])
    assert.deepEqual(mergeChannelOrder(['a', 'b'], ['x', 'z', 'a', 'b']), ['x', 'z', 'a', 'b'])
  })

  it('dedupes, normalizes and caps at the hub limit', () => {
    assert.deepEqual(mergeChannelOrder(['A', 'a', '#b'], []), ['a', 'b'])
    const many = Array.from({ length: CHANNEL_ORDER_MAX + 5 }, (_, i) => 'c' + i)
    assert.equal(mergeChannelOrder(many, []).length, CHANNEL_ORDER_MAX)
  })

  it('sameChannelOrder compares order, not only members', () => {
    assert.ok(sameChannelOrder(['a', 'b'], ['a', 'b']))
    assert.ok(!sameChannelOrder(['a', 'b'], ['b', 'a']))
    assert.ok(sameChannelOrder(null, []))
  })
})

describe('Move up / Move down', () => {
  it('swaps with the neighbour', () => {
    assert.deepEqual(stepChannelOrder(['a', 'b', 'c'], 'b', -1), ['b', 'a', 'c'])
    assert.deepEqual(stepChannelOrder(['a', 'b', 'c'], 'b', 1), ['a', 'c', 'b'])
  })

  it('no neighbour at the edges, and an unknown id moves nothing', () => {
    assert.equal(stepChannelOrder(['a', 'b', 'c'], 'a', -1), null)
    assert.equal(stepChannelOrder(['a', 'b', 'c'], 'c', 1), null)
    assert.equal(stepChannelOrder(['a'], 'a', 1), null)
    assert.equal(stepChannelOrder(['a', 'b'], 'zz', 1), null)
  })

  it('the channel row menu offers them only when there is a neighbour that way', () => {
    const mid = rowMenuItems(false, { channel: true, moveUp: true, moveDown: true }).map((i) => i.id)
    assert.deepEqual(mid, ['open', 'copy', 'mute', 'move-up', 'move-down'])
    assert.deepEqual(rowMenuItems(false, { channel: true, moveDown: true }).map((i) => i.id), ['open', 'copy', 'mute', 'move-down'])
    assert.deepEqual(rowMenuItems(false, { channel: true, moveUp: true }).map((i) => i.id), ['open', 'copy', 'mute', 'move-up'])
    assert.deepEqual(rowMenuItems(false, { person: true, moveUp: true }).some((i) => i.id === 'move-up'), false, 'a person row never')
    const up = rowMenuItems(false, { channel: true, moveUp: true }).find((i) => i.id === 'move-up')
    assert.equal(up.icon, 'chevron-up')
    assert.equal(up.labelKey, 'sidebar.row_menu.move_up')
  })

  it('only the Channels panel rows pass them (not the Flow channel rows)', () => {
    const vue = src('src/components/ChannelSidebar.vue')
    assert.equal(vue.split(':move-up=').length - 1, 1)
    assert.equal(vue.split(':move-down=').length - 1, 1)
    assert.match(vue, /:move-up="channelIndex > 0"/)
    assert.match(vue, /:move-down="channelIndex < channelRows.length - 1"/)
  })

  it('every locale has the words, and the save failure line keeps {token}', () => {
    const dir = join(WUI, 'i18n/locales')
    for (const code of ['en', 'bg', 'el', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const s = JSON.parse(readFileSync(join(dir, code + '.json'), 'utf8')).sidebar
      assert.ok(s.row_menu.move_up && s.row_menu.move_down, code)
      assert.match(s.channel_order_failed, /\{token\}/, code)
      for (const v of [s.row_menu.move_up, s.row_menu.move_down, s.channel_order_failed]) {
        assert.doesNotMatch(v, /<|@/, code + ' breaks the message compiler')
      }
    }
  })
})

describe('wire (contracts/move-v1.md §7)', () => {
  it('PUT /v1/me/channel-order with the whole list, JSON, no new header', async () => {
    const calls = []
    const fetchFn = async (url, init) => {
      calls.push({ url, init })
      return new Response(JSON.stringify({ channel_order: ['b', 'a'] }), { status: 200, headers: { 'content-type': 'application/json' } })
    }
    const api = createSpoolClient({ mock: false, base: 'https://hub.example.com', fetchFn, token: 'tok' })
    const out = await api.setChannelOrder(['b', 'a'])
    assert.deepEqual(out, { channel_order: ['b', 'a'] })
    assert.equal(calls.length, 1)
    assert.match(calls[0].url, /\/v1\/me\/channel-order$/)
    assert.equal(calls[0].init.method, 'PUT')
    assert.deepEqual(JSON.parse(calls[0].init.body), { channel_order: ['b', 'a'] })
    const names = Object.keys(calls[0].init.headers).map((h) => h.toLowerCase()).sort()
    assert.deepEqual(names, ['accept', 'authorization', 'content-type'])
  })

  it('a hub refusal keeps its token', async () => {
    const fetchFn = async () => new Response(JSON.stringify({ error: 'not_member' }), { status: 404, headers: { 'content-type': 'application/json' } })
    const api = createSpoolClient({ mock: false, base: 'https://hub.example.com', fetchFn, token: 'tok' })
    await assert.rejects(api.setChannelOrder(['a']), (e) => e.status === 404 && e.token === 'not_member')
  })

  it('not a list of strings is refused before it goes out', async () => {
    const api = createSpoolClient({ mock: false, base: 'https://hub.example.com', fetchFn: async () => { throw new Error('sent') }, token: 'tok' })
    await assert.rejects(api.setChannelOrder([1]), (e) => e.token === 'bad_json')
  })
})

describe('the lde mock keeps it across a reload', () => {
  it('PUT stores it, [] clears it', async () => {
    const mem = {}
    globalThis.localStorage = { getItem: (k) => (k in mem ? mem[k] : null), setItem: (k, v) => { mem[k] = String(v) }, removeItem: (k) => { delete mem[k] } }
    try {
      const api = createSpoolClient({ mock: true })
      assert.equal(api.mockChannelOrder(), null)
      assert.deepEqual(await api.setChannelOrder(['alerts', 'Lobby', 'alerts']), { channel_order: ['alerts', 'lobby'] })
      assert.deepEqual(createSpoolClient({ mock: true }).mockChannelOrder(), ['alerts', 'lobby'])
      assert.deepEqual(await api.setChannelOrder([]), { channel_order: null })
      assert.equal(api.mockChannelOrder(), null)
    } finally {
      delete globalThis.localStorage
    }
  })
})

describe('the sidebar wiring', () => {
  it('a channel drag and the menu go through the one save path; creating a channel does not', () => {
    const vue = src('src/components/ChannelSidebar.vue')
    assert.match(vue, /if \(list === 'channels'\) void setChannelOrder\(next\)/)
    assert.match(vue, /stepChannelOrder\(channelRows\.value\.map/)
    const create = vue.slice(vue.indexOf('async function onCreate'), vue.indexOf('async function onCreate') + 2000)
    assert.doesNotMatch(create, /channelOrder|setChannelOrder/)
  })

  it('the save is debounced and optimistic, and a failure goes to the snackbar', () => {
    const ts = src('src/composables/useChannelOrder.ts')
    assert.match(ts, /CHANNEL_ORDER_SAVE_MS = 300/)
    assert.match(ts, /order\.value = next\n/)
    assert.match(ts, /noteError\(/)
    assert.match(ts, /sidebar\.channel_order_failed/)
  })
})

describe('Settings -> Behaviour -> Channel order (owner DM 7fa9656f)', () => {
  it('sits beside Left panel order and shares the one order with the left panel', () => {
    const page = src('src/components/settings/behaviour.vue')
    assert.match(page, /<RailOrderSetting \/>\n\s*<ChannelOrderSetting \/>/)
    const ts = src('src/composables/useChannelOrder.ts')
    assert.match(ts, /useState<string\[\]>\('spool-channel-order'/, 'one order per page, not one per caller')
    const vue = src('src/components/ChannelOrderSetting.vue')
    assert.match(vue, /useChannelOrder\(\)/)
    assert.match(vue, /pinRows\(\s*channel\.ordered,\s*channelOrder\.order\.value/, 'the rows the left panel draws, in its order')
    assert.match(vue, /onDrop: \(next\) => \{ void channelOrder\.set\(next\) \}/)
    assert.match(vue, /channelOrder\.step\(displayed\.value, item\.id|channelOrder\.step\(displayed\.value, id, delta\)/)
    assert.match(vue, /channelOrder\.reset\(\)/)
  })

  it('"Default order" clears the stored list (an empty PUT), not a no-op merge', () => {
    const ts = src('src/composables/useChannelOrder.ts')
    const reset = ts.slice(ts.indexOf('function reset()'), ts.indexOf('function reset()') + 300)
    assert.match(reset, /order\.value = \[\]/)
    assert.match(reset, /flush\(\)/)
  })

  it('label, hint and empty text are translated in every locale', () => {
    const en = JSON.parse(src('i18n/locales/en.json')).settings.channel_order
    for (const loc of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const co = JSON.parse(src(`i18n/locales/${loc}.json`)).settings.channel_order
      for (const k of ['label', 'hint', 'empty']) {
        assert.ok(typeof co?.[k] === 'string' && co[k].trim(), `${loc} settings.channel_order.${k}`)
        if (loc !== 'en') assert.notEqual(co[k], en[k], `${loc} settings.channel_order.${k} is translated`)
      }
    }
  })
})
