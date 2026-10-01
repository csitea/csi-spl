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
  dmBadgeText,
  dmTotalText,
  CHIME_KEY,
  shouldPing,
  loadMutedChannels,
  saveMutedChannels,
  toggleMutedChannel,
  MUTED_CHANNELS_KEY,
  playChime,
  playSound,
  SOUND_LIBRARY,
  SOUND_NAMES,
  DEFAULT_SOUND,
  normalizeSound,
  loadChimeSound,
  saveChimeSound,
  CHIME_SOUND_KEY,
} from '../../src/utils/notify.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'
import { normalizeViewMessage } from '../../src/utils/view-api.mjs'
import { dmTotalsFromDms } from '../../src/utils/channel-feed.mjs'

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

  it('a human->human DM escalates and keys like an agent->person one (owner, prd t1 dd88348d)', () => {
    // The live recipient path must treat both sender kinds identically: only the
    // sender box differs (an agent's own box vs box-wui). "the same way it
    // works, agent to person now".
    const fromAgent = msg({ channel: null, from: 'CLE-07', from_box: 'box-desk', to: 'HUM-1', body: 'hi' })
    const fromHuman = msg({ channel: null, from: 'HUM-5', from_box: 'box-wui', to: 'HUM-1', body: 'hi' })
    assert.equal(escalateReason(fromHuman, { selfId: 'HUM-1' }), 'dm')
    assert.equal(channelKey(fromAgent, { selfId: 'HUM-1' }), 'dm:CLE-07@box-desk')
    assert.equal(channelKey(fromHuman, { selfId: 'HUM-1' }), 'dm:HUM-5@box-wui')
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
    /* bug A: the store raises alerts through showAlert (Android's worker fallback) */
    const calls = store.match(/showAlert\([^\n]*\)/g) || []
    assert.ok(calls.length >= 1)
    for (const c of calls) assert.match(c, /notificationOptions\(body, chime\.value, tag\)/)
    /* 051: the ping plays the reader's chosen sound, still gated on the note */
    assert.match(store, /if \(chime\.value && import\.meta\.client( && chimeGate\(\))?\)[\s\S]{0,140}playSound\(sound\.value\)/)
    /* CLE-35075/051: the synth lives in notify.mjs; the gated store path plays
       it, and the Settings picker previews it. Nowhere else. */
    const sounds = execSync(`grep -rlE "playSound\\(" src || true`, { cwd: WUI }).toString().trim().split('\n').filter(Boolean).sort()
    assert.deepEqual(sounds, ['src/components/settings/notifications.vue', 'src/stores/notification.ts', 'src/utils/notify.mjs'])
    assert.match(store, /addEventListener\('storage'[\s\S]{0,80}isSoundPrefKey\(e\.key\)\) hydrate\(\)/)
    /* nothing else in src makes a sound: add it to this list AND gate it on the note */
    const hits = execSync(`grep -rlE "new (Audio|AudioContext|Notification)\\(|showNotification\\(|\\.play\\(\\)" src public || true`, { cwd: WUI }).toString().trim().split('\n').filter(Boolean)
    /* bug A: the one place that constructs an alert is showAlert in notify.mjs */
    assert.deepEqual(hits, ['src/utils/notify.mjs'])
    const lib = readFileSync(join(WUI, 'src/utils/notify.mjs'), 'utf8')
    assert.match(lib, /export async function showAlert\(title, opts, env = \{\}\)/)
  })

  it('CLE-35075: playChime makes the same beep and closes its AudioContext when it ends', () => {
    const made = []
    class FakeCtx {
      constructor() { this.closed = false; this.currentTime = 5; this.destination = {}; made.push(this) }
      createOscillator() { const o = { frequency: {}, connect: () => {}, start: () => { o.started = true }, stop: (t) => { o.stopAt = t } }; this.osc = o; return o }
      createGain() { const g = { gain: {}, connect: () => {} }; this.g = g; return g }
      close() { this.closed = true; return Promise.resolve() }
    }
    const timers = []
    assert.equal(playChime(FakeCtx, (fn) => timers.push(fn)), true)
    const c = made[0]
    assert.equal(c.osc.frequency.value, 880)
    assert.equal(c.g.gain.value, 0.04)
    assert.equal(c.osc.started, true)
    /* HUM-24: after the lead-in */
    assert.ok(Math.abs(c.osc.stopAt - 5.17) < 1e-9, String(c.osc.stopAt))
    assert.equal(c.closed, false, 'open while it sounds')
    c.osc.onended()
    assert.equal(c.closed, false, 'HUM-24: still open while the speaker plays it')
    timers[0]()
    assert.equal(c.closed, true, 'closed after the grace')
    assert.equal(playChime(undefined), false, 'no Web Audio: nothing')
  })

  /* 051: a richer fake than the playChime one — it records every oscillator's
     schedule so a multi-segment, gliding, enveloped sound can be checked. */
  class SynthCtx {
    constructor() { this.closed = false; this.currentTime = 2; this.destination = {}; this.oscs = [] }
    createOscillator() {
      const o = {
        type: 'sine', frequency: { value: 0, ramps: [], setValueAtTime(v, t) { this.value = v; this.setAt = [v, t] }, exponentialRampToValueAtTime(v, t) { this.ramps.push([v, t]) } },
        connect: () => {}, start: (t) => { o.startAt = t }, stop: (t) => { o.stopAt = t },
      }
      this.oscs.push(o); return o
    }
    createGain() { return { gain: { value: 0, setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect: () => {} } }
    close() { this.closed = true; return Promise.resolve() }
  }

  it('051: the sound library is code-only, has fun options, and a non-plain default', () => {
    assert.deepEqual(SOUND_NAMES, Object.keys(SOUND_LIBRARY))
    for (const n of ['plain', 'pop', 'chirp', 'marimba', 'boing']) assert.ok(SOUND_NAMES.includes(n), n)
    assert.ok(SOUND_NAMES.includes(DEFAULT_SOUND))
    assert.notEqual(DEFAULT_SOUND, 'plain', 'a fresh device gets a fun sound, not the beep')
    // every segment is a synthesised tone, never a file url
    for (const spec of Object.values(SOUND_LIBRARY)) {
      assert.ok(Array.isArray(spec.segs) && spec.segs.length >= 1)
      for (const s of spec.segs) {
        assert.equal(typeof s.f, 'number')
        assert.equal(typeof s.dur, 'number')
        assert.equal(typeof s.gain, 'number')
        assert.equal('src' in s || 'url' in s, false)
      }
    }
  })

  it('051: normalizeSound / loadChimeSound / saveChimeSound round-trip and fall back', () => {
    assert.equal(normalizeSound('pop'), 'pop')
    assert.equal(normalizeSound('nope'), DEFAULT_SOUND)
    assert.equal(normalizeSound(undefined), DEFAULT_SOUND)
    const store = memoryStore()
    assert.equal(loadChimeSound(store), DEFAULT_SOUND, 'default before any save')
    saveChimeSound('marimba', store)
    assert.equal(store.getItem(CHIME_SOUND_KEY), 'marimba')
    assert.equal(loadChimeSound(store), 'marimba')
    saveChimeSound('bogus', store)
    assert.equal(loadChimeSound(store), DEFAULT_SOUND, 'a bad stored value reads as the default')
    assert.equal(isSoundPrefKey(CHIME_SOUND_KEY), true, 'a sound change in another tab re-hydrates')
  })

  it('051: playSound plays every library sound and closes its context on the last note', () => {
    const asCtor = (inst) => function () { return inst }
    for (const name of SOUND_NAMES) {
      const ctx = new SynthCtx()
      const timers = []
      assert.equal(playSound(name, asCtor(ctx), (fn, ms) => timers.push({ fn, ms })), true, name)
      assert.equal(ctx.oscs.length, SOUND_LIBRARY[name].segs.length, name)
      for (const o of ctx.oscs) assert.equal(typeof o.stopAt, 'number', `${name}: scheduled a stop`)
      assert.equal(ctx.closed, false, `${name}: open while it sounds`)
      // the last-ending oscillator closes the context
      const last = ctx.oscs.reduce((a, b) => (b.stopAt >= a.stopAt ? b : a))
      assert.equal(typeof last.onended, 'function', `${name}: last note closes the ctx`)
      last.onended()
      /* HUM-24: not at the context-time end - the speaker is still playing it */
      assert.equal(ctx.closed, false, `${name}: still open right after the last note ends`)
      assert.equal(timers.length, 1, `${name}: one deferred close`)
      assert.ok(timers[0].ms >= 1000, `${name}: the close waits >= 1 s`)
      timers[0].fn()
      assert.equal(ctx.closed, true, `${name}: closed after the grace`)
    }
    assert.equal(playSound('chirp', undefined), false, 'no Web Audio: nothing')
    // an unknown name still plays (the default), it does not throw
    assert.equal(playSound('nope', SynthCtx), true)
  })

  it('051: Settings -> Notifications is the sound picker, each option playable, all sounds i18n-keyed', () => {
    const vue = readFileSync(join(WUI, 'src/components/settings/notifications.vue'), 'utf8')
    assert.match(vue, /data-test="settings-notify-sound"/)
    assert.match(vue, /role="radiogroup"/)
    assert.match(vue, /playSound\(name\)/)
    assert.match(vue, /notes\.sound = name/)
    assert.match(vue, /notify\.sound_label/)
    assert.match(vue, /notify\.sound_hint/)
    assert.match(vue, /notify\.sound_preview/)
    const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8'))
    for (const n of SOUND_NAMES) assert.equal(typeof en.notify[`sound_${n}`], 'string', `en label for ${n}`)
    assert.equal(typeof en.notify.sound_label, 'string')
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
    /* bug A: an ordinary message pings too; muting its channel silences it */
    assert.equal(shouldPing(msg({ channel: 'tasks', body: 'Applying patch' }), { selfId: 'HUM-1' }, []), true)
    assert.equal(shouldPing(msg({ channel: 'tasks', body: 'Applying patch' }), { selfId: 'HUM-1' }, ['tasks']), false)
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
    const settings = readFileSync(join(WUI, 'src/components/settings/notifications.vue'), 'utf8')
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

/* CLE-77845 (prd csitea 2026-10-01): a desk answer in #spool-hub-biz raised the
   agent's DM badge while its DM was empty. The hub stores a box reply in its
   topic's channel, but the signed envelope names none; the view element now
   carries the row's channel beside it, and that must key the unread as the
   channel, never as a DM with the agent. */
describe('a box reply in a channel is not a DM (CLE-77845)', () => {
  const el = (extra = {}) => ({
    cursor: 'c1', received_at: '2026-10-01T08:39:12Z', is_parent: 0,
    env: { from_box: 'box-desk', to_box: 'box-wui', msg: { v: 1, msg_id: 'm1', task_id: 't1', from: 'CLE-35004', to: 'HUM-10', kind: 'note', body: 'answer' } },
    ...extra,
  })
  it('the row channel beside the envelope keys the channel', () => {
    const m = normalizeViewMessage(el({ channel: 'spool-hub-biz' }))
    assert.equal(m.channel, 'spool-hub-biz')
    assert.equal(channelKey(m, { channel: 'spool-hub-biz' }), 'ch:spool-hub-biz')
  })
  it('control: an envelope with no channel and no row channel is a DM with the agent', () => {
    const m = normalizeViewMessage(el())
    assert.equal(channelKey(m, {}), 'dm:CLE-35004@box-desk')
  })
})

/* CLE-77845 (owner, topic 5dc55d94): "the direct messages should have the
   <<new>> / <<total>> type of rendering". */
describe('DM rail badge "<new>/<total>" (CLE-77845)', () => {
  it('reads new/total, hides at 0, caps like the plain badge', () => {
    assert.equal(dmBadgeText(2, 7), '2/7')
    assert.equal(dmBadgeText(0, 7), '')
    assert.equal(dmBadgeText(100, 250), '99+/250')
    assert.equal(dmBadgeText(1, 1000), '1/999+')
  })
  it('an unknown total falls back to the plain new count', () => {
    assert.equal(dmBadgeText(3, 0), '3')
    assert.equal(dmBadgeText(3, 2), '3')
  })
  /* CLE-77873 (owner, t1 d6c9661e): a read DM still shows its total, plain */
  it('nothing new: the plain total, never "0/7"; unknown -> nothing', () => {
    assert.equal(dmTotalText(7), '7')
    assert.equal(dmTotalText(1000), '999+')
    assert.equal(dmTotalText(0), '')
    assert.equal(dmTotalText(undefined), '')
  })
  const msg = (id, from, to, extra = {}) => ({ msg_id: id, from, from_box: from.startsWith('HUM') ? 'box-wui' : 'box-desk', to, to_box: to.startsWith('HUM') ? 'box-wui' : 'box-desk', channel: null, ...extra })
  it('totals count every line of a fully inlined DM topic, ours too, per peer', () => {
    const topics = [
      { count: 3, participants: ['CLE-1@box-desk', 'HUM-1@box-wui'], inline: { messages: [msg('a', 'CLE-1', 'HUM-1'), msg('b', 'HUM-1', 'CLE-1'), msg('c', 'CLE-1', 'HUM-1')] } },
      { count: 1, participants: ['CLE-2@box-desk', 'HUM-1@box-wui'], inline: { messages: [msg('d', 'CLE-2', 'HUM-1')] } },
    ]
    assert.deepEqual(dmTotalsFromDms(topics, 'HUM-1'), { 'dm:CLE-1@box-desk': 3, 'dm:CLE-2@box-desk': 1 })
  })
  it('a topic held only in part adds the hub row count to the other end', () => {
    const topics = [{ count: 60, participants: ['CLE-1@box-desk', 'HUM-1@box-wui'], inline: { messages: [msg('a', 'CLE-1', 'HUM-1')] } }]
    assert.deepEqual(dmTotalsFromDms(topics, 'HUM-1'), { 'dm:CLE-1@box-desk': 60 })
  })
  it('a channel line never counts toward a DM total', () => {
    const topics = [{ count: 2, participants: [], inline: { messages: [msg('a', 'CLE-1', 'HUM-1', { channel: 'ops' }), msg('b', 'CLE-1', 'HUM-1')] } }]
    assert.deepEqual(dmTotalsFromDms(topics, 'HUM-1'), { 'dm:CLE-1@box-desk': 1 })
  })
})

// Bug A (t1 5002067f, HUM-24 2026-09-29): "notifications for new messages are
// enabled, but no signal comes". Only a mention, a DM or #alerts made a
// sound or an alert, so an ordinary reply from a member or an agent raised a
// rail badge and nothing else; and on Android `new Notification()` throws, so
// no alert ever showed there.
describe('bug A: a new message signals', () => {
  it('an ordinary channel message from another member or agent pings', () => {
    const ctx = { selfId: 'HUM-24' }
    assert.equal(shouldPing(msg({ from: 'HUM-10', channel: 'lobby', body: 'hello' }), ctx, []), true)
    assert.equal(shouldPing(msg({ from: 'CLE-07', channel: 'spool-hub-bugs', body: 'fixed' }), ctx, []), true)
    /* the reader's own message never pings, with or without its @box */
    assert.equal(shouldPing(msg({ from: 'HUM-24', channel: 'lobby' }), ctx, []), false)
    assert.equal(shouldPing(msg({ from: 'HUM-24@wui', channel: 'lobby' }), ctx, []), false)
    /* a muted channel stays quiet; a DM is never muted by a channel */
    assert.equal(shouldPing(msg({ from: 'HUM-10', channel: 'lobby' }), ctx, ['lobby']), false)
    assert.equal(shouldPing(msg({ from: 'HUM-10', channel: null }), ctx, ['lobby']), true)
    /* escalation still names the alert: an ordinary message is not a mention */
    assert.equal(escalateReason(msg({ from: 'HUM-10', channel: 'lobby', body: 'hello' }), ctx), null)
  })

  it('the open feed pings when the reader is away, for any message, not only an escalated one', () => {
    const note = readFileSync(join(WUI, 'src/stores/notification.ts'), 'utf8')
    assert.match(note, /away\(\) && shouldPing\(m, ctx, loadMutedChannels\(\)\)/)
    assert.match(note, /document\.hasFocus\(\)/)
    assert.doesNotMatch(note, /if \(reason\) \{\s*const copy = copyFor/)
  })

  it('Android: a throwing Notification constructor falls back to the service worker', async () => {
    const { showAlert } = await import('../../src/utils/notify.mjs')
    const shown = []
    function Throws() { throw new TypeError('Illegal constructor') }
    const serviceWorker = { getRegistration: async () => ({ showNotification: async (t, o) => { shown.push([t, o]) } }) }
    assert.equal(await showAlert('DM from HUM-10', { body: 'hi', silent: false }, { Notification: Throws, serviceWorker }), true)
    assert.deepEqual(shown, [['DM from HUM-10', { body: 'hi', silent: false }]])
    /* desktop: the constructor works and the worker is not touched */
    const made = []
    function Works(t) { made.push(t) }
    assert.equal(await showAlert('x', {}, { Notification: Works, serviceWorker: { getRegistration: async () => { throw new Error('unused') } } }), true)
    assert.deepEqual(made, ['x'])
    /* neither available: false, never a throw */
    assert.equal(await showAlert('x', {}, { Notification: Throws, serviceWorker: undefined }), false)
  })

  it('one alert per feed replaces the last (tag), and the store passes the feed key', async () => {
    /* HUM-24 (311427c6): renotify, or a same-tag replacement is silent */
    assert.deepEqual(notificationOptions('b', true, 'ch:lobby'), { body: 'b', silent: false, tag: 'ch:lobby', renotify: true })
    assert.deepEqual(notificationOptions('b', false), { body: 'b', silent: true })
    const note = readFileSync(join(WUI, 'src/stores/notification.ts'), 'utf8')
    assert.match(note, /ping\(copy\.title, copy\.body, key\)/)
    assert.match(note, /showAlert\(title, notificationOptions\(body, chime\.value, tag\)\)/)
  })

  it('a burst of messages plays one chime per 2 s', async () => {
    const { pingThrottle } = await import('../../src/utils/notify.mjs')
    let t = 0
    const gate = pingThrottle(2000, () => t)
    assert.equal(gate(), true)
    t = 500
    assert.equal(gate(), false)
    t = 2100
    assert.equal(gate(), true)
  })

  it('a suspended AudioContext (autoplay policy) is resumed before it plays', () => {
    let resumed = 0
    const param = () => ({ value: 0, setValueAtTime() {}, exponentialRampToValueAtTime() {} })
    class Ctx {
      constructor() { this.state = 'suspended'; this.currentTime = 0; this.destination = {} }
      resume() { resumed++; this.state = 'running'; return Promise.resolve() }
      close() { return Promise.resolve() }
      createOscillator() { return { frequency: param(), connect() {}, start() {}, stop() {} } }
      createGain() { return { gain: param(), connect() {} } }
    }
    assert.equal(playSound('chirp', Ctx), true)
    assert.equal(resumed, 1)
  })

  /* HUM-24 (311427c6, CLE-35004's lead): the clock moved on while the resume
     was pending, so notes scheduled before it lay in the past - a short motif
     (pop / plain / chirp) never sounded */
  it('HUM-24: a suspended context schedules its notes from the clock AFTER the resume', async () => {
    const { LEAD_S } = await import('../../src/utils/notify.mjs')
    const param = () => ({ value: 0, setValueAtTime() {}, exponentialRampToValueAtTime() {} })
    for (const name of SOUND_NAMES) {
      const starts = []
      let resolve
      class Ctx {
        constructor() { this.state = 'suspended'; this.currentTime = 0; this.destination = {} }
        resume() { return new Promise((r) => { resolve = () => { this.state = 'running'; this.currentTime = 0.4; r() } }) }
        close() { return Promise.resolve() }
        createOscillator() { return { frequency: param(), connect() {}, start(t) { starts.push(t) }, stop() {} } }
        createGain() { return { gain: param(), connect() {} } }
      }
      assert.equal(playSound(name, Ctx, () => {}), true, name)
      assert.equal(starts.length, 0, `${name}: nothing scheduled on the frozen clock`)
      resolve()
      await new Promise((r) => setTimeout(r, 0))
      assert.ok(starts.length > 0 && starts.every((t) => t >= 0.4 + LEAD_S - 1e-9), `${name}: ${starts}`)
    }
  })

  /* HUM-24 (311427c6), third report: the bell read "alerts on" in a browser
     that was never asked, or that blocks notifications, and nothing said so */
  it('HUM-24: alertState names why an alert cannot fire', async () => {
    const { alertState, needsHomeScreen } = await import('../../src/utils/notify.mjs')
    assert.equal(alertState('granted', true), 'on')
    assert.equal(alertState('granted', false), 'off')
    assert.equal(alertState('default', true), 'ask')
    assert.equal(alertState('denied', true), 'blocked')
    assert.equal(alertState('denied', false), 'off')
    assert.equal(alertState('unsupported', true), 'unsupported')
    const iphone = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Version/17.5 Mobile/15E148 Safari/604.1'
    const ipad = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.5 Safari/605.1.15'
    assert.equal(alertState('unsupported', true, { ua: iphone }), 'install')
    assert.equal(alertState('unsupported', true, { ua: iphone, standalone: true }), 'unsupported')
    assert.equal(needsHomeScreen({ ua: ipad, maxTouchPoints: 5 }), true, 'an iPad reports itself as a Mac')
    assert.equal(needsHomeScreen({ ua: ipad, maxTouchPoints: 0 }), false, 'a real Mac')
    assert.equal(needsHomeScreen({ ua: 'Mozilla/5.0 (Linux; Android 14) Chrome/129 Mobile' }), false)
  })

  it('HUM-24: Settings shows the real state, can allow and test, and lists muted channels', () => {
    const vue = readFileSync(join(WUI, 'src/components/settings/notifications.vue'), 'utf8')
    for (const id of ['settings-notify-state', 'settings-notify-allow', 'settings-notify-test', 'settings-notify-muted']) {
      assert.match(vue, new RegExp(`data-test="${id}`), id)
    }
    const note = readFileSync(join(WUI, 'src/stores/notification.ts'), 'utf8')
    assert.match(note, /alertState\(permission\.value, alertsEnabled\.value/)
    /* a permission granted or revoked in the browser's site settings shows without a reload */
    assert.match(note, /visibilitychange/)
    /* the bell is on but the browser was never asked: the first click anywhere asks */
    assert.match(note, /askOnFirstGesture/)
  })

  /* HUM-24 (311427c6, msg 826e3ff8): pop / plain / chirp were silent on a
     phone - all three end before ~0.17 s, under Android's output latency,
     and the context was closed at the context-time end */
  it('HUM-24: the close waits for the output latency, and notes start after a lead-in', async () => {
    const { closeDelayMs, CLOSE_GRACE_S, LEAD_S } = await import('../../src/utils/notify.mjs')
    assert.equal(closeDelayMs({}), CLOSE_GRACE_S * 1000)
    assert.equal(closeDelayMs({ outputLatency: 0.3, baseLatency: 0.01 }), Math.round((0.3 + CLOSE_GRACE_S) * 1000))
    assert.equal(closeDelayMs({ baseLatency: 0.2 }), Math.round((0.2 + CLOSE_GRACE_S) * 1000))
    /* every library sound outlives a 0.3 s Bluetooth latency before its context closes */
    for (const name of SOUND_NAMES) {
      const end = Math.max(...SOUND_LIBRARY[name].segs.map((x) => (x.at || 0) + x.dur))
      assert.ok(CLOSE_GRACE_S > 0.3 + end, name)
    }
    const starts = []
    const param = () => ({ value: 0, setValueAtTime() {}, exponentialRampToValueAtTime() {} })
    class Ctx {
      constructor() { this.currentTime = 3; this.destination = {} }
      close() { return Promise.resolve() }
      createOscillator() { return { frequency: param(), connect() {}, start(t) { starts.push(t) }, stop() {} } }
      createGain() { return { gain: param(), connect() {} } }
    }
    for (const name of SOUND_NAMES) playSound(name, Ctx, () => {})
    assert.ok(starts.length > 0 && starts.every((t) => t >= 3 + LEAD_S - 1e-9), 'no note starts at the context\'s first sample')
  })
})
