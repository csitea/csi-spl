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

// Owner, topic 07b84fd7: "default shuold be browser zone , but the uesrs should
// be able to overwrite it by their personal settings , PER TENANT".
import { setTimeZoneSource, viewerTimeZone } from '../../src/utils/date-iso.mjs'
import { bodyTimeRuns, hasBodyTime } from '../../src/utils/body-times.mjs'

describe('a picked zone (per workspace) wins over the browser\'s', () => {
  const withZone = (zone, fn) => { setTimeZoneSource(() => zone); try { return fn() } finally { setTimeZoneSource(() => '') } }
  it('the browser runs in UTC, the person picked Europe/Helsinki: every clock reads Helsinki', () => {
    inZone('UTC', () => withZone('Europe/Helsinki', () => {
      assert.equal(viewerTimeZone(), 'Europe/Helsinki')
      assert.equal(formatTopicTs(TS, SENT), '2026-10-01 21:46:26 sent 7s')
      assert.equal(formatTs(TS), '21:46')
      assert.equal(formatMsgListTs(TS), '2026-10-01 21:46')
      assert.equal(isoDateTimeSec(TS), '2026-10-01 21:46:26')
    }))
  })
  it('the browser runs in Helsinki, the person picked UTC: every clock reads UTC', () => {
    inZone('Europe/Helsinki', () => withZone('UTC', () => {
      assert.equal(formatTopicTs(TS, SENT), '2026-10-01 18:46:26 sent 7s')
      assert.equal(phoneCardTime(formatMsgListTs(TS), TS, SENT), '18:46')
    }))
  })
  it('no pick, or a zone this browser does not know: the browser\'s zone', () => {
    inZone('Europe/Helsinki', () => {
      assert.equal(viewerTimeZone(), '')
      assert.equal(formatTs(TS), '21:46')
      withZone('Mars/Olympus_Mons', () => {
        assert.equal(viewerTimeZone(), '')
        assert.equal(formatTs(TS), '21:46')
      })
    })
  })
  it('the day rolls over in the picked zone, not the browser\'s', () => {
    inZone('UTC', () => withZone('Europe/Helsinki', () => {
      assert.equal(isoDateTime('2026-10-01T22:30:00Z'), '2026-10-02 01:30')
    }))
  })
})

describe('times written inside a message body (requirements 2 + 5)', () => {
  const body = 'done at 2026-10-01T18:46:26Z, heartbeat 18:46, log 2026-10-01 18:46'
  const localised = (zone) => inZone(zone, () => bodyTimeRuns(body))
  it('an ISO time with Z reads 3 h apart under Europe/Helsinki and UTC', () => {
    assert.deepEqual(localised('UTC')[1], { text: '2026-10-01 18:46:26', iso: '2026-10-01T18:46:26Z' })
    assert.deepEqual(localised('Europe/Helsinki')[1], { text: '2026-10-01 21:46:26', iso: '2026-10-01T18:46:26Z' })
  })
  it('an offset form is the same instant', () => {
    inZone('Europe/Helsinki', () => {
      assert.equal(bodyTimeRuns('2026-10-01T21:46:26+03:00')[0].text, '2026-10-01 21:46:26')
      assert.equal(bodyTimeRuns('2026-10-01T18:46+0000')[0].text, '2026-10-01 21:46')
    })
  })
  it('CONTROL: a bare time or a time with no zone is left exactly as written', () => {
    for (const zone of ['UTC', 'Europe/Helsinki']) {
      const runs = localised(zone)
      assert.equal(runs.length, 3)
      assert.equal(runs[2].text, ', heartbeat 18:46, log 2026-10-01 18:46')
      assert.equal(runs[2].iso, undefined)
    }
    assert.equal(hasBodyTime('heartbeat 18:46'), false)
    assert.equal(hasBodyTime('2026-10-01 18:46'), false)
    assert.equal(hasBodyTime('2026-10-01T18:46'), false)
    assert.deepEqual(bodyTimeRuns('build-2026-10-01T18:46:26Z'), [{ text: 'build-2026-10-01T18:46:26Z' }])
  })
  it('the renderers use it: MessageRuns text runs, MarkdownBlock text, the event log hover', () => {
    const runs = readFileSync(join(SRC, 'components/MessageRuns.vue'), 'utf8')
    assert.match(runs, /bodyTimeRuns\(p\.text, bodyAt\(\), labelMod\?\.withShortTimes\)/)
    assert.match(runs, /<time v-if="tr\.iso"[^>]*:datetime="tr\.dt \|\| tr\.iso"[^>]*:title="tr\.iso"/)
    assert.match(readFileSync(join(SRC, 'components/MarkdownBlock.vue'), 'utf8'), /hasBodyTime\(s\)/)
    const ev = readFileSync(join(SRC, 'pages/events.vue'), 'utf8')
    assert.match(ev, /<time :datetime="utcOf\(r\) \|\| undefined" :title="utcOf\(r\) \|\| undefined"/)
    assert.match(readFileSync(join(SRC, 'app.vue'), 'utf8'), /setTimeZoneSource\(\(\) => String\(session\.claims\?\.time_zone \|\| ''\)\)/)
  })
})

// Owner HUM-10, t1 179ef3f9 (msgs aed5827e + 0fca98d5): "Drill 5 has started:
// sat reboots at about 07:05:30Z" -> "convert each one of those times by the
// agents to the time zone of the user reading". Format = the owner's answers
// (msg 4da3a44d): 1c reader clock + zone, then "(UTC as written)"; 2 another
// day than the post's = "yyyy-mm-dd HH:MM"; 3b x = "about" the middle; 4b no marker.
import { parseBody } from '../../src/utils/code-blocks.mjs'
import { withShortTimes } from '../../src/utils/body-times-short.mjs'

describe('short UTC times in a body (07:05:30Z, 10:45Z, 10:4xZ, ranges)', () => {
  const AT = '2026-10-09T06:50:00Z'
  const shown = (zone, text, at = AT) => inZone(zone, () => bodyTimeRuns(text, at, withShortTimes).map((r) => r.text).join(''))
  it('the owner\'s line, for a reader in Europe/Helsinki', () => {
    const line = 'Drill 5 has started: sat reboots at about 07:05:30Z.'
    assert.equal(shown('Europe/Helsinki', line), 'Drill 5 has started: sat reboots at about 10:05:30 EEST (07:05:30 UTC).')
    const run = inZone('Europe/Helsinki', () => bodyTimeRuns(line, AT, withShortTimes))[1]
    assert.deepEqual(run, { text: '10:05:30 EEST (07:05:30 UTC)', iso: '07:05:30Z', dt: '2026-10-09T07:05:30.000Z' })
  })
  it('each form, a +03:00 reader', () => {
    const z = 'Europe/Helsinki'
    assert.equal(shown(z, 'at 10:45Z'), 'at 13:45 EEST (10:45 UTC)')
    assert.equal(shown(z, 'done 10:4xZ'), 'done about 13:45 EEST (about 10:45 UTC)')
    assert.equal(shown(z, 'about 10:4xZ'), 'about 13:45 EEST (about 10:45 UTC)')
    assert.equal(shown(z, 'window 10:15-10:17Z'), 'window 13:15-13:17 EEST (10:15-10:17 UTC)')
    assert.equal(shown(z, 'from 09:53Z..10:23Z'), 'from 12:53..13:23 EEST (09:53..10:23 UTC)')
    assert.equal(shown(z, 'ends 10:45Z.'), 'ends 13:45 EEST (10:45 UTC).')
  })
  it('a +05:30 reader: whole minutes, x = the middle of its ten minutes', () => {
    const z = 'Asia/Kolkata'
    assert.equal(shown(z, '07:05:30Z'), '12:35:30 GMT+5:30 (07:05:30 UTC)')
    assert.equal(shown(z, '10:45Z'), '16:15 GMT+5:30 (10:45 UTC)')
    assert.equal(shown(z, '10:4xZ'), 'about 16:15 GMT+5:30 (about 10:45 UTC)')
  })
  it('a UTC reader sees the same clock, named', () => {
    assert.equal(shown('UTC', '10:45Z'), '10:45 UTC (10:45 UTC)')
  })
  it('another day than the post\'s for the reader: the full date, yyyy-mm-dd HH:MM', () => {
    assert.equal(shown('Europe/Helsinki', 'at 23:30Z', '2026-10-09T20:00:00Z'), 'at 2026-10-10 02:30 EEST (23:30 UTC)')
    assert.equal(shown('America/New_York', 'at 02:00Z', '2026-10-09T05:10:00Z'), 'at 2026-10-08 22:00 EDT (02:00 UTC)')
    assert.equal(shown('Europe/Helsinki', '20:50-21:10Z', '2026-10-09T20:00:00Z'), '23:50-2026-10-10 00:10 EEST (20:50-21:10 UTC)')
    /* the post itself is after midnight for the reader: same day, no date */
    assert.equal(shown('Europe/Helsinki', 'at 22:30Z', '2026-10-09T22:40:00Z'), 'at 01:30 EEST (22:30 UTC)')
  })
  it('the day is the post\'s: the UTC day that puts the time nearest to it', () => {
    const run = inZone('UTC', () => bodyTimeRuns('23:50Z', '2026-10-09T00:10:00Z', withShortTimes)[0])
    assert.equal(run.dt, '2026-10-08T23:50:00.000Z')
    assert.equal(inZone('UTC', () => bodyTimeRuns('00:05Z', '2026-10-09T23:55:00Z', withShortTimes)[0].dt), '2026-10-10T00:05:00.000Z')
  })
  it('CONTROL: a bare 10:45, a non-time and an x with seconds stay as written', () => {
    for (const t of ['bare 10:45', 'v10:45Z', '25:10Z', '10:4x:30Z', 'id ab:45Z']) {
      assert.deepEqual(inZone('Europe/Helsinki', () => bodyTimeRuns(t, AT, withShortTimes)), [{ text: t }], t)
    }
    assert.equal(hasBodyTime('bare 10:45'), false)
    assert.equal(hasBodyTime('at 10:45Z'), true)
  })
  it('CONTROL: no message timestamp (the old call), or the lazy chunk not loaded yet: as written', () => {
    const t = 'reboots at 07:05:30Z, about 10:4xZ, 10:15-10:17Z'
    assert.deepEqual(inZone('Europe/Helsinki', () => bodyTimeRuns(t)), [{ text: t }])
    assert.deepEqual(inZone('Europe/Helsinki', () => bodyTimeRuns(t, undefined, withShortTimes)), [{ text: t }])
    assert.deepEqual(inZone('Europe/Helsinki', () => bodyTimeRuns(t, AT)), [{ text: t }])
  })
  it('the short-time code is a lazy chunk, never a static import of the first paint', () => {
    for (const f of ['components/MessageRuns.vue', 'components/MarkdownBlock.vue', 'components/MessageBody.vue', 'utils/body-times.mjs']) {
      assert.doesNotMatch(readFileSync(join(SRC, f), 'utf8'), /^import[^\n]*body-times-short/m, f)
    }
    assert.match(readFileSync(join(SRC, 'utils/app-link-label.mjs'), 'utf8'), /^export \{ withShortTimes \} from '\.\/body-times-short\.mjs'$/m)
    assert.match(readFileSync(join(SRC, 'composables/useAppLinkLabel.ts'), 'utf8'), /import\('~\/utils\/app-link-label\.mjs'\)/)
  })
  it('inside `code` and a code block a short time is untouched', () => {
    const blocks = parseBody('run `date` at `10:45Z` then 10:45Z\n```\nlog 07:05:30Z\n```')
    const parts = blocks.flatMap((b) => b.parts || [])
    assert.ok(parts.some((p) => p.type === 'inline' && p.text === '10:45Z'))
    assert.equal(blocks.find((b) => b.type === 'code').text.trim(), 'log 07:05:30Z')
    const runs = readFileSync(join(SRC, 'components/MessageRuns.vue'), 'utf8')
    assert.match(runs, /<code v-if="p\.type === 'inline'" class="code-inline">\{\{ p\.text \}\}<\/code>/)
  })
  it('an ISO time beside a short one: each converted once', () => {
    assert.equal(shown('Europe/Helsinki', '2026-10-09T07:05Z and 07:05Z'), '2026-10-09 10:05 and 10:05 EEST (07:05 UTC)')
  })
  it('MessageCard hands the message timestamp to its body; no marker on the time (4b)', () => {
    assert.match(readFileSync(join(SRC, 'components/MessageCard.vue'), 'utf8'), /<MessageBody v-else :body="String\(msg\.body \|\| ''\)" :at="msg\.ts"/)
    assert.match(readFileSync(join(SRC, 'components/MessageBody.vue'), 'utf8'), /provide\(BODY_TIME_AT, \(\) => props\.at\)/)
    assert.doesNotMatch(readFileSync(join(SRC, 'components/MessageRuns.vue'), 'utf8'), /underline dotted/)
  })
})
