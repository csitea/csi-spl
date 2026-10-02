// P3-02: the WUI's own "this browser last read signed out" hint, read by the
// document-head script (utils/signed-out-redirect-script.mjs) before any JS
// loads. The hub's session cookie is HttpOnly and stays the authority; this
// cookie carries no identity and nothing reads it but that script.
//
// Written by the session store: set when the session reads 'out', removed
// when it reads 'in'; removed too when a social sign-in leaves for the hub, so
// the page the hub lands on is not sent to /login. On a tenant host
// (<tenant>.<site>) it is a cookie of the site's domain, so the apex and the
// tenant hosts agree.

export const SIGNED_OUT_HINT_COOKIE = 'spl_so'
/** sessionStorage key: the head script sent this tab to /login (pages/login.vue continues when the session reads 'in'). */
export const EARLY_LOGIN_FLAG = 'spl:early-login'

const MAX_AGE = 30 * 24 * 3600

/**
 * The cookie's Domain attribute: the site host when this host is it or one of
 * its tenant hosts, '' (host-only) otherwise.
 * @param {string} hostname
 * @param {string} siteUrl
 */
export function hintDomain(hostname, siteUrl) {
  const h = String(hostname || '').toLowerCase()
  let site = ''
  try { site = siteUrl ? new URL(String(siteUrl)).hostname.toLowerCase() : '' } catch { site = '' }
  if (!site || !h || !site.includes('.')) return ''
  return h === site || h.endsWith(`.${site}`) ? site : ''
}

/**
 * Set (`out` true) or remove the hint on `doc`.
 * @param {{ cookie: string }} doc
 * @param {boolean} out
 * @param {{ hostname?: string, protocol?: string, siteUrl?: string }} [where]
 */
export function writeSignedOutHint(doc, out, where = {}) {
  if (!doc) return
  const domain = hintDomain(where.hostname, where.siteUrl)
  const tail = `; Path=/; SameSite=Lax${where.protocol === 'https:' ? '; Secure' : ''}`
  try {
    if (out) {
      doc.cookie = `${SIGNED_OUT_HINT_COOKIE}=1; Max-Age=${MAX_AGE}${domain ? `; Domain=${domain}` : ''}${tail}`
      return
    }
    // both shapes: a host-only one may predate the domain one
    doc.cookie = `${SIGNED_OUT_HINT_COOKIE}=; Max-Age=0${tail}`
    if (domain) doc.cookie = `${SIGNED_OUT_HINT_COOKIE}=; Max-Age=0; Domain=${domain}${tail}`
  } catch { /* cookies blocked: the hint is only an optimisation */ }
}

/** True once: the head script sent this tab to /login. */
export function takeEarlyLoginFlag(storage) {
  try {
    if (!storage || storage.getItem(EARLY_LOGIN_FLAG) !== '1') return false
    storage.removeItem(EARLY_LOGIN_FLAG)
    return true
  } catch {
    return false
  }
}
