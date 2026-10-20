// csi-spl-wui/src/utils/display-name.ts
//
// The "Display name" field in Settings → Profile as pure,
// node-testable steps. The hub is the authority (PUT /api/v1/auth/preferences
// display_name, auth-v1 §3): these rules mirror its ValidDisplayName so the
// form refuses what the hub would, without a round trip, and the saved name is
// what the hub echoes back.

/** humans.display_name's CHECK (rdb 0006), counted in characters, not bytes. */
export const MAX_DISPLAY_NAME: number = 200

// C0, DEL, C1, and the line / paragraph separators: a name is one line.
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/

/**
 * @param raw what the field holds
 * @returns name is trimmed; '' when not ok
 */
export function validDisplayName(raw: unknown): { ok: boolean, name: string } {
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
 * @param raw the field's text
 */
export async function applyDisplayName(
  raw: unknown,
  { current, save, apply }: { current: unknown, save: (name: string) => Promise<{ ok: boolean, data?: unknown }>, apply: (name: string) => void },
): Promise<{ ok: boolean, name: string, reason?: 'invalid' | 'unchanged' | 'refused', out?: unknown }> {
  const v = validDisplayName(raw)
  if (!v.ok) return { ok: false, name: '', reason: 'invalid' }
  if (v.name === (typeof current === 'string' ? current.trim() : '')) return { ok: true, name: v.name, reason: 'unchanged' }
  let out: { ok: boolean, data?: unknown, error?: unknown }
  try {
    out = await save(v.name)
  } catch (e) {
    out = { ok: false, error: e }
  }
  if (!out || !out.ok) return { ok: false, name: '', reason: 'refused', out }
  const data = out.data as { display_name?: unknown } | null | undefined
  const echoed = data && typeof data.display_name === 'string' ? data.display_name : v.name
  apply(echoed)
  return { ok: true, name: echoed }
}

/**
 * Two id -> display name maps hold the same pairs (key order ignored).
 * useHumanNames compared two JSON.stringify strings per mount for this.
 */
export function sameNames(a: Record<string, string> | null | undefined, b: Record<string, string> | null | undefined): boolean {
  const x = a || {}
  const y = b || {}
  const keys = Object.keys(x)
  if (keys.length !== Object.keys(y).length) return false
  for (const k of keys) {
    if (!Object.prototype.hasOwnProperty.call(y, k) || x[k] !== y[k]) return false
  }
  return true
}
