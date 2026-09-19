/**
 * Top-right user control (CLE-3402), shaped after the reference storefront's
 * header account control: the signed-in person's avatar, a dropdown with who
 * they are, Settings and Sign out; signed out, the sign-in entry.
 *
 * Pure helpers only — the component (UserMenu.vue) and the Settings page read
 * the session claims (auth-v1 §4 /api/v1/auth/session) through these, so the
 * decisions are unit-tested without a DOM.
 */

const MEMBER_RE = /^HUM-\d+$/

/** Claims → what the menu shows. Every field is a string ('' when absent). */
export function userIdentity(claims) {
  const c = claims && typeof claims === 'object' ? claims : {}
  const s = (v) => (typeof v === 'string' ? v.trim() : '')
  const hum = MEMBER_RE.test(s(c.hum)) ? s(c.hum) : ''
  const name = s(c.name)
  const email = s(c.email)
  const primary = name || email || hum
  // the second line never repeats the first
  const secondary = [email, hum].find((v) => v && v !== primary) || ''
  return { hum, name, email, method: s(c.p), tenant: s(c.t), primary, secondary }
}

/**
 * One or two letters for a person with no member id (no identicon to draw):
 * first letters of the first and last name, else the first two of the name,
 * else of the email's local part; '' → the default silhouette.
 */
export function userInitials(claims) {
  const { name, email } = userIdentity(claims)
  const words = name.split(/\s+/).filter(Boolean)
  if (words.length >= 2) return (firstChar(words[0]) + firstChar(words[words.length - 1])).toUpperCase()
  if (words.length === 1) return [...words[0]].slice(0, 2).join('').toUpperCase()
  const local = email.split('@')[0] || email
  return [...local].slice(0, 2).join('').toUpperCase()
}

function firstChar(w) {
  return [...w][0] || ''
}

/** What the avatar draws: the member's identicon/IdP picture, initials, or the silhouette. */
export function avatarMode(claims) {
  if (userIdentity(claims).hum) return 'member'
  return userInitials(claims) ? 'initials' : 'silhouette'
}

const METHOD_LABEL = { password: 'Email and password', google: 'Google', microsoft: 'Microsoft', facebook: 'Facebook' }

/** Session claim `p` (the sign-in provider) in words. */
export function methodLabel(p) {
  const k = String(p || '').trim().toLowerCase()
  if (!k) return 'Unknown'
  return METHOD_LABEL[k] || k.charAt(0).toUpperCase() + k.slice(1)
}

/** Button name for screen readers: "Account menu for <who>". */
export function menuButtonLabel(claims) {
  const { primary } = userIdentity(claims)
  return primary ? `Account menu for ${primary}` : 'Account menu'
}

// ── spec 021: catalogue keys for the copy above ────────────────────────────
// The components render these through t(); the English functions above stay
// the en source and tests/unit/user-menu.test.mjs pins the pairing.

/** { key, params } for methodLabel(p): brand / provider names ride as {name}. */
export function methodLabelKey(p) {
  const k = String(p || '').trim().toLowerCase()
  if (!k) return { key: 'user_menu.method_unknown', params: {} }
  if (k === 'password') return { key: 'user_menu.method_password', params: {} }
  return { key: 'user_menu.method_named', params: { name: methodLabel(p) } }
}

/** { key, params } for menuButtonLabel(claims). */
export function menuButtonLabelKey(claims) {
  const { primary } = userIdentity(claims)
  return primary
    ? { key: 'user_menu.account_menu_for', params: { who: primary } }
    : { key: 'user_menu.account_menu', params: {} }
}

/**
 * WAI-ARIA menu-button keys: the next focused item index, or -1 to close.
 * Arrow keys wrap; Home/End jump; Escape and Tab close.
 */
export function nextMenuIndex(current, key, count) {
  if (count <= 0) return -1
  const at = Number.isInteger(current) && current >= 0 && current < count ? current : -1
  switch (key) {
    case 'ArrowDown': return at < 0 ? 0 : (at + 1) % count
    case 'ArrowUp': return at < 0 ? count - 1 : (at - 1 + count) % count
    case 'Home': return 0
    case 'End': return count - 1
    case 'Escape':
    case 'Tab': return -1
    default: return at
  }
}

/**
 * The path to come back to after sign-in: same-origin, never /login itself,
 * nor its locale-prefixed form (/fi/login, spec 021).
 */
export function signInRedirect(fullPath) {
  const p = String(fullPath || '/')
  return p.startsWith('/') && !p.startsWith('//') && !/^(?:\/[a-z]{2})?\/login(?:[/?#]|$)/i.test(p) ? p : '/'
}
