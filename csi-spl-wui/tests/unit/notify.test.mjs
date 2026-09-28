import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  shouldEscalate,
  escalateReason,
  mentionedIds,
  channelKey,
  normalizeChannel,
  notifyCopy,
  notifyCopyKey,
  loadChime,
  saveChime,
  notificationOptions,
  isSoundPrefKey,
  ALERTS_KEY,
  previewUnread,
  CHIME_KEY,
  shouldPing,
  loadMutedChannels,
  saveMutedChannels,
  toggleMutedChannel,
  MUTED_CHANNELS_KEY,
  playChime,
} from '../../src/utils/notify.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

function msg(partial) {
  return {
    v: 1,
    msg_id: 'm1',
    task_id: 't1',
    ts: '2026-09-19T05:00:00Z',
    from: 'CLE-07',
    to: '@channel',
    kind: 'note',
    body: 'hello',
    channel: 'lobby',
    ...partial,
  }
}

describe('notify escalation', () => {
  it('escalates a mention of the signed-in HUM-* in a channel', () => {
    const m = msg({ body: 'hey @HUM-1 please look', channel: 'lobby' })
    assert.equal(escalateReason(m, { selfId: 'HUM-1' }), 'mention')
    assert.equal(shouldEscalate(m, { selfId: 'HUM-1' }), true)
    assert.equal(shouldEscalate(m, { selfId: 'HUM-2' }), false)
  })

  it('escalates to=HUM-* as a mention', () => {
    const m = msg({ to: 'HUM-1', body: 'review this', channel: 'tasks' })
    assert.equal(escalateReason(m, { selfId: 'HUM-1' }), 'mention')
  })

  it('escalates a DM (channel null) and a ctx.isDm pane', () => {
    const dm = msg({ channel: null, to: 'HUM-1', body: 'ping' })
    assert.equal(escalateReason(dm, { selfId: 'HUM-1' }), 'dm')
    const onDm = msg({ channel: undefined, body: 'hi' })
    assert.equal(escalateReason(onDm, { selfId: 'HUM-1', isDm: true, peer: 'CLE-07@box-a' }), 'dm')
    assert.equal(channelKey(dm, { selfId: 'HUM-1' }), 'dm:CLE-07')
  })

  it('escalates any #alerts message and not a plain #tasks note', () => {
    const alerts = msg({ channel: 'alerts', body: 'box-b offline' })
    assert.equal(escalateReason(alerts, { selfId: 'HUM-1' }), 'alerts')
    assert.equal(shouldEscalate(msg({ channel: '#alerts' }), { selfId: 'HUM-1' }), true)
    assert.equal(shouldEscalate(msg({ channel: 'tasks', body: 'Applying patch' }), { selfId: 'HUM-1' }), false)
    assert.equal(shouldEscalate(msg({ channel: 'lobby', body: 'hello' }), { selfId: 'HUM-1' }), false)
  })

  it('never escalates own messages, even in #alerts or with a self mention', () => {
    assert.equal(shouldEscalate(msg({ from: 'HUM-1', channel: 'alerts' }), { selfId: 'HUM-1' }), false)
    assert.equal(shouldEscalate(msg({ from: 'HUM-1', body: '@HUM-1 note' }), { selfId: 'HUM-1' }), false)
  })

  it('parses mention ids and copies', () => {
    assert.deepEqual(mentionedIds('cc @CLE-07 and @HUM-1 please'), ['CLE-07', 'HUM-1'])
    assert.deepEqual(mentionedIds('email me@example.com'), [])
    const copy = notifyCopy(msg({ from: 'GRK-03', body: 'up' }), 'alerts')
    assert.equal(copy.title.startsWith('#alerts'), true)
  })

  it('notifyCopyKey names the same title as a catalogue key (spec 021)', () => {
    const m = msg({ from: 'GRK-03', body: 'up' })
    for (const [reason, key] of [['alerts', 'notify.title_alerts'], ['dm', 'notify.title_dm'], ['mention', 'notify.title_mention'], [null, 'notify.title_other']]) {
      const k = notifyCopyKey(m, reason)
      assert.equal(k.titleKey, key)
      assert.deepEqual(k.params, { from: 'GRK-03' })
      assert.equal(k.body, notifyCopy(m, reason).body)
    }
  })

  it('normalizes general to lobby and builds ch:/dm: keys', () => {
    assert.equal(normalizeChannel('#General'), 'lobby')
    assert.equal(channelKey(msg({ channel: 'tasks' })), 'ch:tasks')
    assert.equal(channelKey(msg({ channel: 'general' })), 'ch:lobby')
    assert.equal(channelKey(msg({}), { channel: 'lobby' }), 'ch:lobby')
  })

  it('chime is opt-in (default off) and survives storage throws', () => {
    const store = memoryStore()
    assert.equal(loadChime(store), false)
    saveChime(true, store)
    assert.equal(store.getItem(CHIME_KEY), '1')
    assert.equal(loadChime(store), true)
    const boom = { getItem() { throw new Error('x') }, setItem() { throw new Error('x') } }
    assert.equal(loadChime(boom), false)
    assert.equal(previewUnread(0), '')
    assert.equal(previewUnread(3), '3')
    assert.equal(previewUnread(100), '99+')
  })

  /* SPL-998: with the bell on and the note off, every alert still beeped -
     a browser Notification plays the OS alert sound unless it is silent. */
  it('SPL-998: the note is the one sound switch - an alert is silent while it is off', () => {
    assert.deepEqual(notificationOptions('hi', false), { body: 'hi', silent: true })
    assert.deepEqual(notificationOptions('hi', true), { body: 'hi', silent: false })
    assert.equal(notificationOptions(undefined, false).body, '')
    assert.equal(isSoundPrefKey(CHIME_KEY), true)
    assert.equal(isSoundPrefKey(ALERTS_KEY), true)
    assert.equal(isSoundPrefKey(null), true, 'localStorage.clear() in another tab')
    assert.equal(isSoundPrefKey('spool-theme'), false)
  })

  it('SPL-998: every sound path in src reads the note', () => {
    const store = readFileSync(join(WUI, 'src/stores/notification.ts'), 'utf8')
    const calls = store.match(/new Notification\([^)]*\)/g) || []
    assert.ok(calls.length >= 1)
    for (const c of calls) assert.match(c, /notificationOptions\(body, chime\.value\)/)
    assert.match(store, /if \(chime\.value && import\.meta\.client\)[\s\S]{0,120}playChime\(\)/)
    /* CLE-35075: the beep lives in notify.mjs playChime; only the gated store path calls it */
    const chimes = execSync(`grep -rlE "playChime\\(" src || true`, { cwd: WUI }).toString().trim().split('\n').filter(Boolean).sort()
    assert.deepEqual(chimes, ['src/stores/notification.ts', 'src/utils/notify.mjs'])
    assert.match(store, /addEventListener\('storage'[\s\S]{0,80}isSoundPrefKey\(e\.key\)\) hydrate\(\)/)
    /* nothing else in src makes a sound: add it to this list AND gate it on the note */
    const hits = execSync(`grep -rlE "new (Audio|AudioContext|Notification)\\(|showNotification\\(|\\.play\\(\\)" src public || true`, { cwd: WUI }).toString().trim().split('\n').filter(Boolean)
    assert.deepEqual(hits, ['src/stores/notification.ts'])
  })

  it('CLE-35075: playChime makes the same beep and closes its AudioContext when it ends', () => {
    const made = []
    class FakeCtx {
      constructor() { this.closed = false; this.currentTime = 5; this.destination = {}; made.push(this) }
      createOscillator() { const o = { frequency: {}, connect: () => {}, start: () => { o.started = true }, stop: (t) => { o.stopAt = t } }; this.osc = o; return o }
      createGain() { const g = { gain: {}, connect: () => {} }; this.g = g; return g }
      close() { this.closed = true; return Promise.resolve() }
    }
    assert.equal(playChime(FakeCtx), true)
    const c = made[0]
    assert.equal(c.osc.frequency.value, 880)
    assert.equal(c.g.gain.value, 0.04)
    assert.equal(c.osc.started, true)
    assert.equal(c.osc.stopAt, 5.12)
    assert.equal(c.closed, false, 'open while it sounds')
    c.osc.onended()
    assert.equal(c.closed, true, 'closed when the beep ends')
    assert.equal(playChime(undefined), false, 'no Web Audio: nothing')
  })

  it('NotificationCenter and the notification store do not import mock-data', () => {
    const center = readFileSync(join(WUI, 'src/components/NotificationCenter.vue'), 'utf8')
    const store = readFileSync(join(WUI, 'src/stores/notification.ts'), 'utf8')
    assert.equal(center.includes('mock-data'), false)
    assert.equal(store.includes('mock-data'), false)
    assert.equal(center.includes('useNotificationStore'), true)
    assert.equal(center.includes('chime'), true)
    assert.equal(center.includes('toggleAlerts'), true) // the bell asks the browser once, then toggles
  })
})

describe('live #alerts / DM escalation wiring (gap A2)', () => {
  const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

  it('a live #alerts frame keys and escalates as alerts even while a DM is open', () => {
    const frame = { msg_id: 'x', from: 'CLE-2', from_box: 'b1', channel: 'alerts', body: 'disk full' }
    const page = { selfId: 'HUM-1', activeKey: 'dm:CLE-3@b2' }
    assert.equal(channelKey(frame, page), 'ch:alerts')
    assert.equal(escalateReason(frame, page), 'alerts')
    const dm = { msg_id: 'y', from: 'CLE-3', from_box: 'b2', channel: null, body: 'hi' }
    assert.equal(channelKey(dm, page), 'dm:CLE-3@b2')
    assert.equal(escalateReason(dm, page), 'dm')
  })

  it('the plugin ingests live frames with the page identity only, not its peer', () => {
    const plugin = src('src/plugins/notify.client.ts')
    assert.match(plugin, /notes\.ingest\(\[m\], \{ selfId: page\.selfId, activeKey: page\.activeKey \}/)
    assert.equal(plugin.includes('applyChannels'), true)
  })

  it('the store derives unread from stored cursors and counts mentions', () => {
    const store = src('src/stores/notification.ts')
    assert.equal(store.includes('isUnread(m, cursors[key])'), true)
    assert.equal(store.includes('mentions'), true)
  })

  /* CLE-3433. main.css collapses the sidebar to a 72px rail at 800px and
     below and hides the section headings, the nav labels, the create row and
     the version stamp. NotificationCenter never got that treatment, so the
     words "enable alerts" were wrapped inside a 40px-wide button carrying
     `overflow-wrap: anywhere` and rendered as a column of single letters —
     measured on the deployed dev build 28ec27b as 40x234px at every viewport
     from 390 to 768. Pin the rail form, and pin that the control is hidden
     from NOBODY: a phone is where push matters most, so it keeps an
     accessible name rather than being display:none'd like the labels.
     SPL-990: at <= 820 px the rail is gone (full-width level 1) and the
     controls move to the avatar bottom sheet; the rail copy hides, the menu
     copy is never hidden. */
  it('CLE-3433 / SPL-990: on a phone the alerts control is an icon in the avatar sheet, and keeps its name', () => {
    const vue = src('src/components/NotificationCenter.vue')
    assert.match(vue, /@media \(max-width: 820px\)/)
    assert.match(src('src/components/UserMenu.vue'), /<NotificationCenter placement="menu" \/>/)
    assert.match(vue, /:aria-label="alertsLabel"/)
    assert.match(vue, /'bell' : 'bell-off'/)
    // owner 2026-09-26: the note is struck through when the chime is off, like the bell
    assert.match(vue, /notes\.chime \? 'music' : 'music-off'/)
    assert.match(src('src/utils/uiIcons.ts'), /"music-off": \[/)
    /* SPL-998 owner: the note's strike has "the same width and color as on
       the bell" - so it IS the bell-off slash path, drawn by the same rule */
    const icons = src('src/utils/uiIcons.ts')
    const glyph = (n) => icons.slice(icons.indexOf(`${n}: [`) + n.length + 3, icons.indexOf('],', icons.indexOf(`${n}: [`)))
      .split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('//'))
    const bell = glyph('"bell-off"'), note = glyph('"music-off"'), music = glyph('music')
    assert.match(bell.at(-1), /^"M2 2 22 22",$/, 'the bell slash is a plain stroke')
    assert.equal(note.at(-1), bell.at(-1), 'the note strike is the bell strike')
    assert.deepEqual(note.slice(0, -1), music)
    assert.doesNotMatch(vue, /\.notify-chime:not\(\.on\)/, 'no chime-only off colour: it matches the bell off')
    assert.match(vue, /notify\.chime_on/)
    assert.match(vue, /notify\.chime_off/)
    assert.match(vue, /:aria-pressed="notes\.chime"/)
    assert.match(vue, /:aria-pressed="notes\.chime"/)
    const rail = vue.slice(vue.indexOf('@media (max-width: 820px)'))
    /* owner 2026-09-26: icons at every width, so there is no text to hide */
    assert.doesNotMatch(vue, /class="notify-text"/)
    assert.match(vue, /\.notify-glyph \{ display: block; \}/)
    /* the control itself is never removed: only the rail copy steps aside */
    assert.match(rail, /\.notify-box--rail \{ display: none; \}/)
    assert.doesNotMatch(rail, /\.notify-box(--menu)? \{[^}]*display:\s*none/)
    assert.doesNotMatch(rail, /\.notify-alerts \{[^}]*display:\s*none/)
    assert.match(src('src/utils/uiIcons.ts'), /\n  bell: \[/)
  })
})

describe('muted channels do not ping', () => {
  it('a mention on a muted channel does not ping, and the same mention on an open channel does', () => {
    const mention = msg({ body: 'hey @HUM-1 please look', channel: 'releases' })
    assert.equal(shouldPing(mention, { selfId: 'HUM-1' }, []), true)
    assert.equal(shouldPing(mention, { selfId: 'HUM-1' }, ['releases']), false)
    assert.equal(shouldPing(mention, { selfId: 'HUM-1' }, ['alerts']), true)
    const alerts = msg({ channel: 'alerts', body: 'wake' })
    assert.equal(shouldPing(alerts, { selfId: 'HUM-1' }, []), true)
    assert.equal(shouldPing(alerts, { selfId: 'HUM-1' }, ['alerts']), false)
    const dm = msg({ channel: null, from: 'CLE-07', to: 'HUM-1', body: 'hi' })
    assert.equal(shouldPing(dm, { selfId: 'HUM-1' }, ['lobby', 'alerts', 'releases']), true)
    assert.equal(shouldPing(msg({ channel: 'tasks', body: 'Applying patch' }), { selfId: 'HUM-1' }, []), false)
  })

  it('mute is remembered in this browser under spool.muted-channels', () => {
    const store = memoryStore()
    assert.deepEqual(loadMutedChannels(store), [])
    const once = saveMutedChannels(toggleMutedChannel([], 'alerts'), store)
    assert.deepEqual(once, ['alerts'])
    assert.deepEqual(loadMutedChannels(store), ['alerts'])
    assert.deepEqual(saveMutedChannels(toggleMutedChannel(once, '#alerts'), store), [])
    assert.equal(MUTED_CHANNELS_KEY, 'spool.muted-channels')
    const note = readFileSync(join(WUI, 'src/stores/notification.ts'), 'utf8')
    assert.match(note, /shouldPing\(m, ctx, loadMutedChannels\(\)\)/)
    assert.match(note, /bump\(key, reason\)/)
  })
})


// owner, 2026-09-26: "the bell does not change to striken and not striken" -
// the bell is the reader's on/off choice, not only the browser permission.
describe('alerts on/off (the bell)', () => {
  it('fires only when the browser granted it AND the reader wants it', async () => {
    const { alertsActive, loadAlerts, saveAlerts } = await import('../../src/utils/notify.mjs')
    assert.equal(alertsActive('granted', true), true)
    assert.equal(alertsActive('granted', false), false)
    assert.equal(alertsActive('default', true), false)
    assert.equal(alertsActive('denied', true), false)
    const mem = new Map()
    const store = { getItem: (k) => (mem.has(k) ? mem.get(k) : null), setItem: (k, v) => mem.set(k, String(v)) }
    assert.equal(loadAlerts(store), true) // default ON: a granted browser keeps alerting
    saveAlerts(false, store)
    assert.equal(loadAlerts(store), false)
    saveAlerts(true, store)
    assert.equal(loadAlerts(store), true)
  })
  it('the bell glyph follows the reader switch, not whether messages are popping', () => {
    const center = readFileSync(join(WUI, 'src/components/NotificationCenter.vue'), 'utf8')
    const settings = readFileSync(join(WUI, 'src/pages/settings/notifications.vue'), 'utf8')
    assert.match(center, /notes\.toggleAlerts\(\)/)
    assert.match(center, /notes\.alertsEnabled/)
    assert.match(settings, /notes\.alertsEnabled/)
    assert.doesNotMatch(center, /alertsOn \? 'bell'/)
    const store = readFileSync(join(WUI, 'src/stores/notification.ts'), 'utf8')
    const flip = store.indexOf('alertsEnabled.value = !alertsEnabled.value')
    const ask = store.indexOf('await requestPush()')
    assert.ok(flip > 0 && ask > flip)
    assert.match(store, /if \(alertsOn\.value && typeof Notification/)
    assert.doesNotMatch(store, /if \(permission\.value !== 'granted'\)/)
  })
})
