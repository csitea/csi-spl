// Bidi control handling, split out of code-blocks.mjs so a first-paint caller
// (a display name is stripped of bidi controls, channel-feed.mjs) does not drag
// the whole markdown renderer into the initial chunk (027 perf budget).
// code-blocks.mjs re-exports stripBidiControls and reuses BIDI_CLASS for its
// URL grammar; this module imports nothing.

/**
 * Bidi embedding / override / isolate controls (U+202A..U+202E, U+2066..U+2069)
 * and the ALM/LRM/RLM marks (the hub refuses the same set, 323c76e5).
 * They are invisible and reorder the text around them, so a display name drops
 * them (stripBidiControls) and a link ends before one.
 */
export const BIDI_CLASS = String.raw`\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069`
const BIDI_RE = new RegExp(`[${BIDI_CLASS}]`, "g")

/** The string without bidi controls: for one-line labels such as display names. */
export function stripBidiControls(s) {
  return String(s ?? "").replace(BIDI_RE, "")
}
