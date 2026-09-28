// csi-spl-wui/src/utils/debug-pane.mjs
//
// The "Debug pane" checkbox in Settings → Appearance as a pure,
// node-testable step: flip the session claim at once so the DebugPanel at the
// bottom of the app appears or disappears without a reload, then save it to
// the hub (PUT /api/v1/auth/preferences diagnostics_enabled) and put the old
// value back when the hub refuses.
//
// The hub stays the authority: the next GET /api/v1/auth/session answers the
// stored value, so an optimistic flip the hub never took is corrected at the
// next probe even if this revert were skipped.

/**
 * @param {unknown} want the checkbox's new state; only the literal `true` ticks.
 * @param {{ current: unknown, apply: (on: boolean) => void,
 *           save: (on: boolean) => Promise<{ ok: boolean }> }} io
 * @returns {Promise<{ ok: boolean, value: boolean, out?: unknown }>}
 */
export async function applyDebugPaneSetting(want, { current, apply, save }) {
  const prev = current === true
  const next = want === true
  if (next === prev) return { ok: true, value: prev }
  apply(next)
  let out
  try {
    out = await save(next)
  } catch (e) {
    out = { ok: false, error: e }
  }
  if (out && out.ok) return { ok: true, value: next }
  apply(prev)
  return { ok: false, value: prev, out }
}
