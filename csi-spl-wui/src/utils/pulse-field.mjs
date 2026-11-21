// The pulsating colour field behind the blog and the sign-in page (spec 111
// section 12, SPL-6140): the pure parts, so a unit test covers them without a
// browser. PulseField.client.vue draws with them.
//
// The colours are the theme's own: three CSS tokens read at runtime, never a
// literal brand colour. A token that is missing or unreadable falls back to
// the stop before it, and every stop to the first readable one.

/** The tokens, in gradient order: the two accents, then the warm one. */
export const PULSE_TOKENS = ['--color-accent', '--color-accent-2', '--color-warn']

/** Caps that keep the field cheap on any screen. */
export const PULSE_MAX_DASHES = 900
export const PULSE_MAX_DPR = 2
const PULSE_MIN_GAP = 22

/** "#rgb", "#rrggbb", "rgb(r, g, b)" or "rgba(r g b / a)" to [r, g, b] (0..255), else null. */
export function parsePulseColor(raw) {
  const s = String(raw ?? '').trim().toLowerCase()
  let m = /^#([0-9a-f]{3})$/.exec(s)
  if (m) return [...m[1]].map((c) => parseInt(c + c, 16))
  m = /^#([0-9a-f]{6})(?:[0-9a-f]{2})?$/.exec(s)
  if (m) return [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16))
  m = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/.exec(s)
  if (m) return [m[1], m[2], m[3]].map((v) => Math.max(0, Math.min(255, Math.round(Number(v)))))
  return null
}

/**
 * The three gradient stops from a token reader `get(name) -> string` (in the
 * browser: getComputedStyle(html).getPropertyValue). Each stop is [r, g, b];
 * null when no token parses (the caller then draws nothing).
 */
export function readPulseColors(get) {
  const parsed = PULSE_TOKENS.map((name) => {
    try { return parsePulseColor(get(name)) } catch { return null }
  })
  const first = parsed.find(Boolean)
  if (!first) return null
  const out = []
  for (let i = 0; i < parsed.length; i++) out.push(parsed[i] || out[i - 1] || first)
  return out
}

/** The colour at `p` (0..1) along the stops, as [r, g, b]. */
export function mixPulseStops(stops, p) {
  const t = Math.max(0, Math.min(1, p)) * (stops.length - 1)
  const i = Math.min(stops.length - 2, Math.floor(t))
  const f = t - i
  return stops[i].map((v, k) => Math.round(v + (stops[i + 1][k] - v) * f))
}

/** A small seeded generator, so a resize places the same field again. */
function pulseRandom(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/**
 * The dashes for a w x h (CSS px) field: a jittered grid, the gap widened so
 * the count never passes `max`. Each dash: x, y and a phase (0..2pi).
 */
export function placePulseDashes(w, h, max = PULSE_MAX_DASHES, seed = 7) {
  if (!(w > 0 && h > 0)) return []
  const gap = Math.max(PULSE_MIN_GAP, Math.sqrt((w * h) / max))
  const cols = Math.max(1, Math.floor(w / gap))
  const rows = Math.max(1, Math.floor(h / gap))
  const rnd = pulseRandom(seed)
  const out = []
  for (let r = 0; r < rows && out.length < max; r++) {
    for (let c = 0; c < cols && out.length < max; c++) {
      out.push({
        x: (c + 0.15 + rnd() * 0.7) * (w / cols),
        y: (r + 0.15 + rnd() * 0.7) * (h / rows),
        phase: rnd() * Math.PI * 2,
      })
    }
  }
  return out
}

/**
 * How large one dash is (0..1) at distance `d` from the centre, `reach` the
 * field's half diagonal: none near the centre (the content sits there) and
 * none at the far corners, fullest on a ring in between.
 */
export function pulseRingWeight(d, reach) {
  if (!(reach > 0)) return 0
  const u = d / reach
  const rise = Math.min(1, Math.max(0, (u - 0.12) / 0.3))
  const fall = Math.min(1, Math.max(0, (1.05 - u) / 0.45))
  return rise * fall
}

/** The canvas pixel ratio: the device's, capped. */
export function pulseDpr(raw) {
  const n = Number(raw)
  return Math.min(PULSE_MAX_DPR, n > 0 ? n : 1)
}
