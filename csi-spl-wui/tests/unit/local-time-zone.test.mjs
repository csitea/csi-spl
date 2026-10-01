// CLE-77908 (owner, t1 b23639e2, 2026-10-01): "why the times of the sent seem
// so off" / "off by 3hours". The desktop topic pane (`... sent 7s`) and the
// desktop home topic rows printed UTC; a viewer in Helsinki (UTC+3 in
// summer) read every time three hours early. Every message / topic clock now
// prints the viewer's own wall clock: the same instant renders 3 h apart under
// TZ=Europe/Helsinki and TZ=UTC.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { formatAbsTs, formatMsgListTs, formatTopicTs, formatTs, phoneCardTime } from '../../src/utils/channel-feed.mjs'
import { isoClock, isoDateTime, isoDateTimeSec } from '../../src/utils/date-iso.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const TS = '2026-10-01T18:46:26Z'
const SENT = Date.parse('2026-10-01T18:46:33Z')

/* Node re-reads process.env.TZ on assignment */
function inZone(zone, fn) {
  const tz0 = process.env.TZ
  process.env.TZ = zone
  try { return fn() } finally { if (tz0 === undefined) delete process.env.TZ; else process.env.TZ = tz0 }
}
const render = () => ({
  topicPane: formatTopicTs(TS, SENT),
  abs: formatAbsTs(TS),
  homeRow: formatTs(TS, 'fi'),
  list: formatMsgListTs(TS),
  phone: phoneCardTime(formatTopicTs(TS, SENT), TS, SENT),
  clock: isoClock(TS),
  dt: isoDateTime(TS),
  dts: isoDateTimeSec(TS),
})

describe('every clock is the viewer\'s local time (CLE-77908)', () => {
  it('UTC: the stored instant as written', () => {
    assert.deepEqual(inZone('UTC', render), {
      topicPane: '2026-10-01 18:46:26 sent 7s',
      abs: '2026-10-01 18:46:26',
      homeRow: '18:46',
      list: '2026-10-01 18:46',
      phone: '18:46',
      clock: '18:46',
      dt: '2026-10-01 18:46',
      dts: '2026-10-01 18:46:26',
    })
  })
  it('Europe/Helsinki (EEST, UTC+3): the same instant 3 h later on every surface', () => {
    assert.deepEqual(inZone('Europe/Helsinki', render), {
      topicPane: '2026-10-01 21:46:26 sent 7s',
      abs: '2026-10-01 21:46:26',
      homeRow: '21:46',
      list: '2026-10-01 21:46',
      phone: '21:46',
      clock: '21:46',
      dt: '2026-10-01 21:46',
      dts: '2026-10-01 21:46:26',
    })
  })
  it('the two zones differ by exactly 3 h on the topic pane and the home row', () => {
    const hel = inZone('Europe/Helsinki', render)
    const utc = inZone('UTC', render)
    const h = (s) => Number(s.match(/(\d{2}):\d{2}/)[1])
    for (const k of ['topicPane', 'homeRow', 'list', 'dts']) assert.equal(h(hel[k]) - h(utc[k]), 3, k)
  })
  it('CONTROL: a value that is not a time passes through untouched', () => {
    inZone('Europe/Helsinki', () => {
      assert.equal(formatTs('not a date'), 'not a date')
      assert.equal(formatAbsTs('not a date'), 'not a date')
      assert.equal(formatTopicTs('not a date', 1), 'not a date')
    })
  })
  it('no display formatter slices a UTC clock out of an ISO string', () => {
    const feed = readFileSync(join(SRC, 'utils/channel-feed.mjs'), 'utf8')
    const debug = readFileSync(join(SRC, 'components/common/DebugPanel.vue'), 'utf8')
    assert.doesNotMatch(feed, /toISOString\(\)\.slice\((?:11|0, ?1[69])/)
    assert.doesNotMatch(debug, /\.replace\('T', ' '\)/)
  })
})
