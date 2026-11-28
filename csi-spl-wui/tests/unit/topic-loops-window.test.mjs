// Spec 182 v0.12 (SPL-6744; HUM-10, t1 0cf1d4cf msg 122b69a5: "every 60
// minutes, but only on working days between x and y time in 24 hours
// format"): the loop form's work window, its body, its row label and the
// mock twin of the hub's rules. The due-time walk is the hub's
// (store/topic_loop_window_test.go).
// Run: node tests/unit/topic-loops-window.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { emptyLoopForm, loopBody, loopForm, loopFormError, loopWindowLabel } from '../../src/utils/topic-loops.mjs'
import { mockAddTopicLoop, mockEditTopicLoop } from '../../src/utils/spool-client-mock.mjs'

const KEY = 'feed.topic_loops.'
const hourly = (over = {}) => ({ ...emptyLoopForm('Europe/Helsinki'), prompt: 'p', trigger: 'every_hour', ...over })

describe('the work window of a time trigger (v0.12)', () => {
  it('a new loop has no limit, and its body is the body of before', () => {
    const f = hourly()
    assert.deepEqual([f.workdays, f.windowOn, f.windowFrom, f.windowTo], [false, false, '08:00', '17:00'])
    assert.equal(loopFormError(f), '')
    assert.deepEqual(loopBody(f), { prompt: 'p', triggers: ['every_hour'] })
  })

  it('working days and a window: the body carries both and the zone', () => {
    const body = loopBody(hourly({ workdays: true, windowOn: true }))
    assert.deepEqual(body, { prompt: 'p', triggers: ['every_hour'], window_from: '08:00', window_to: '17:00', workdays_only: true, daily_tz: 'Europe/Helsinki' })
    const n = loopBody(hourly({ trigger: 'every_n_minutes', interval: 60, workdays: true }))
    assert.deepEqual([n.interval_min, n.window_from, n.window_to, n.workdays_only], [60, '', '', true])
  })

  it('HH:MM 24-hour bounds, From before To on one day; a known zone', () => {
    for (const [from, to] of [['22:00', '06:00'], ['08:00', '08:00'], ['8:00', '17:00'], ['08:00', '24:00'], ['', '17:00']]) {
      assert.equal(loopFormError(hourly({ windowOn: true, windowFrom: from, windowTo: to })), KEY + 'err_window', `${from}-${to}`)
    }
    assert.equal(loopFormError(hourly({ windowOn: true, windowFrom: '00:00', windowTo: '23:59' })), '')
    assert.equal(loopFormError(hourly({ workdays: true, dailyTz: 'Mars/Base' })), KEY + 'err_daily_tz')
    assert.equal(loopFormError(hourly({ windowOn: true, windowFrom: '22:00', windowTo: '06:00', trigger: 'blocker_posted' })), '', 'another trigger ignores the window')
  })

  it('a trigger that is not a timer never sends the window', () => {
    assert.deepEqual(loopBody(hourly({ trigger: 'blocker_posted', workdays: true, windowOn: true })), { prompt: 'p', triggers: ['blocker_posted'] })
  })

  it('Edit opens on the stored window; turning it off sends the clear', () => {
    const loop = { prompt: 'p', triggers: ['every_hour'], window_from: '09:00', window_to: '16:30', workdays_only: true, daily_tz: 'Europe/Riga' }
    const f = loopForm(loop, 'UTC')
    assert.deepEqual([f.workdays, f.windowOn, f.windowFrom, f.windowTo, f.dailyTz, f.hadWindow], [true, true, '09:00', '16:30', 'Europe/Riga', true])
    const off = loopBody({ ...f, workdays: false, windowOn: false })
    assert.deepEqual([off.window_from, off.window_to, off.workdays_only, off.daily_tz], ['', '', false, undefined])
    assert.equal(loopForm({ prompt: 'p', triggers: ['every_hour'] }).hadWindow, false)
  })

  it('the list row names the window', () => {
    assert.deepEqual(loopWindowLabel({ window_from: '08:00', window_to: '17:00', workdays_only: true, daily_tz: 'Europe/Helsinki' }),
      [KEY + 'window_row_both', { from: '08:00', to: '17:00', tz: 'Europe/Helsinki' }])
    assert.deepEqual(loopWindowLabel({ window_from: '08:00', window_to: '17:00' }), [KEY + 'window_row_hours', { from: '08:00', to: '17:00', tz: 'UTC' }])
    assert.deepEqual(loopWindowLabel({ workdays_only: true, daily_tz: 'Europe/Oslo' }), [KEY + 'window_row_days', { tz: 'Europe/Oslo' }])
    assert.equal(loopWindowLabel({ triggers: ['every_hour'] }), null)
  })

  it('the mock keeps the window through a pause, clears it with its trigger and refuses an overnight one', () => {
    const s = { me: { id: 'HUM-1' }, messages: [] }
    const a = mockAddTopicLoop(s, 't1', loopBody(hourly({ workdays: true, windowOn: true })))
    assert.deepEqual([a.window_from, a.window_to, a.workdays_only, a.daily_tz], ['08:00', '17:00', true, 'Europe/Helsinki'])
    const p = mockEditTopicLoop(s, 't1', a.loop_id, { state: 'paused' })
    assert.deepEqual([p.window_from, p.workdays_only], ['08:00', true])
    assert.throws(() => mockEditTopicLoop(s, 't1', a.loop_id, { window_from: '22:00', window_to: '06:00' }), (e) => e.status === 400 && e.token === 'bad_loop')
    const e = mockEditTopicLoop(s, 't1', a.loop_id, { triggers: ['blocker_posted'] })
    assert.deepEqual([e.window_from, e.workdays_only], [undefined, undefined])
  })
})
