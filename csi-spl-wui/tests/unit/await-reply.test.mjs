// SPL-1994 (owner HUM-10, t1 72898ea2): the hourglass on a person's post, from
// the click on Send (SPL-2026), until an agent answers in that topic
// (src/utils/await-reply.mjs).
// Run: node tests/unit/await-reply.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import {
  AWAIT_ANIMATIONS, AWAIT_ANIM_IDS, AWAIT_ANIM_KEY, AWAIT_ROTATE_ORDER, AWAIT_ROTATE_STEP_MS, AWAIT_SHOW_MAX_MS,
  DEFAULT_AWAIT_ANIM, ROTATE_AWAIT_ANIM, awaitAnimKey, awaitAnimPick, awaitAnimation, createRotateClock, msToNextRotate, rotateAnimAt,
  awaitSpinMs, awaitState, isAgentPost, isPersonPost, nextAwaitChange, readAwaitAnim, writeAwaitAnim,
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
    assert.equal(awaitAnimation('hourglass').kind, 'css')
  })

  it('every entry is a css class or a clip with a src and a media type', () => {
    for (const [id, a] of Object.entries(AWAIT_ANIMATIONS)) {
      if (a.kind === 'css') assert.match(a.className, /^await-anim--[a-z0-9-]+$/, id)
      else {
        assert.equal(a.kind, 'clip', id)
        assert.ok(a.src && /^(image\/webp|video\/)/.test(a.type), id)
      }
    }
  })
})

// SPL-2027 (owner HUM-10, t1 72898ea2 msgs c4aae6fc, 1689b768, f7779032)
const VUE = readFileSync(new URL('../../src/components/AwaitReply.vue', import.meta.url), 'utf8')
const LOCALES = new URL('../../i18n/locales/', import.meta.url)

describe('SPL-2027: a running robot and a popping brain', () => {
  for (const id of ['robot', 'brain']) {
    it(`${id} is an entry, a css animation with its own class`, () => {
      assert.deepEqual(awaitAnimation(id), { id, kind: 'css', className: `await-anim--${id}` })
      assert.ok(AWAIT_ANIM_IDS.includes(id))
    })
    it(`${id} has its own drawing and keyframes in AwaitReply.vue`, () => {
      assert.ok(VUE.includes(`look.id === '${id}'`), 'drawing')
      assert.match(VUE, new RegExp(`@keyframes await-${id}\\b`), 'keyframes')
      assert.match(VUE, new RegExp(`\\.await-anim--${id}\\.await-reply--spin`), 'only while spinning')
    })
  }

  it('the pick list is rotate, then every entry, in order (a literal, kept off the entry chunk)', () => {
    assert.deepEqual([...AWAIT_ANIM_IDS], [ROTATE_AWAIT_ANIM, ...Object.keys(AWAIT_ANIMATIONS)])
  })

  it('reduced motion: every animation runs only under prefers-reduced-motion: no-preference', () => {
    const css = VUE.slice(VUE.indexOf('<style')).replace(/\/\*[\s\S]*?\*\//g, '')
    let outside = css
    for (const block of css.match(/@media \(prefers-reduced-motion: no-preference\) \{[\s\S]*?\n\}/g) || []) outside = outside.replace(block, '')
    assert.ok(css.length > outside.length, 'a no-preference block exists')
    assert.doesNotMatch(outside, /\banimation(-name)?:/, 'no animation outside the no-preference blocks')
  })

  it('SPL-2043: another 20% bigger (16.8 -> 20.16 px), inside the unchanged 16 px box; no :style (CSP)', () => {
    assert.match(VUE, /\.await-reply__glyph \{ inline-size: 20\.16px; block-size: 20\.16px;/)
    assert.equal((VUE.match(/width="20" height="20"/g) || []).length, 3, 'each svg drawing')
    assert.match(VUE, /inline-size: 16px;\n  block-size: 16px;/)
    assert.doesNotMatch(VUE, /:style=/)
  })

  it('every locale names the setting and each animation', () => {
    for (const f of readdirSync(LOCALES).filter((x) => x.endsWith('.json'))) {
      const a = JSON.parse(readFileSync(new URL(f, LOCALES), 'utf8')).settings?.await_anim || {}
      for (const k of ['label', ...AWAIT_ANIM_IDS]) assert.ok(String(a[k] || '').trim(), `${f} settings.await_anim.${k}`)
    }
  })
})

describe('SPL-2027: the per-person pick', () => {
  const ann = { hum: 'HUM-10', t: 't1' }
  const bob = { hum: 'HUM-24', t: 't1' }

  it('nothing stored: the default (rotate)', () => {
    assert.equal(readAwaitAnim(ann, memoryStore()), 'rotate')
  })

  it('a pick is read back, per person and tenant', () => {
    const store = memoryStore()
    assert.equal(writeAwaitAnim(ann, 'robot', store), 'robot')
    writeAwaitAnim(bob, 'brain', store)
    assert.equal(readAwaitAnim(ann, store), 'robot')
    assert.equal(readAwaitAnim(bob, store), 'brain')
    assert.equal(readAwaitAnim({ hum: 'HUM-10', t: 't2' }, store), 'rotate')
    assert.equal(store.getItem('spool-await-anim:t1:HUM-10'), 'robot')
  })

  it('an unknown id (stored or written) falls back to the default', () => {
    const store = memoryStore({ [awaitAnimKey(ann)]: 'unicorn' })
    assert.equal(readAwaitAnim(ann, store), 'rotate')
    assert.equal(writeAwaitAnim(ann, 'unicorn', store), 'rotate')
  })

  it('signed out: one browser-wide key', () => {
    assert.equal(awaitAnimKey(null), AWAIT_ANIM_KEY)
    assert.equal(awaitAnimKey({ hum: 'HUM-1' }), 'spool-await-anim:HUM-1')
  })

  it('a broken storage reads the default and never throws', () => {
    const broken = { getItem() { throw new Error('denied') }, setItem() { throw new Error('denied') } }
    assert.equal(readAwaitAnim(ann, broken), 'rotate')
    assert.equal(writeAwaitAnim(ann, 'brain', broken), 'brain')
  })
})

// SPL-2043 (owner HUM-10, t1 72898ea2 msgs c48092cf, 19feedf8): the drawings
// take turns, ~3 s each, all the time; rotate is the default pick.
describe('SPL-2043: rotate, the drawings in turn', () => {
  it('rotate is a pick, the default, listed first; a single pick stays a pick', () => {
    assert.equal(DEFAULT_AWAIT_ANIM, 'rotate')
    assert.equal(AWAIT_ANIM_IDS[0], 'rotate')
    for (const id of AWAIT_ANIM_IDS) assert.equal(awaitAnimPick(id), id)
    assert.equal(awaitAnimPick(''), 'rotate')
    assert.equal(awaitAnimPick('unicorn'), 'rotate')
  })

  it('the cycle order is hourglass -> robot -> brain -> hourglass, 3 s each', () => {
    assert.deepEqual([...AWAIT_ROTATE_ORDER], ['hourglass', 'robot', 'brain'])
    assert.equal(AWAIT_ROTATE_STEP_MS, 3000)
    const t0 = 3000 * 1000 * 3 /* a cycle start */
    const seen = [0, 2999, 3000, 5999, 6000, 8999, 9000].map((d) => rotateAnimAt(t0 + d))
    assert.deepEqual(seen, ['hourglass', 'hourglass', 'robot', 'robot', 'brain', 'brain', 'hourglass'])
    assert.equal(rotateAnimAt(NaN), 'hourglass')
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

  it('one clock: every mark on it shows the same drawing, stepping each 3 s', () => {
    const c = fakeClock(9000 * 1000 + 1000)
    const clock = createRotateClock(c)
    const a = []
    const b = []
    const offA = clock.subscribe((id) => a.push(id))
    c.advance(1000)
    const offB = clock.subscribe((id) => b.push(id))
    assert.equal(c.timers.size, 1, 'one timer for two marks')
    c.advance(2000) /* -> robot */
    c.advance(3000) /* -> brain */
    c.advance(3000) /* -> hourglass */
    assert.deepEqual(a, ['hourglass', 'robot', 'brain', 'hourglass'])
    assert.deepEqual(b, ['hourglass', 'robot', 'brain', 'hourglass'])
    offA()
    assert.equal(clock.running, true, 'still one listener')
    offB()
    assert.equal(clock.running, false)
    assert.equal(c.timers.size, 0, 'no timer left behind (unmount cleans up)')
    c.advance(30000)
    assert.equal(a.length + b.length, 8, 'nobody is called after leaving')
  })

  it('a mark joining mid-step sees the current drawing at once', () => {
    const c = fakeClock(9000 * 1000)
    const clock = createRotateClock(c)
    const off1 = clock.subscribe(() => {})
    c.advance(4000)
    let seen = null
    const off2 = clock.subscribe((id) => { seen = id })
    assert.equal(seen, 'robot')
    off1(); off2(); off2()
    assert.equal(c.timers.size, 0)
  })

  it('AwaitReply: rotate cycles only while spinning and motion is welcome, else the still hourglass', () => {
    assert.match(VUE, /rotating = computed\(\(\) => chosen\.value === ROTATE_AWAIT_ANIM && props\.state === 'spin' && !reduced\.value\)/)
    assert.match(VUE, /useAwaitRotate\(rotating\)/)
    assert.match(VUE, /addEventListener\?\.\('change', readMotion\)/, 'reduced motion switched on later stops the cycle')
    assert.match(VUE, /removeEventListener\?\.\('change', readMotion\)/)
    const comp = readFileSync(new URL('../../src/composables/useAwaitAnim.ts', import.meta.url), 'utf8')
    assert.match(comp, /active\.value \? rotateNow\.value : AWAIT_ROTATE_ORDER\[0\]/, 'inactive = the first drawing, still')
    assert.match(comp, /onScopeDispose\(off\)/, 'unsubscribed on unmount')
  })
})
