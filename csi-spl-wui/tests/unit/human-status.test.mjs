// Spec 096 (manual status, lane L3 / T003): a member's "Busy" or
// "Unavailable until 14:00" - the ring on the dot, the words in the viewer's
// zone, expiry on read (no stale status after a missed clearing frame), the
// `status` frame, the picker's "until" choices and the composer line.
// Run: node --test tests/unit/human-status.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  applyStatusFrame, cleanStatusNote, liveStatus, msToNextExpiry, normalizeHumanStatus, pruneExpired,
  statusController, statusLabel, statusMapFromHumans, statusRing, statusUntilLabel, statusWords,
} from '../../src/utils/human-status.mjs'
import {
  STATUS_UNTIL_CHOICES, composerStatusTargets, defaultUntilChoice, draftMentionIds, parseWallDateTime,
  statusBody, untilFromChoice, untilProblem,
} from '../../src/utils/human-status.mjs'
import { isoDateTime, setTimeZoneSource } from '../../src/utils/date-iso.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const NOW = Date.parse('2026-10-06T10:00:00Z')
const MIN = 60 * 1000

describe('normalize and expiry on read', () => {
  it('available, unknown and junk states are no status', () => {
    for (const raw of [null, undefined, 'busy', {}, { state: 'available' }, { state: 'away' }]) {
      assert.equal(normalizeHumanStatus(raw), null)
    }
  })
  it('keeps state, a cleaned note and the until as UTC ISO', () => {
    assert.deepEqual(normalizeHumanStatus({ state: 'unavailable', note: '  On leave\n', until: '2026-10-07T12:00:00Z' }),
      { state: 'unavailable', note: 'On leave', until: '2026-10-07T12:00:00.000Z' })
    assert.deepEqual(normalizeHumanStatus({ state: 'busy' }), { state: 'busy', note: '', until: '' })
  })
  it('a status whose until has passed reads as available (no sweep needed)', () => {
    const st = { state: 'busy', note: '', until: new Date(NOW - 1).toISOString() }
    assert.equal(liveStatus(st, NOW), null)
    assert.equal(liveStatus({ ...st, until: new Date(NOW).toISOString() }, NOW), null, 'until == now is expired')
    assert.equal(liveStatus({ ...st, until: new Date(NOW + MIN).toISOString() }, NOW)?.state, 'busy')
    assert.equal(liveStatus({ ...st, until: '' }, NOW)?.state, 'busy', 'no end never expires')
  })
  it('the roster read: only members with a live status get an entry', () => {
    const map = statusMapFromHumans([
      { human_id: 'HUM-1' },
      { human_id: 'HUM-2', status: { state: 'busy', note: 'In a meeting' } },
      { human_id: 'HUM-3', status: { state: 'unavailable', until: new Date(NOW - MIN).toISOString() } },
      { human_id: 'HUM-4', status: { state: 'unavailable', until: new Date(NOW + MIN).toISOString() } },
    ], NOW)
    assert.deepEqual(Object.keys(map).sort(), ['HUM-2', 'HUM-4'])
  })
})

describe('the status frame (spec 7.4)', () => {
  it('sets by member id, the box dropped from the peer label', () => {
    const next = applyStatusFrame({}, { type: 'status', peer: 'HUM-12@wui', state: 'unavailable', note: 'On leave', until: '2026-10-07T12:00:00Z' })
    assert.deepEqual(next, { 'HUM-12': { state: 'unavailable', note: 'On leave', until: '2026-10-07T12:00:00.000Z' } })
  })
  it('available clears; an unchanged or foreign frame returns the same map', () => {
    const map = { 'HUM-12': { state: 'busy', note: '', until: '' } }
    assert.deepEqual(applyStatusFrame(map, { type: 'status', peer: 'HUM-12@wui', state: 'available' }), {})
    assert.equal(applyStatusFrame(map, { type: 'status', peer: 'HUM-12@wui', state: 'busy' }), map)
    assert.equal(applyStatusFrame(map, { type: 'presence', peer: 'HUM-12@wui', status: 'offline' }), map)
    assert.equal(applyStatusFrame(map, { type: 'status', peer: 'HUM-9@wui', state: 'available' }), map)
  })
  it('the socket client hands it to the presence listener; the roster tells the two apart', () => {
    const ws = read('src/utils/live-ws.mjs')
    assert.match(ws, /case FRAMES\.presence:\s*\n\s*case 'status':\s*\n\s*onPresence\(f\)/)
    assert.match(read('src/stores/human-status.ts'), /live\.onPresence\(\(f\) => \{ if \(f\.type === 'status'\) void applyStatus\(f\) \}\)/)
  })
})

describe('client-side expiry (spec 7.5)', () => {
  it('prunes only expired rows, and reports the soonest end', () => {
    const map = {
      a: { state: 'busy', note: '', until: new Date(NOW - 1).toISOString() },
      b: { state: 'unavailable', note: '', until: new Date(NOW + 5 * MIN).toISOString() },
      c: { state: 'busy', note: '', until: '' },
    }
    assert.deepEqual(Object.keys(pruneExpired(map, NOW)), ['b', 'c'])
    const kept = { b: map.b, c: map.c }
    assert.equal(pruneExpired(kept, NOW), kept, 'nothing expired: same object')
    assert.equal(msToNextExpiry(kept, NOW), 5 * MIN)
    assert.equal(msToNextExpiry({ c: map.c }, NOW), null)
  })
})

describe('the controller the store loads with the first status', () => {
  it('a frame or a roster read replaces the map; the timer drops a status at its until', () => {
    const map = { value: {} }
    const timers = []
    const ctl = statusController(map, { set: (fn, ms) => { timers.push({ fn, ms }); return timers.length }, clear: () => {} })
    const end = new Date(Date.now() + 5000).toISOString()
    ctl.apply({ type: 'status', peer: 'HUM-2@wui', state: 'busy', until: end })
    assert.equal(map.value['HUM-2'].state, 'busy')
    const last = timers.at(-1)
    assert.ok(last.ms > 5000 && last.ms <= 5300, `fires just after the until: ${last.ms}`)
    map.value = { 'HUM-2': { ...map.value['HUM-2'], until: new Date(Date.now() - 1).toISOString() } }
    last.fn()
    assert.deepEqual(map.value, {}, 'expired: dropped without any frame')
    ctl.fill([{ human_id: 'HUM-3', status: { state: 'unavailable' } }])
    assert.deepEqual(Object.keys(map.value), ['HUM-3'])
    assert.equal(ctl.of('HUM-3@wui')?.state, 'unavailable', 'looked up by id@box')
    assert.equal(ctl.label('HUM-3', (k) => k)?.short, 'status.unavailable')
    assert.equal(ctl.of('HUM-2'), null)
    const n = timers.length
    ctl.apply({ type: 'status', peer: 'HUM-3@wui', state: 'unavailable' })
    assert.equal(timers.length, n, 'an unchanged frame schedules nothing')
  })
})

describe('ring and words', () => {
  it('ring by state: amber busy, red unavailable, none available', () => {
    assert.equal(statusRing({ state: 'busy' }), 'busy')
    assert.equal(statusRing({ state: 'unavailable' }), 'unavailable')
    assert.equal(statusRing(null), '')
    const css = read('src/assets/css/main.css')
    assert.match(css, /\.dot\.dot--busy \{[^}]*var\(--color-warn\)/)
    assert.match(css, /\.dot\.dot--unavailable \{[^}]*var\(--color-danger\)/)
  })
  it('text by state; the until in the VIEWER zone, HH:MM today, else date and time', () => {
    setTimeZoneSource(() => 'Europe/Helsinki')
    try {
      const today = '2026-10-06T11:00:00Z' /* 14:00 in Helsinki */
      assert.deepEqual(statusWords({ state: 'unavailable', note: 'On leave', until: today }, NOW),
        { key: 'status.unavailable_until', params: { when: '14:00' }, note: 'On leave' })
      const later = '2026-10-12T06:00:00Z'
      assert.equal(statusUntilLabel(later, NOW), '2026-10-12 09:00')
      assert.deepEqual(statusWords({ state: 'busy', note: '', until: '' }, NOW), { key: 'status.busy', params: {}, note: '' })
      setTimeZoneSource(() => 'America/New_York')
      assert.equal(statusUntilLabel(today, NOW), '07:00', 'another viewer zone, another wall time')
    } finally {
      setTimeZoneSource(() => '')
    }
    assert.equal(statusWords({ state: 'busy', note: '', until: new Date(NOW - 1).toISOString() }, NOW), null)
  })
  it('the label a person reads: short, full with the note, the ring', () => {
    const t = (k, p) => `${k}${p && p.when ? '@' + p.when : ''}`
    assert.deepEqual(statusLabel({ state: 'busy', note: 'In a meeting', until: '' }, t, NOW),
      { short: 'status.busy', full: 'status.busy · In a meeting', note: 'In a meeting', ring: 'busy' })
    assert.equal(statusLabel({ state: 'busy', note: '', until: '' }, t, NOW).full, 'status.busy')
    assert.equal(statusLabel(null, t, NOW), null)
  })
  it('every key the words and lines can name exists in en and bg', () => {
    for (const code of ['en', 'bg']) {
      const cat = JSON.parse(read(`i18n/locales/${code}.json`))
      const st = cat.status
      const ed = cat.status_edit
      for (const s of ['busy', 'unavailable']) {
        for (const k of [s, `${s}_until`]) assert.ok(st[k], `${code} status.${k}`)
        for (const k of [`line_${s}`, `line_${s}_until`, `state_${s}`]) assert.ok(ed[k], `${code} status_edit.${k}`)
      }
      for (const c of STATUS_UNTIL_CHOICES) assert.ok(ed[`until_${c}`], `${code} status_edit.until_${c}`)
      for (const k of ['err_until_invalid', 'err_until_past', 'err_until_far', 'privacy', 'pause_notify', 'all_workspaces']) assert.ok(ed[k], `${code} status_edit.${k}`)
      assert.deepEqual(Object.keys(st).sort(), ['busy', 'busy_until', 'change', 'set', 'unavailable', 'unavailable_until'], 'only what the first screen shows sits in status.*')
      assert.doesNotMatch(JSON.stringify({ st, ed }), /tenant/i, `${code}: user text says workspace, never tenant`)
    }
  })
})

describe('the picker values (spec 3, 7.3, 9, 12)', () => {
  it('note: trimmed, control characters out, 80 characters max', () => {
    assert.equal(cleanStatusNote('  a\tb\u0007c\n'), 'a b c')
    assert.equal(Array.from(cleanStatusNote('x'.repeat(100))).length, 80)
    assert.equal(Array.from(cleanStatusNote('\u{1F600}'.repeat(90))).length, 80, 'counts characters, not UTF-16 units')
  })
  it('defaults: no end for Busy, 1 hour for Unavailable', () => {
    assert.equal(defaultUntilChoice('busy'), 'none')
    assert.equal(defaultUntilChoice('unavailable'), '1h')
  })
  it('until choices, end of today and tomorrow 09:00 in the viewer zone', () => {
    setTimeZoneSource(() => 'Europe/Helsinki')
    try {
      assert.equal(untilFromChoice('30m', NOW), new Date(NOW + 30 * MIN).toISOString())
      assert.equal(untilFromChoice('2h', NOW), new Date(NOW + 120 * MIN).toISOString())
      assert.equal(untilFromChoice('none', NOW), '')
      assert.equal(isoDateTime(untilFromChoice('today', NOW)), '2026-10-06 23:59')
      assert.equal(isoDateTime(untilFromChoice('tomorrow', NOW)), '2026-10-07 09:00')
      assert.equal(untilFromChoice('custom', NOW, '2026-10-08T14:30'), '2026-10-08T11:30:00.000Z')
      assert.equal(untilFromChoice('custom', NOW, 'garbage'), null)
      /* the DST change day in Helsinki: +3 before it, +2 after it */
      assert.equal(parseWallDateTime('2026-10-25T02:30')?.toISOString(), '2026-10-24T23:30:00.000Z')
      assert.equal(parseWallDateTime('2026-10-25T05:00')?.toISOString(), '2026-10-25T03:00:00.000Z')
      assert.equal(parseWallDateTime('2026-13-01T00:00'), null)
      assert.equal(parseWallDateTime('2026-02-30T10:00'), null, 'a day that does not exist')
    } finally {
      setTimeZoneSource(() => '')
    }
  })
  it('until checks mirror the hub: future, at most 90 days', () => {
    assert.equal(untilProblem('', NOW), '')
    assert.equal(untilProblem(null, NOW), 'status_edit.err_until_invalid')
    assert.equal(untilProblem(new Date(NOW - MIN).toISOString(), NOW), 'status_edit.err_until_past')
    assert.equal(untilProblem(new Date(NOW + 91 * 24 * 60 * MIN).toISOString(), NOW), 'status_edit.err_until_far')
    assert.equal(untilProblem(new Date(NOW + 89 * 24 * 60 * MIN).toISOString(), NOW), '')
  })
  it('the PUT body: available is a DELETE; pause only for unavailable; off by default', () => {
    assert.equal(statusBody({ state: 'available' }), null)
    assert.deepEqual(statusBody({ state: 'busy', note: ' In a meeting ', until: '', pauseNotify: true }), { state: 'busy', note: 'In a meeting' })
    assert.deepEqual(statusBody({ state: 'unavailable', until: '2026-10-07T12:00:00.000Z', allWorkspaces: true, pauseNotify: true }),
      { state: 'unavailable', until: '2026-10-07T12:00:00.000Z', all_workspaces: true, pause_notify: true })
    assert.deepEqual(statusBody({ state: 'unavailable' }), { state: 'unavailable' })
  })
})

describe('the composer line (spec 5.1)', () => {
  const statuses = {
    'HUM-2': { state: 'unavailable', note: 'On leave', until: '' },
    'HUM-3': { state: 'busy', note: '', until: '' },
    'HUM-1': { state: 'busy', note: '', until: '' },
  }
  const statusOf = (id) => statuses[id] || null
  it('the DM peer, then each @mentioned member once; never the sender; only a live status', () => {
    assert.deepEqual(composerStatusTargets({ dmPeer: 'HUM-2@wui', mentionIds: ['HUM-3', 'HUM-2', 'HUM-12'], selfId: 'HUM-1', statusOf }).map((r) => r.id), ['HUM-2', 'HUM-3'])
    assert.deepEqual(composerStatusTargets({ dmPeer: 'HUM-1@wui', mentionIds: [], selfId: 'HUM-1', statusOf }), [])
    assert.deepEqual(composerStatusTargets({ dmPeer: 'HUM-12@wui', statusOf }), [])
  })
  it('a draft names members by id or by display name (the @ picker writes the name)', () => {
    const people = [{ id: 'HUM-2', name: 'Ann' }, { id: 'HUM-3', name: 'Ann Lee' }, { id: 'HUM-12', name: 'HUM-12' }]
    assert.deepEqual(draftMentionIds('hi @HUM-12 and @Ann Lee, and @Ann.', people), ['HUM-12', 'HUM-3', 'HUM-2'])
    assert.deepEqual(draftMentionIds('mail a@Annex', people), [], 'an @ inside a word is not a mention')
    assert.deepEqual(draftMentionIds('@Annex', people), [], 'a longer word is not the name')
    assert.deepEqual(draftMentionIds('no mentions', people), [])
  })
  it('the composer mounts the line lazily, Busy softer than Unavailable', () => {
    assert.match(read('src/components/MessageComposer.vue'), /<LazyComposerStatusLine v-if="statusLineDue"/)
    assert.doesNotMatch(read('src/components/MessageComposer.vue'), /human-status\.mjs'/, 'the composer itself never imports the status helpers')
    assert.match(read('src/components/ComposerStatusLine.vue'), /\[data-state=busy\][^}]*color: var\(--color-muted\)/)
  })
})

describe('where it shows (spec 5)', () => {
  it('one dot component in the DM list, People rail, self row, mention picker and DM header', () => {
    assert.ok((read('src/components/ChannelSidebar.vue').match(/<StatusDot/g) || []).length >= 3)
    assert.match(read('src/components/MentionList.vue'), /<StatusDot/)
    assert.match(read('src/components/FeedHeader.vue'), /'dot--' \+ ring/)
    assert.match(read('src/pages/people/[id].vue'), /person-manual-status/)
  })
  it('nothing on a post author line (Q9)', () => {
    assert.doesNotMatch(read('src/components/MessageCard.vue'), /StatusDot|statusOf|useHumanStatus/)
  })
  it('the first screen pays nothing until a status exists (027 initial-chunk budget)', () => {
    for (const f of ['src/stores/roster.ts', 'src/stores/human-status.ts', 'src/components/StatusDot.vue', 'src/components/MessageComposer.vue']) {
      assert.doesNotMatch(read(f), /from '~\/utils\/human-status\.mjs'/, `${f} imports the status helpers statically`)
    }
    assert.match(read('src/stores/human-status.ts'), /import\('~\/utils\/human-status\.mjs'\)/)
    /* the entry chunk's roster store only keeps the raw status per member */
    assert.doesNotMatch(read('src/stores/roster.ts'), /human-status|status:/, 'the entry chunk roster store knows nothing of statuses')
    assert.doesNotMatch(read('src/utils/spool-client.mjs'), /MyStatus/, 'nor does the spool client (the write is in the lazy module)')
    assert.doesNotMatch(read('src/components/MessageComposer.vue'), /useHumanStatusStore/, 'the composer gate keeps no status state')
    /* the picker and the line are on-demand components: their words wait in the second catalogue */
    for (const f of ['StatusPicker', 'ComposerStatusLine']) {
      assert.match(read('src/utils/i18n-first-screen.mjs'), new RegExp(`"components/${f}\\.vue": "idle"`))
      assert.match(read(`src/components/${f}.vue`), /const i18nReady = computed\(\(\) => te\('status_edit\./)
    }
  })
  it('the lazy half imports only date helpers the entry chunk already keeps', () => {
    /* parseIsoDate added 307 bytes to the entry chunk (node gzip, CI AC-02) */
    assert.match(read('src/utils/human-status.mjs'), /import \{ isoClock, isoDate, isoDateTime, isoDateTimeSec \} from '\.\/date-iso\.mjs'/)
    /* a radio v-model pulls Vue's vModelRadio into the shared runtime chunk */
    assert.doesNotMatch(read('src/components/StatusPicker.vue'), /v-model="state"/)
  })
  it('the picker is lazy: the layout mounts it only while open', () => {
    assert.match(read('src/layouts/default.vue'), /<LazyStatusPicker v-if="statusPicker\.open\.value"/)
  })
})
