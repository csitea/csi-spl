// SPL-1994 (owner HUM-10, t1 72898ea2): the hourglass on a person's post, from
// the click on Send (SPL-2026), until an agent answers in that topic
// (src/utils/await-reply.mjs).
// Run: node tests/unit/await-reply.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { gzipSync } from 'node:zlib'
import {
  AWAIT_ANIMATIONS, AWAIT_ANIM_IDS, AWAIT_ANIM_KEY, AWAIT_ROTATE_STEP_MS, AWAIT_SHOW_MAX_MS, DEFAULT_AWAIT_SET, STILL_AWAIT_ANIM,
  awaitAnimKey, awaitAnimSet, awaitAnimation, awaitSetAt, createRotateClock, dropLegacyAwaitAnim, legacyAwaitSet, msToNextRotate,
  planAwaitMigration, rotateAnimAt, rotateStepAt, toggleAwaitAnim,
  awaitSpinMs, awaitState, isAgentPost, isPersonPost, nextAwaitChange,
} from '../../src/utils/await-reply.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

const T0 = Date.parse('2026-10-15T12:00:00Z')
const MIN = 60 * 1000
const at = (ms) => new Date(ms).toISOString()
const row = (id, from, ms, extra = {}) => ({ msg_id: id, task_id: 'task-1', from, ts: at(ms), received_at: at(ms), to: '@channel', ...extra })
const opts = (now, extra = {}) => ({ now, spinMs: 10 * MIN, ...extra })

describe('awaitState', () => {
  it('a received person post after an agent line spins, on that post', () => {
    const rows = [row('a1', 'c-001', T0 - 5 * MIN), row('h1', 'HUM-10', T0)]
    const s = awaitState(rows, opts(T0 + 1000))
    assert.equal(s?.state, 'spin')
    assert.equal(s?.msgId, 'h1')
    assert.equal(s?.taskId, 'task-1')
    assert.equal(s?.until, T0 + 10 * MIN)
  })

  it('the first agent post after it ends the wait', () => {
    const rows = [row('a1', 'c-001', T0 - 5 * MIN), row('h1', 'HUM-10', T0), row('a2', 'm-183', T0 + 30 * 1000)]
    assert.equal(awaitState(rows, opts(T0 + MIN)), null)
  })

  /* SPL-2026 (owner msg 8285fce1): "right after i click send" */
  it('pending -> spin: the post spins from the click, before the ack', () => {
    const rows = [row('a1', 'c-001', T0 - MIN), row('h1', 'HUM-10', T0, { pending: true })]
    const s = awaitState(rows, opts(T0))
    assert.equal(s?.state, 'spin')
    assert.equal(s?.msgId, 'h1')
  })

  it('acked -> spin: the same post keeps spinning once the hub has it', () => {
    const rows = [row('a1', 'c-001', T0 - MIN), row('h1', 'HUM-10', T0 + 80, { pending: false, cursor: 'c9' })]
    assert.equal(awaitState(rows, opts(T0 + 100))?.state, 'spin')
    assert.equal(awaitState(rows, opts(T0 + 100))?.msgId, 'h1')
  })

  it('answered -> none: an agent post after the sent one ends it', () => {
    const rows = [row('a1', 'c-001', T0 - MIN), row('h1', 'HUM-10', T0), row('a2', 'c-001', T0 + 2000)]
    assert.equal(awaitState(rows, opts(T0 + 3000)), null)
  })

  it('failed -> none: a send held for the network (waiting) never spins', () => {
    const rows = [row('a1', 'c-001', T0 - MIN), row('h1', 'HUM-10', T0, { pending: true, waiting: true })]
    assert.equal(awaitState(rows, opts(T0)), null)
  })

  it('failed -> none: a send the hub refused leaves no row, so the topic shows nothing', () => {
    /* stores/channel.ts + stores/live.ts drop the optimistic row (withoutMsg) on a hard failure */
    assert.equal(awaitState([row('a1', 'c-001', T0 - MIN)], opts(T0)), null)
  })

  it('a newer held-for-network post hides an older received one', () => {
    const rows = [row('a1', 'c-001', T0 - MIN), row('h1', 'HUM-10', T0), row('h2', 'HUM-10', T0 + 5000, { pending: true, waiting: true })]
    assert.equal(awaitState(rows, opts(T0 + 6000)), null)
  })

  it('a newer pending post carries the mark over an older received one', () => {
    const rows = [row('a1', 'c-001', T0 - MIN), row('h1', 'HUM-10', T0), row('h2', 'HUM-10', T0 + 5000, { pending: true })]
    assert.equal(awaitState(rows, opts(T0 + 6000))?.msgId, 'h2')
  })

  it('RED CONTROL: the SPL-1994 rule (pending = not received) gives no mark on a pending row', () => {
    /* the old rule, expressed through the new one: it treated every pending
       row like one the hub never got. The pending -> spin test above fails
       under it, which is what that test guards. */
    const oldRule = (rows, o) => awaitState(rows.map((m) => (m.pending ? { ...m, waiting: true } : m)), o)
    const rows = [row('a1', 'c-001', T0 - MIN), row('h1', 'HUM-10', T0, { pending: true })]
    assert.equal(oldRule(rows, opts(T0)), null)
    assert.notEqual(awaitState(rows, opts(T0)), null)
  })

  it('the newest of several person posts carries it', () => {
    const rows = [row('a1', 'c-001', T0 - MIN), row('h1', 'HUM-10', T0), row('h2', 'HUM-24', T0 + 2000)]
    assert.equal(awaitState(rows, opts(T0 + 3000))?.msgId, 'h2')
  })

  it('order of rows does not matter (newest-first feeds)', () => {
    const rows = [row('h1', 'HUM-10', T0), row('a1', 'c-001', T0 - MIN)]
    assert.equal(awaitState(rows, opts(T0))?.msgId, 'h1')
  })

  it('no agent in the topic: calm wait, never spin', () => {
    const rows = [row('h1', 'HUM-10', T0)]
    assert.equal(awaitState(rows, opts(T0 + 1000))?.state, 'wait')
  })

  it('a post addressed to an agent, or a channel with agents, spins', () => {
    assert.equal(awaitState([row('h1', 'HUM-10', T0, { to: 'c-001' })], opts(T0))?.state, 'spin')
    assert.equal(awaitState([row('h1', 'HUM-10', T0)], opts(T0, { agents: true }))?.state, 'spin')
  })

  it('after the cnf minutes the spin turns into a calm wait', () => {
    const rows = [row('a1', 'c-001', T0 - MIN), row('h1', 'HUM-10', T0)]
    assert.equal(awaitState(rows, opts(T0 + 10 * MIN - 1))?.state, 'spin')
    const s = awaitState(rows, opts(T0 + 10 * MIN))
    assert.equal(s?.state, 'wait')
    assert.equal(s?.until, T0 + AWAIT_SHOW_MAX_MS)
  })

  it('a day-old unanswered post is history: nothing', () => {
    const rows = [row('a1', 'c-001', T0 - MIN), row('h1', 'HUM-10', T0)]
    assert.equal(awaitState(rows, opts(T0 + AWAIT_SHOW_MAX_MS)), null)
  })

  it('CONTROL: a topic whose last word is an agent shows nothing', () => {
    const rows = [row('h1', 'HUM-10', T0 - MIN), row('a1', 'c-001', T0)]
    assert.equal(awaitState(rows, opts(T0 + 1000)), null)
  })

  it('a topic-list stand-in row is not a post', () => {
    assert.equal(awaitState([{ ...row('t1', 'HUM-10', T0), topic_row: true }], opts(T0)), null)
  })

  it('an agent line a person typed at its terminal is the person\'s', () => {
    const typed = row('h1', 'c-001', T0, { typed_by: 'HUM-10' })
    assert.equal(isPersonPost(typed), true)
    assert.equal(isAgentPost(typed), false)
    assert.equal(awaitState([row('a1', 'c-001', T0 - MIN), typed], opts(T0))?.msgId, 'h1')
  })

  it('a browser box or guest is no agent; a legacy id is one', () => {
    assert.equal(isAgentPost(row('x', 'BOX-1', T0)), false)
    assert.equal(isAgentPost(row('x', 'GST-3', T0)), false)
    assert.equal(isPersonPost(row('x', 'GST-3', T0)), true)
    assert.equal(isAgentPost(row('x', 'CLE-77952', T0)), true)
  })
})

describe('awaitSpinMs (cnf env.wui.await_reply_minutes)', () => {
  it('reads minutes, falls back to 10', () => {
    assert.equal(awaitSpinMs('3'), 3 * MIN)
    assert.equal(awaitSpinMs('0.5'), 30 * 1000)
    for (const bad of ['', '0', '-2', 'ten', undefined, null]) assert.equal(awaitSpinMs(bad), 10 * MIN, String(bad))
  })
})

describe('nextAwaitChange', () => {
  it('the soonest change, Infinity for none', () => {
    assert.equal(nextAwaitChange([null, { until: 5 }, { until: 3 }]), 3)
    assert.equal(nextAwaitChange([]), Infinity)
  })
})

describe('the animation seam', () => {
  it('the hourglass is the fallback drawing, a CSS animation by class', () => {
    assert.deepEqual(awaitAnimation(''), { id: 'hourglass', kind: 'css', className: 'await-anim--hourglass' })
    assert.equal(awaitAnimation('no-such').id, 'hourglass')
    assert.equal(STILL_AWAIT_ANIM, 'hourglass')
  })

  it('every entry is a css drawing with its own class', () => {
    for (const [id, a] of Object.entries(AWAIT_ANIMATIONS)) assert.deepEqual(a, { kind: 'css', className: `await-anim--${id}` }, id)
  })
})

// SPL-2113 (owner HUM-10, t1 3aa9fac2 msgs d45ec26e, c33a028e, 1ea9f107)
const VUE = readFileSync(new URL('../../src/components/AwaitReply.vue', import.meta.url), 'utf8')
const SETTING = readFileSync(new URL('../../src/components/AwaitAnimSetting.vue', import.meta.url), 'utf8')
const COMPOSABLE = readFileSync(new URL('../../src/composables/useAwaitAnim.ts', import.meta.url), 'utf8')
const DRAWING_DIR = new URL('../../src/components/await-anim/', import.meta.url)
const LOCALES = new URL('../../i18n/locales/', import.meta.url)
const fileOf = (id) => id.split('-').map((w) => w[0].toUpperCase() + w.slice(1)).join('') + '.vue'
/* the style block with comments dropped, and what is left outside its no-preference blocks */
const motionSplit = (src) => {
  const css = src.slice(src.indexOf('<style')).replace(/\/\*[\s\S]*?\*\//g, '')
  let outside = css
  for (const block of css.match(/@media \(prefers-reduced-motion: no-preference\) \{[\s\S]*?\n\}/g) || []) outside = outside.replace(block, '')
  return { css, outside }
}

describe('SPL-2113: 17 drawings, a dancing robot among them', () => {
  it('at least 15, the first three kept, a dancing robot; the list is the entries in order (a literal)', () => {
    assert.ok(AWAIT_ANIM_IDS.length >= 15, String(AWAIT_ANIM_IDS.length))
    assert.deepEqual(AWAIT_ANIM_IDS.slice(0, 3), ['hourglass', 'robot', 'brain'])
    assert.ok(AWAIT_ANIM_IDS.includes('dancing-robot'))
    assert.deepEqual([...AWAIT_ANIM_IDS], Object.keys(AWAIT_ANIMATIONS))
    assert.equal(new Set(AWAIT_ANIM_IDS).size, AWAIT_ANIM_IDS.length)
  })

  it('the hourglass is drawn in AwaitReply.vue; every other drawing is its own lazy component', () => {
    assert.match(VUE, /<svg v-if="look === 'hourglass'"/)
    assert.match(VUE, /@keyframes await-hourglass\b/)
    for (const id of AWAIT_ANIM_IDS.slice(1)) {
      assert.ok(VUE.includes(`'${id}': () => import('~/components/await-anim/${fileOf(id)}')`), `${id}: a dynamic import`)
      assert.ok(existsSync(new URL(fileOf(id), DRAWING_DIR)), `${id}: ${fileOf(id)}`)
    }
    assert.doesNotMatch(VUE, /^import .*await-anim\//m, 'no static import of a drawing')
  })

  for (const id of AWAIT_ANIM_IDS.slice(1)) {
    it(`${id}: code-drawn svg, its own keyframes, motion only while spinning and welcome, CSP-safe, <= 1.5 KB gzip`, () => {
      const src = readFileSync(new URL(fileOf(id), DRAWING_DIR), 'utf8')
      assert.match(src, /<svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">/)
      assert.doesNotMatch(src, /<(img|video|image)\b|url\(|href=|:style=|style="/, 'no file, no inline style')
      assert.match(src, new RegExp(`@keyframes await-${id}\\b`), 'its own keyframes')
      const { css, outside } = motionSplit(src)
      assert.ok(css.length > outside.length, 'a no-preference block exists')
      assert.doesNotMatch(outside, /\banimation(-name)?:/, 'no animation outside the no-preference blocks')
      for (const rule of css.match(/[^{}]+\{[^{}]*\banimation:[^{}]*\}/g) || []) assert.match(rule, /\.await-reply--spin /, `only while spinning: ${rule.trim().slice(0, 60)}`)
      assert.ok(gzipSync(src).length <= 1536, `${gzipSync(src).length} B gzip`)
    })
  }

  it('reduced motion: the hourglass animates only under prefers-reduced-motion: no-preference', () => {
    const { css, outside } = motionSplit(VUE)
    assert.ok(css.length > outside.length)
    assert.doesNotMatch(outside, /\banimation(-name)?:/)
  })

  it('SPL-2043: 20.16 px drawings in the unchanged 16 px box, the lazy ones too; no :style (CSP)', () => {
    assert.match(VUE, /\.await-reply__drawing :deep\(\.await-reply__glyph\) \{ inline-size: 20\.16px; block-size: 20\.16px;/)
    assert.match(VUE, /inline-size: 16px;\n  block-size: 16px;/)
    assert.doesNotMatch(VUE, /:style=/)
    assert.doesNotMatch(SETTING, /:style=/)
  })

  it('every locale names the setting, its hint and each animation', () => {
    for (const f of readdirSync(LOCALES).filter((x) => x.endsWith('.json'))) {
      const a = JSON.parse(readFileSync(new URL(f, LOCALES), 'utf8')).settings?.await_anim || {}
      for (const k of ['label', 'hint', ...AWAIT_ANIM_IDS]) assert.ok(String(a[k] || '').trim(), `${f} settings.await_anim.${k}`)
      assert.equal(a.rotate, undefined, `${f}: the old "take turns" choice is gone`)
    }
  })
})

describe('SPL-2113: the ticked set', () => {
  it('never picked (null, absent, junk): the default three', () => {
    assert.deepEqual([...DEFAULT_AWAIT_SET], ['hourglass', 'robot', 'brain'])
    for (const v of [null, undefined, [], 'robot', {}, ['unicorn']]) assert.deepEqual(awaitAnimSet(v), ['hourglass', 'robot', 'brain'], JSON.stringify(v))
  })

  it('known ids only, once each, in catalogue order', () => {
    assert.deepEqual(awaitAnimSet(['wave', 'unicorn', 'dots', 'wave']), ['dots', 'wave'])
    assert.deepEqual(awaitAnimSet(['dancing-robot']), ['dancing-robot'])
  })

  it('tick adds, untick removes, in catalogue order', () => {
    assert.deepEqual(toggleAwaitAnim(['hourglass', 'robot', 'brain'], 'dots', true), ['hourglass', 'robot', 'brain', 'dots'])
    assert.deepEqual(toggleAwaitAnim(['dots', 'wave'], 'hourglass', true), ['hourglass', 'dots', 'wave'])
    assert.deepEqual(toggleAwaitAnim(['hourglass', 'robot', 'brain'], 'robot', false), ['hourglass', 'brain'])
  })

  it('min 1: unticking the last one, an unknown id or a no-op hands back the same array', () => {
    const one = ['rocket']
    assert.equal(toggleAwaitAnim(one, 'rocket', false), one)
    const set = ['hourglass', 'robot']
    assert.equal(toggleAwaitAnim(set, 'unicorn', true), set)
    assert.equal(toggleAwaitAnim(set, 'robot', true), set)
    assert.equal(toggleAwaitAnim(set, 'dots', false), set)
  })
})

describe('SPL-2113: the ticked ones take turns, 3 s each (SPL-2043)', () => {
  it('the step is the wall clock / 3 s; a set is shown in turn from the step', () => {
    assert.equal(AWAIT_ROTATE_STEP_MS, 3000)
    assert.equal(rotateStepAt(9000), 3)
    assert.equal(rotateStepAt(NaN), 0)
    const t0 = 3000 * 1000 * 3 /* a cycle start of the default three */
    const seen = [0, 2999, 3000, 5999, 6000, 8999, 9000].map((d) => rotateAnimAt(t0 + d))
    assert.deepEqual(seen, ['hourglass', 'hourglass', 'robot', 'robot', 'brain', 'brain', 'hourglass'])
    assert.equal(rotateAnimAt(NaN), 'hourglass')
  })

  it('only the ticked ones take turns: two ticked alternate, nothing else ever shows', () => {
    const set = ['dancing-robot', 'rocket']
    const seen = Array.from({ length: 40 }, (_, n) => awaitSetAt(set, n))
    assert.deepEqual([...new Set(seen)], ['dancing-robot', 'rocket'])
    for (let n = 1; n < seen.length; n++) assert.notEqual(seen[n], seen[n - 1], `step ${n} alternates`)
    assert.deepEqual(Array.from({ length: 5 }, (_, n) => awaitSetAt(['wave'], n)), ['wave', 'wave', 'wave', 'wave', 'wave'])
    assert.equal(awaitSetAt(set, -1), 'rocket', 'a negative step stays in the set')
  })

  it('every ticked drawing gets its turn, in catalogue order, for a set of any size (no cap)', () => {
    const set = awaitAnimSet([...AWAIT_ANIM_IDS])
    assert.deepEqual(Array.from({ length: set.length }, (_, n) => awaitSetAt(set, n)), [...AWAIT_ANIM_IDS])
  })

  it('the next step is due at the next 3 s boundary', () => {
    assert.equal(msToNextRotate(9000), 3000)
    assert.equal(msToNextRotate(9001), 2999)
    assert.equal(msToNextRotate(11999), 1)
  })

  /* a fake clock: now is ours, timers are queued and fired by hand */
  function fakeClock(start) {
    const c = { t: start, timers: new Map(), seq: 0 }
    c.now = () => c.t
    c.setTimer = (fn, ms) => { const h = ++c.seq; c.timers.set(h, { fn, at: c.t + ms }); return h }
    c.clearTimer = (h) => { c.timers.delete(h) }
    c.advance = (ms) => {
      const end = c.t + ms
      for (;;) {
        const due = [...c.timers.entries()].filter(([, x]) => x.at <= end).sort((a, b) => a[1].at - b[1].at)[0]
        if (!due) break
        c.timers.delete(due[0])
        c.t = due[1].at
        due[1].fn()
      }
      c.t = end
    }
    return c
  }

  it('one clock: every mark on it gets the same step, each 3 s', () => {
    const c = fakeClock(9000 * 1000 + 1000)
    const clock = createRotateClock(c)
    const a = []
    const b = []
    const offA = clock.subscribe((n) => a.push(n))
    c.advance(1000)
    const offB = clock.subscribe((n) => b.push(n))
    assert.equal(c.timers.size, 1, 'one timer for two marks')
    c.advance(2000)
    c.advance(3000)
    c.advance(3000)
    assert.deepEqual(a, [3000, 3001, 3002, 3003])
    assert.deepEqual(b, [3000, 3001, 3002, 3003])
    assert.deepEqual(a.map((n) => awaitSetAt(['gears', 'orbit'], n)), ['gears', 'orbit', 'gears', 'orbit'])
    offA()
    assert.equal(clock.running, true, 'still one listener')
    offB()
    assert.equal(clock.running, false)
    assert.equal(c.timers.size, 0, 'no timer left behind (unmount cleans up)')
    c.advance(30000)
    assert.equal(a.length + b.length, 8, 'nobody is called after leaving')
  })

  it('a mark joining mid-step sees the current step at once', () => {
    const c = fakeClock(9000 * 1000)
    const clock = createRotateClock(c)
    const off1 = clock.subscribe(() => {})
    c.advance(4000)
    let seen = null
    const off2 = clock.subscribe((n) => { seen = n })
    assert.equal(seen, 3001)
    off1(); off2(); off2()
    assert.equal(c.timers.size, 0)
  })

  it('AwaitReply: turns only while spinning, motion welcome, two or more ticked; else the still hourglass', () => {
    assert.match(VUE, /const moving = computed\(\(\) => props\.state === 'spin' && !reduced\.value\)/)
    assert.match(VUE, /rotating = computed\(\(\) => !props\.anim && moving\.value && set\.value\.length > 1\)/)
    assert.match(VUE, /if \(!moving\.value\) return 'hourglass'/)
    assert.match(VUE, /useAwaitRotate\(rotating, set\)/)
    assert.match(VUE, /addEventListener\?\.\('change', readMotion\)/, 'reduced motion switched on later stops the turns')
    assert.match(VUE, /removeEventListener\?\.\('change', readMotion\)/)
    assert.match(COMPOSABLE, /active\.value \? awaitSetAt\(set\.value, rotateStep\.value\) : STILL_AWAIT_ANIM/, 'inactive = the still hourglass')
    assert.match(COMPOSABLE, /onScopeDispose\(off\)/, 'unsubscribed on unmount')
  })

  it('the setting: one checkbox per drawing, the last ticked one locked', () => {
    assert.match(SETTING, /v-for="id in ids"/)
    assert.match(SETTING, /type="checkbox"/)
    assert.match(SETTING, /set\.length === 1 && set\.includes\(id\)/)
    assert.match(SETTING, /<LazyAwaitReply state="spin" :anim="id" preview \/>/, 'each row its running sample')
  })
})

describe('SPL-2113: the old browser pick moves to the account once', () => {
  const ann = { hum: 'HUM-10', t: 't1' }

  it('the old pick as a set: take turns = the default three, one drawing = that one', () => {
    assert.deepEqual(legacyAwaitSet('rotate'), ['hourglass', 'robot', 'brain'])
    for (const id of ['hourglass', 'robot', 'brain']) assert.deepEqual(legacyAwaitSet(id), [id])
    for (const v of ['', null, 'unicorn', 'dots']) assert.equal(legacyAwaitSet(v), null, String(v))
  })

  it('an old pick and no pick in the account: migrate it, under the old per-person key', () => {
    const store = memoryStore({ 'spool-await-anim:t1:HUM-10': 'robot' })
    assert.deepEqual(planAwaitMigration(ann, store), { key: 'spool-await-anim:t1:HUM-10', set: ['robot'] })
    assert.deepEqual(planAwaitMigration({ ...ann, await_anims: null }, store), { key: 'spool-await-anim:t1:HUM-10', set: ['robot'] })
  })

  it('once: the account already holds a pick, nothing stored, or signed out = nothing to do', () => {
    const store = memoryStore({ 'spool-await-anim:t1:HUM-10': 'brain', [AWAIT_ANIM_KEY]: 'robot' })
    assert.equal(planAwaitMigration({ ...ann, await_anims: ['dots'] }, store), null)
    assert.equal(planAwaitMigration({ hum: 'HUM-24', t: 't1' }, store), null)
    assert.equal(planAwaitMigration(null, store), null)
    assert.equal(planAwaitMigration({ t: 't1' }, store), null)
  })

  it('an unusable old value: only the key is dropped', () => {
    const store = memoryStore({ 'spool-await-anim:t1:HUM-10': 'unicorn' })
    assert.deepEqual(planAwaitMigration(ann, store), { key: 'spool-await-anim:t1:HUM-10', set: null })
  })

  it('the old key is removed after the move, so the second visit has nothing to migrate', () => {
    const store = memoryStore({ 'spool-await-anim:t1:HUM-10': 'rotate' })
    const plan = planAwaitMigration(ann, store)
    assert.equal(dropLegacyAwaitAnim(plan.key, store), true)
    assert.equal(planAwaitMigration(ann, store), null)
    const broken = { getItem() { throw new Error('denied') }, removeItem() { throw new Error('denied') } }
    assert.equal(planAwaitMigration(ann, broken), null, 'a broken storage reads nothing, never throws')
    assert.equal(dropLegacyAwaitAnim('k', broken), false)
  })

  it('the keys stay as SPL-2027 wrote them', () => {
    assert.equal(awaitAnimKey(null), AWAIT_ANIM_KEY)
    assert.equal(awaitAnimKey({ hum: 'HUM-1' }), 'spool-await-anim:HUM-1')
    assert.equal(awaitAnimKey(ann), 'spool-await-anim:t1:HUM-10')
  })

  it('the composable migrates once per tab, keeps the old key when the save fails', () => {
    assert.match(COMPOSABLE, /if \(migrating \|\| !import\.meta\.client \|\| session\.state !== 'in'\) return/)
    assert.match(COMPOSABLE, /if \(out\.ok\) dropLegacyAwaitAnim\(plan\.key\)\n\s+else mirrorAwaitAnims\(session, null\)/)
  })
})
