// csi-spl-wui/src/utils/display-name.mjs
//
// The "Display name" field in Settings → Profile as pure,
// node-testable steps. The hub is the authority (PUT /api/v1/auth/preferences
// display_name, auth-v1 §3): these rules mirror its ValidDisplayName so the
// form refuses what the hub would, without a round trip, and the saved name is
// what the hub echoes back.

/** humans.display_name's CHECK (rdb 0006), counted in characters, not bytes. */
export const MAX_DISPLAY_NAME = 200

// C0, DEL, C1, and the line / paragraph separators: a name is one line.
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/

/**
 * @param {unknown} raw what the field holds
 * @returns {{ ok: boolean, name: string }} name is trimmed; '' when not ok
 */
export function validDisplayName(raw) {
  if (typeof raw !== 'string') return { ok: false, name: '' }
  const name = raw.trim()
  if (!name || CONTROL.test(name) || [...name].length > MAX_DISPLAY_NAME) return { ok: false, name: '' }
  return { ok: true, name }
}

/**
 * Validate, save, then mirror the saved name into the session claims so the
 * user menu and the profile card show it at once. Nothing is mirrored before
 * the hub stored it.
 *
 * @param {unknown} raw the field's text
 * @param {{ current: unknown, save: (name: string) => Promise<{ ok: boolean, data?: any }>,
 *           apply: (name: string) => void }} io
 * @returns {Promise<{ ok: boolean, name: string, reason?: 'invalid' | 'unchanged' | 'refused', out?: unknown }>}
 */
export async function applyDisplayName(raw, { current, save, apply }) {
  const v = validDisplayName(raw)
  if (!v.ok) return { ok: false, name: '', reason: 'invalid' }
  if (v.name === (typeof current === 'string' ? current.trim() : '')) return { ok: true, name: v.name, reason: 'unchanged' }
  let out
  try {
    out = await save(v.name)
  } catch (e) {
    out = { ok: false, error: e }
  }
  if (!out || !out.ok) return { ok: false, name: '', reason: 'refused', out }
  const echoed = out.data && typeof out.data.display_name === 'string' ? out.data.display_name : v.name
  apply(echoed)
  return { ok: true, name: echoed }
}
