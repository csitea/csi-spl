// Spec 164 row B6 (SPL-5560): a channel's box pins in the WUI. Owner HUM-10
// (t1 021d4921, msg 6b6d092c): "by default any channel should run on any
// box from the cluster , but one should be able to fix only certain boxes
// for a channel". The client reads the workspace's boxes (GET /v1/pins) and
// a channel's pins, and saves them with PUT { box_pins }; Workspace settings
// -> Channels shows "Any box" for an unpinned channel. The browser half is
// tests/e2e/tenant-channel-box-pins.test.mjs.
//
// Red controls (each turns this file red; restored -> green):
//   - setChannelBoxPins sends a body without box_pins  -> "the PUT carries box_pins"
//   - listPins is missing from the lazy client          -> "listPins is a lazy client method"
//   - listPins drops its upload token (live('/v1/pins')) -> "listPins sends the upload token" and
//     "a live client sends GET /v1/pins with the upload token, not the view token" (R7 W1)
//   - tenantChannelBoxPins returns null                  -> "an admin reads a channel's pins from the tenant list" (R7 W2)
// Run: node tests/unit/channel-box-pins.test.mjs
import { readFileSync } from 'node:fs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'
import { lazySpoolMethods } from '../../src/utils/spool-client-lazy.mjs'
import {
  boxIdsOf,
  channelBoxChoices,
  channelBoxPinsBody,
  channelBoxPinsErrorKey,
  normalizeChannelBoxPins,
  normalizeTenantChannels,
  tenantChannelBoxPins,
  workspaceBoxIds,
} from '../../src/utils/tenant-settings.mjs'
import { createMockTenant } from '../../src/utils/tenant-settings-mock.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const raises = (fn, status, token) => { try { fn(); return false } catch (e) { return e.status === status && e.token === token } }
const read = (p) => readFileSync(new URL('../../' + p, import.meta.url), 'utf8')

console.log('channel-box-pins')

/* ---- the client: three lazy calls on the hub routes of row B2 ---- */
const calls = []
const ctx = { mock: false, live: async (path, opts = {}) => { calls.push({ path, opts }); return { ok: true } } }
ok('listPins is a lazy client method', typeof lazySpoolMethods.listPins === 'function')
ok('getChannelBoxPins and setChannelBoxPins are lazy client methods',
  typeof lazySpoolMethods.getChannelBoxPins === 'function' && typeof lazySpoolMethods.setChannelBoxPins === 'function')
const stubs = read('src/utils/spool-client.mjs')
ok('the first-load client has a stub for each (LAZY_METHODS)', ['listPins', 'getChannelBoxPins', 'setChannelBoxPins'].every((n) => stubs.includes(`'${n}',`)))

if (lazySpoolMethods.listPins) await lazySpoolMethods.listPins(ctx)
ok('listPins reads GET /v1/pins', calls.at(-1)?.path === '/v1/pins' && !calls.at(-1)?.opts?.method, JSON.stringify(calls.at(-1)))
if (lazySpoolMethods.listPins) await lazySpoolMethods.listPins(ctx, 'up-tok')
ok('listPins sends the upload token', calls.at(-1)?.opts?.headers?.authorization === 'Bearer up-tok', JSON.stringify(calls.at(-1)))

/* R7 W1: the hub serves GET /v1/pins only to the WS upload token (tokenTenant
   -> bearerAny), so the credential is checked on the real client's fetch, not
   on the mock. The view token still rides on every other call. */
const seen = []
const hubFetch = async (url, opts = {}) => {
  seen.push({ url, auth: opts.headers?.authorization || '' })
  return { ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => ({ pins: [], box_pins: [] }) }
}
const client = createSpoolClient({ fetchFn: hubFetch, mock: false, token: 'view-tok' })
await client.listPins('up-tok')
const pinsCall = seen.find((c) => c.url.endsWith('/v1/pins'))
ok('a live client sends GET /v1/pins with the upload token, not the view token', pinsCall?.auth === 'Bearer up-tok', JSON.stringify(seen))
await client.getChannelBoxPins('design')
ok('the channel GET keeps the view token', seen.at(-1)?.url.endsWith('/v1/channels/design/box-pins') && seen.at(-1)?.auth === 'Bearer view-tok', JSON.stringify(seen.at(-1)))
await lazySpoolMethods.getChannelBoxPins(ctx, 'team a')
ok('getChannelBoxPins reads GET /v1/channels/{ch}/box-pins (encoded)', calls.at(-1)?.path === '/v1/channels/team%20a/box-pins' && !calls.at(-1)?.opts.method, JSON.stringify(calls.at(-1)))
await lazySpoolMethods.setChannelBoxPins(ctx, 'design', ['box-b', 'box-a'])
const put = calls.at(-1)
let putBody = null
try { putBody = JSON.parse(put?.opts.body || 'null') } catch { putBody = null }
ok('setChannelBoxPins is a PUT on /v1/channels/{ch}/box-pins', put?.path === '/v1/channels/design/box-pins' && put?.opts.method === 'PUT', JSON.stringify(put))
ok('the PUT carries box_pins', Array.isArray(putBody?.box_pins) && putBody.box_pins.join() === 'box-b,box-a', JSON.stringify(putBody))
await lazySpoolMethods.setChannelBoxPins(ctx, 'design', [])
ok('box_pins [] clears the pin (back to any box)', JSON.parse(calls.at(-1).opts.body).box_pins.length === 0)

/* ---- the body readers ---- */
ok('box ids: trimmed, deduped, sorted, strings only', boxIdsOf([' box-b', 'box-a', 'box-b', 7, '', null]).join() === 'box-a,box-b')
ok('box ids of junk is []', boxIdsOf(undefined).length === 0 && boxIdsOf('box-a').length === 0)
ok('GET /v1/pins -> the workspace box ids', workspaceBoxIds({ pins: [{ box_id: 'box-desk', pubkey: 'x' }, { box_id: 'box-a' }, {}] }).join() === 'box-a,box-desk')
ok('a pins body without pins is []', workspaceBoxIds(null).length === 0 && workspaceBoxIds({}).length === 0)
const unpinned = normalizeChannelBoxPins({ channel: 'design', box_pins: [], is_pinned: false })
ok('no pin = any box', unpinned.pinned === false && unpinned.boxPins.length === 0)
const pinned = normalizeChannelBoxPins({ channel: 'design', box_pins: ['box-b', 'box-a'], is_pinned: true })
ok('a pinned channel reads its boxes', pinned.pinned === true && pinned.boxPins.join() === 'box-a,box-b')
ok('the dialog offers every workspace box plus a pinned box that left it', channelBoxChoices(['box-a', 'box-b'], ['box-gone']).join() === 'box-a,box-b,box-gone')
ok('"Any box" saves box_pins []', channelBoxPinsBody(true, ['box-a']).box_pins.length === 0)
ok('"Only these boxes" saves the ticked boxes', channelBoxPinsBody(false, ['box-b', 'box-a']).box_pins.join() === 'box-a,box-b')
ok('a default channel shows the hub refusal', channelBoxPinsErrorKey({ token: 'channel_default_unpinnable' }) === 'channels.properties.boxes_error.channel_default_unpinnable')
ok('an unknown box shows its refusal', channelBoxPinsErrorKey({ token: 'unknown_box' }) === 'channels.properties.boxes_error.unknown_box')
ok('anything else is the generic line', channelBoxPinsErrorKey(new Error('x')) === 'channels.properties.boxes_error.generic')

/* ---- Workspace settings -> Channels: the Boxes column's data ---- */
const rows = normalizeTenantChannels({ channels: [{ channel: 'design', box_pins: ['box-b', 'box-a'] }, { channel: 'lobby', visibility: 'default' }] })
ok('a tenant channel row carries its boxes', rows.find((r) => r.channel === 'design').boxPins.join() === 'box-a,box-b')
const adminList = { channels: [{ channel: 'secret', box_pins: ['box-desk', 'box-a'] }, { channel: 'open', box_pins: [] }] }
ok("an admin reads a channel's pins from the tenant list", tenantChannelBoxPins(adminList, 'secret')?.join() === 'box-a,box-desk')
ok('an unpinned listed channel is [] and an unlisted one is null', tenantChannelBoxPins(adminList, 'open')?.length === 0 && tenantChannelBoxPins(adminList, 'gone') === null)
const dialog = read('src/components/ChannelPropertiesDialog.vue')
ok('the dialog reads the workspace pins with the upload token', /api\.listPins\(await live\.freshUploadToken\(\)\)/.test(dialog))
ok('the dialog falls back to the tenant list on a 404 for an admin', dialog.includes('api.listTenantChannels()') && dialog.includes('tenantChannelBoxPins('))
ok('a row without box_pins is unpinned (Any box)', rows.find((r) => r.channel === 'lobby').boxPins.length === 0)

/* ---- the mock hub keeps the B2 rules (spec 164 4.1) ---- */
const m = createMockTenant()
ok('the mock lists the workspace boxes', workspaceBoxIds(m.pins()).join() === 'box-a,box-b,box-desk')
ok('the mock refuses a default channel', raises(() => m.setChannelBoxPins('lobby', ['box-a']), 400, 'channel_default_unpinnable'))
ok('the mock refuses a box outside the workspace', raises(() => m.setChannelBoxPins('design', ['box-zz']), 400, 'unknown_box'))
m.setChannelBoxPins('design', ['box-b', 'box-a', 'box-a'])
ok('the mock stores the pins sorted and deduped', m.channelBoxPins('design').box_pins.join() === 'box-a,box-b' && m.channelBoxPins('design').is_pinned === true)
ok('the mock tenant channels show the pins', m.channels().channels.find((c) => c.channel === 'design').box_pins.join() === 'box-a,box-b')
m.setChannelBoxPins('design', [])
ok('the mock clears the pin with []', m.channelBoxPins('design').is_pinned === false && m.channels().channels.find((c) => c.channel === 'design').box_pins.length === 0)
const mockCtx = { mock: true, tenantMock: async () => m }
await lazySpoolMethods.setChannelBoxPins(mockCtx, 'secret', ['box-desk'])
ok('the client mock path stores through the tenant mock', (await lazySpoolMethods.getChannelBoxPins(mockCtx, 'secret')).box_pins.join() === 'box-desk')

/* ---- the UI wires every string to a key ---- */
const en = JSON.parse(read('i18n/locales/en.json'))
const p = en.channels.properties
ok('every Boxes string is a key', ['boxes_label', 'boxes_any', 'boxes_some', 'boxes_none', 'boxes_save', 'boxes_saved', 'boxes_readonly', 'boxes_hint'].every((k) => typeof p[k] === 'string' && p[k]))
ok('every refusal has its line', ['channel_default_unpinnable', 'unknown_box', 'unknown_channel', 'forbidden', 'generic', 'load'].every((k) => typeof p.boxes_error?.[k] === 'string'))
ok('the Channels column keys', typeof en.tenant_settings.col_boxes === 'string' && typeof en.tenant_settings.boxes_any === 'string')

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll channel-box-pins checks passed.')
