/**
 * The chime's sounds and their player (051, CLE-35075, HUM-24). Split out of
 * notify.mjs so the initial JS does not carry them (027 ci_initial_gzip_kb,
 * SPL-3573): stores/notification.ts loads this module on the first chime,
 * the Settings picker imports it from its own lazy chunk.
 */

import { DEFAULT_SOUND } from './notify.mjs'

/**
 * 051: the sound the chime plays. Each is a short motif of one or more
 * oscillator segments, all generated in code — no audio files, no licensing,
 * nothing bundled (distribution hygiene). A segment:
 *   { type?, f, to?, dur, gain, at?, env? }
 * `type` is the oscillator wave (default sine); `f` the frequency; `to` an
 * exponential glide target over the segment; `dur` its length in seconds;
 * `gain` its peak; `at` a start offset from the motif's start; `env` a quick
 * attack/decay envelope (a bare gain clicks, an envelope pops or rings).
 * `plain` is the pre-051 880 Hz beep, kept as an explicit choice.
 *
 * HUM-24 (311427c6, msg d4c4c791, round 2): "the first three still do not
 * work" and "the sounds are the wrong length". Every sound was 0.10-0.24 s
 * long at -24..-28 dBFS peak. Measured on a PipeWire null sink (n=5 per
 * sound, cold and warm, c-028 2026-10-02): Chrome hands every one of them to
 * the sound server whole, so what is lost is lost after it - the device or its
 * amplifier waking. Chrome also stops its output stream after ~30 s of silence,
 * so no context kept open can keep a device awake between alerts. Each motif is
 * therefore 0.6-0.8 s, repeats its notes so a cut start still leaves most of it
 * heard, uses a harmonic wave (triangle / sawtooth, never a bare sine; small
 * speakers barely reproduce a pure tone below ~300 Hz) and peaks near -14 dBFS.
 */
export const SOUND_LIBRARY = {
  plain: { segs: [
    { type: 'triangle', f: 880, dur: 0.16, gain: 0.2, env: true },
    { type: 'triangle', f: 880, dur: 0.16, gain: 0.2, env: true, at: 0.24 },
    { type: 'triangle', f: 880, dur: 0.24, gain: 0.2, env: true, at: 0.48 },
  ] },
  pop: { segs: [
    { type: 'triangle', f: 1100, to: 420, dur: 0.12, gain: 0.22, env: true },
    { type: 'triangle', f: 1100, to: 420, dur: 0.12, gain: 0.22, env: true, at: 0.22 },
    { type: 'triangle', f: 1300, to: 480, dur: 0.16, gain: 0.22, env: true, at: 0.44 },
  ] },
  chirp: { segs: [
    { type: 'triangle', f: 660, dur: 0.12, gain: 0.2, env: true },
    { type: 'triangle', f: 990, dur: 0.14, gain: 0.2, env: true, at: 0.13 },
    { type: 'triangle', f: 660, dur: 0.12, gain: 0.2, env: true, at: 0.36 },
    { type: 'triangle', f: 990, dur: 0.24, gain: 0.2, env: true, at: 0.49 },
  ] },
  marimba: { segs: [
    { type: 'triangle', f: 523, dur: 0.3, gain: 0.16, env: true },
    { type: 'triangle', f: 659, dur: 0.3, gain: 0.16, env: true, at: 0.15 },
    { type: 'triangle', f: 784, dur: 0.45, gain: 0.16, env: true, at: 0.3 },
    { type: 'triangle', f: 1568, dur: 0.3, gain: 0.05, env: true, at: 0.3 },
  ] },
  boing: { segs: [
    { type: 'sawtooth', f: 420, to: 140, dur: 0.26, gain: 0.12, env: true },
    { type: 'sawtooth', f: 520, to: 160, dur: 0.38, gain: 0.12, env: true, at: 0.3 },
  ] },
}

/**
 * HUM-24 (311427c6, msg 826e3ff8: "only marimba and the cartoon sound work,
 * the other sound options are empty"): the context used to close the moment
 * its last oscillator ended IN CONTEXT TIME, but the speaker plays
 * `outputLatency` behind that clock (Android ~0.1-0.3 s, more on Bluetooth),
 * so the close threw away the audio still on its way out. Pop (0.10 s),
 * plain (0.12 s) and chirp (0.165 s) were dropped whole; marimba (0.20 s) and
 * boing (0.23 s) only lost their tail - exactly the three silent options.
 * The close now waits for the output latency plus this margin.
 */
export const CLOSE_GRACE_S = 1.5

/** How long after the last note ends (context time) the context may close, in ms. */
export function closeDelayMs(ctx) {
  const lat = Math.max(Number(ctx && ctx.outputLatency) || 0, Number(ctx && ctx.baseLatency) || 0)
  return Math.round((lat + CLOSE_GRACE_S) * 1000)
}

/* the first notes of a context just woken can be cut while the output starts.
   HUM-24 (311427c6, msg ddd345ea: "no, the others still don't work" on
   4.8.1): every chime opens a NEW context, so a new output stream, and a
   Bluetooth / Android audio route drops what plays while it wakes (~0.15-0.3
   s). Only the sounds longer than that (marimba 0.20 s, boing 0.23 s) got past
   it, so the notes start after silence. HUM-24 then (msg 3c310c8c): desktop
   Linux + Chrome, where PulseAudio / PipeWire wake an idle sink; on 4.8.1
   chirp ending at 0.215 s was lost and marimba ending at 0.25 s was heard,
   so her output drops ~0.2-0.23 s - the lead is the context's own reported
   latency plus 0.4 s (CLE-35004's numbers). */
export const LEAD_S = 0.4

/** Seconds from the context clock to the first note: its output latency + LEAD_S. */
export function leadFor(ctx) {
  const lat = Math.max(Number(ctx && ctx.outputLatency) || 0, Number(ctx && ctx.baseLatency) || 0)
  return lat + LEAD_S
}

/**
 * Play a named sound. One AudioContext per call, closed shortly after its
 * last oscillator ends — a context keeps an audio thread and buffers alive
 * for the life of the tab otherwise, one more per alert (CLE-35075).
 *
 * @param {string} name a key of SOUND_LIBRARY (unknown => DEFAULT_SOUND)
 * @param {(new () => any) | undefined} [Ctx] AudioContext (a test seam)
 * @param {(fn: () => void, ms: number) => unknown} [later] setTimeout (a test seam)
 * @returns {boolean} whether the sound was started
 */
export function playSound(name, Ctx = typeof AudioContext === 'undefined' ? undefined : AudioContext, later = setTimeout) {
  if (typeof Ctx !== 'function') return false
  const spec = SOUND_LIBRARY[name] || SOUND_LIBRARY[DEFAULT_SOUND]
  let ctx = null
  /* close() rejects on a context already closed or never running: the sound is
     over either way, so a failed close costs the reader nothing */
  const drop = () => { if (ctx) void Promise.resolve().then(() => ctx.close()).catch(() => {}) }
  /* the notes are scheduled from the clock as it reads when they can play */
  const schedule = () => {
    const t0 = ctx.currentTime + leadFor(ctx)
    let last = null
    let lastStop = t0
    for (const s of spec.segs) {
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      if (s.type) osc.type = s.type
      const start = t0 + (s.at || 0)
      const stop = start + s.dur
      if (s.to) {
        osc.frequency.setValueAtTime(s.f, start)
        osc.frequency.exponentialRampToValueAtTime(s.to, stop)
      } else {
        osc.frequency.value = s.f
      }
      if (s.env) {
        /* HUM-24 round 2: a fast attack, a gentle fall to a third, then the
           release - a straight fall from the peak left each note audible for
           only its first ~40 ms (measured -50 dBFS span 0.04-0.08 s) */
        gain.gain.setValueAtTime(0.0001, start)
        gain.gain.exponentialRampToValueAtTime(s.gain, start + 0.01)
        gain.gain.exponentialRampToValueAtTime(s.gain / 3, Math.max(start + 0.02, stop - 0.03))
        gain.gain.exponentialRampToValueAtTime(0.0001, stop)
      } else {
        gain.gain.value = s.gain
      }
      osc.connect(gain)
      gain.connect(ctx.destination)
      osc.start(start)
      osc.stop(stop)
      if (stop >= lastStop) { lastStop = stop; last = osc }
    }
    if (last) {
      last.onended = () => {
        /* the motif has played: a context that is already closed rejects close(), harmlessly */
        later(() => { void Promise.resolve(ctx.close()).catch(() => {}) }, closeDelayMs(ctx))
      }
    }
  }
  try {
    ctx = new Ctx()
    /* bug A: a context made outside a click starts `suspended` under the
       autoplay policy and plays nothing; resuming it is allowed once the
       page has had any click or key press.
       HUM-24 (311427c6, lead from CLE-35004): schedule only once the resume
       has resolved - notes scheduled from the clock BEFORE it may already lie
       in the past when it runs, and a short motif then never sounds */
    if (ctx.state === 'suspended' && typeof ctx.resume === 'function') {
      void Promise.resolve(ctx.resume())
        .then(() => schedule())
        .catch(drop)
      return true
    }
    schedule()
    return true
  } catch {
    /* autoplay policies */
    drop()
    return false
  }
}

/**
 * The pre-051 880 Hz beep, kept for back-compat: `playSound('plain', …)`.
 * @param {(new () => any) | undefined} [Ctx] AudioContext (a test seam)
 * @param {(fn: () => void, ms: number) => unknown} [later] setTimeout (a test seam)
 * @returns {boolean} whether a beep was started
 */
export function playChime(Ctx = typeof AudioContext === 'undefined' ? undefined : AudioContext, later = setTimeout) {
  return playSound('plain', Ctx, later)
}
