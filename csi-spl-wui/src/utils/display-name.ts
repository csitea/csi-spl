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

/*
 * SPL-5707 (spec 154 section 12.5): the name is a first + last name and the
 * member keeps a phone. The hub is the authority (PUT preferences
 * first_name, last_name, phone; auth/profile.go); these mirror its
 * ValidNamePart, ValidPhone and SplitDisplayName so the form refuses what the
 * hub would, and display_name becomes the hub's join of the two.
 */

/** humans.first_name / last_name's CHECK (rdb 0290), in characters. */
const MAX_NAME_PART: number = 100

/** One name part: trimmed, one line, 1..100 characters. */
export function validNamePart(raw: unknown): { ok: boolean, name: string } {
  const v = validDisplayName(raw)
  if (!v.ok || [...v.name].length > MAX_NAME_PART) return { ok: false, name: '' }
  return v
}

/**
 * The international form only: spaces, '-', '.', '(' and ')' are dropped,
 * then '+', a first digit 1..9 and 7..15 digits in all (E.164).
 */
export function validPhone(raw: unknown): { ok: boolean, phone: string } {
  if (typeof raw !== 'string') return { ok: false, phone: '' }
  const s = raw.trim().replace(/[\s\-.()]/g, '')
  return /^\+[1-9][0-9]{6,14}$/.test(s) ? { ok: true, phone: s } : { ok: false, phone: '' }
}

/** The hub's split: the first word, then the rest (rdb 0290's backfill rule). */
export function splitDisplayName(name: unknown): { first: string, last: string } {
  const s = typeof name === 'string' ? name.trim() : ''
  const m = /^(\S+)\s*([\s\S]*)$/.exec(s)
  const cut = (x: string) => [...x].slice(0, MAX_NAME_PART).join('').trim()
  return m ? { first: cut(m[1] || ''), last: cut((m[2] || '').trim()) } : { first: '', last: '' }
}

export interface ProfileFields { first: string, last: string, phone: string }

type ProfileReason = 'invalid_name' | 'invalid_phone' | 'unchanged' | 'refused'

/** The form's fields checked and normalised as the hub would, or the reason. */
function checkProfile(raw: ProfileFields): { ok: true, v: ProfileFields } | { ok: false, reason: ProfileReason } {
  const first = validNamePart(raw.first)
  const lastText = String(raw.last ?? '').trim()
  const last = lastText ? validNamePart(lastText) : { ok: true, name: '' }
  if (!first.ok || !last.ok || [...(first.name + ' ' + last.name).trim()].length > MAX_DISPLAY_NAME) return { ok: false, reason: 'invalid_name' }
  const phoneText = String(raw.phone ?? '').trim()
  const phone = phoneText ? validPhone(phoneText) : { ok: true, phone: '' }
  if (!phone.ok) return { ok: false, reason: 'invalid_phone' }
  return { ok: true, v: { first: first.name, last: last.name, phone: phone.phone } }
}

/**
 * Validate, save the three together, then mirror the hub's display_name echo
 * into the session claims. Nothing is mirrored before the hub stored it.
 */
export async function applyProfile(
  raw: ProfileFields,
  { current, save, apply }: { current: ProfileFields, save: (v: ProfileFields) => Promise<{ ok: boolean, data?: unknown }>, apply: (name: string) => void },
): Promise<{ ok: boolean, v?: ProfileFields, reason?: ProfileReason, out?: unknown }> {
  const c = checkProfile(raw)
  if (!c.ok) return { ok: false, reason: c.reason }
  const cur = checkProfile(current)
  if (cur.ok && JSON.stringify(cur.v) === JSON.stringify(c.v)) return { ok: true, v: c.v, reason: 'unchanged' }
  let out: { ok: boolean, data?: unknown, error?: unknown }
  try {
    out = await save(c.v)
  } catch (e) {
    out = { ok: false, error: e }
  }
  if (!out || !out.ok) return { ok: false, reason: 'refused', out }
  const data = out.data as { display_name?: unknown } | null | undefined
  apply(data && typeof data.display_name === 'string' ? data.display_name : (c.v.first + ' ' + c.v.last).trim())
  return { ok: true, v: c.v }
}

export { sameNames } from './display-name-core'

