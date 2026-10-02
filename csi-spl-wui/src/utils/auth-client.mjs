/**
 * Social sign-in client (specs/010-spool-social-auth/contracts/auth-v1.md §1–§4)
 * and native email + password sign-in (specs/015-spool-native-auth/contracts/native-auth-v1.md).
 * Every call goes to the AUTH BASE: the hub's API origin (runtime
 * NUXT_PUBLIC_AUTH_BASE, e.g. https://api.<domain>), cross-origin from the WUI
 * host with credentials, so the hub's session cookie (Domain = the shared
 * parent) rides along and the hub's credentialed CORS admits the WUI origin.
 * '' = same-origin (lde: the nitro devProxy serves /api/v1/auth/**).
 * The WUI never reads the session cookie; it asks GET /api/v1/auth/session.
 */

export const AUTH_PREFIX = '/api/v1/auth'

const ERRORS = {
  cancelled: 'Sign-in was cancelled.',
  invalid_state: 'That sign-in link expired — try again.',
  exchange_failed: 'The provider could not confirm you — try again.',
  email_unverified: 'Your account has no verified email with this provider — try another.',
  not_allowed: 'This account has no access here yet — ask your admin for an invite.',
  invite_expired: 'Your invitation has expired — ask your admin to send a new one.',
  unavailable: 'Sign-in is unavailable right now.',
}

/** native-auth-v1 §4 copy, plus the §2 400 details and 5xx fallbacks the forms can meet. */
const NATIVE_ERRORS = {
  invalid_credentials: 'Email or password is wrong.',
  email_unverified: 'Confirm your email first — we can send the link again.',
  not_allowed: 'This account has no access here yet — ask your admin for an invite.',
  invite_expired: 'Your invitation has expired — ask your admin to send a new one.',
  verification_token_invalid: 'That link is not valid any more.',
  verification_token_expired: 'That link expired — we can send a new one.',
  reset_token_invalid: 'That reset link is not valid any more — ask for a new one.',
  email_delivery_unavailable: 'We cannot send email right now — try again later.',
  rate_limited: 'Too many attempts — try again later.',
  unauthenticated: 'Your session ended — sign in again.',
  password_too_short: 'That password is too short.',
  email: 'Enter a valid email address.',
  unavailable: 'Sign-in is unavailable right now.',
  network: 'The hub did not answer — try again.',
}

const NAMES = { google: 'Google', facebook: 'Facebook', microsoft: 'Microsoft', linkedin: 'LinkedIn', xai: 'xAI' }

/** §2 copy; unknown codes get a generic line. Empty code → ''. */
export function authErrorMessage(code) {
  const c = String(code || '')
  if (!c) return ''
  return ERRORS[c] || 'Sign-in failed.'
}

/**
 * native-auth-v1 §1: "Too many attempts — try again in N minutes." for a
 * Retry-After in seconds; unknown / unparsable → the §4 generic line.
 */
export function retryAfterMessage(seconds) {
  const n = Number(seconds)
  if (!Number.isFinite(n) || n <= 0) return NATIVE_ERRORS.rate_limited
  if (n <= 60) return 'Too many attempts — try again in a minute.'
  const m = Math.ceil(n / 60)
  return `Too many attempts — try again in ${m} minutes.`
}

/**
 * Copy for a native call's failure ({ error, detail, retryAfter }). A 400
 * `bad_request` names the field in `detail` (`email`, `password_too_short` + min).
 */
export function nativeErrorMessage(out) {
  const o = out || {}
  const code = String(o.error || '')
  if (!code) return ''
  if (code === 'rate_limited') return retryAfterMessage(o.retryAfter)
  if (code === 'bad_request') {
    const d = String(o.detail || '')
    if (d.startsWith('password_too_short')) {
      const m = /(\d+)/.exec(d)
      return m ? `That password is too short — use at least ${m[1]} characters.` : NATIVE_ERRORS.password_too_short
    }
    if (d.startsWith('email')) return NATIVE_ERRORS.email
    return 'Check the form and try again.'
  }
  return NATIVE_ERRORS[code] || 'Something went wrong — try again.'
}

// ── spec 021: catalogue keys for the copy above ────────────────────────────
// The components render these through t(); the English functions above stay
// the canonical en source and tests/unit/auth-i18n-keys.test.mjs pins every
// i18n/locales/en.json value to them, so the two cannot drift.

/** { key, params } for authErrorMessage(code); null for an empty code. */
export function authErrorKey(code) {
  const c = String(code || '')
  if (!c) return null
  return { key: ERRORS[c] ? `auth.error.${c}` : 'auth.error.failed', params: {} }
}

/** { key, params } for retryAfterMessage(seconds). */
export function retryAfterKey(seconds) {
  const n = Number(seconds)
  if (!Number.isFinite(n) || n <= 0) return { key: 'auth.native_error.rate_limited', params: {} }
  if (n <= 60) return { key: 'auth.native_error.retry_minute', params: {} }
  return { key: 'auth.native_error.retry_minutes', params: { m: Math.ceil(n / 60) } }
}

/** { key, params } for nativeErrorMessage(out); null when there is no error. */
export function nativeErrorKey(out) {
  const o = out || {}
  const code = String(o.error || '')
  if (!code) return null
  if (code === 'rate_limited') return retryAfterKey(o.retryAfter)
  if (code === 'bad_request') {
    const d = String(o.detail || '')
    if (d.startsWith('password_too_short')) {
      const m = /(\d+)/.exec(d)
      return m
        ? { key: 'auth.native_error.password_too_short_min', params: { min: m[1] } }
        : { key: 'auth.native_error.password_too_short', params: {} }
    }
    if (d.startsWith('email')) return { key: 'auth.native_error.email', params: {} }
    return { key: 'auth.native_error.check_form', params: {} }
  }
  return { key: NATIVE_ERRORS[code] ? `auth.native_error.${code}` : 'auth.native_error.generic', params: {} }
}

/** Display name of a provider id: known brands spelled right, else capitalised. */
export function providerName(p) {
  const id = String(p || '')
  return NAMES[id] || (id.charAt(0).toUpperCase() + id.slice(1))
}

export function providerLabel(p) {
  return `Continue with ${providerName(p)}`
}

/**
 * A same-site path to land on after sign-in; anything else → '/' (the hub enforces the same).
 * Whitespace, a C0 control or DEL anywhere, or any backslash, is refused: the URL parser
 * drops tab / CR / LF and reads a backslash as '/', so "/<TAB>/evil.example"
 * is "//evil.example" to the browser, and NuxtLink (ufo hasProtocol) renders
 * it as an external link; ufo reads any whitespace there the same
 * way. The URL check is the backstop: whatever
 * survives must still resolve on this origin.
 */
export function safeRedirect(path) {
  const p = String(path || '')
  if (!p.startsWith('/') || p.startsWith('//') || /[\s\u0000-\u001f\u007f\\]/.test(p)) return '/'
  if (p.startsWith('/login')) return '/'
  // spec 021: the locale-prefixed sign-in page (/fi/login, /he/login?x) is /login too
  if (/^\/[a-z]{2}\/login(?:[/?#]|$)/i.test(p)) return '/'
  try {
    if (new URL(p, 'https://wui.invalid').origin !== 'https://wui.invalid') return '/'
  } catch {
    return '/'
  }
  return p
}

/**
 * The auth base as an origin: '' (same-origin) or http(s)://host[:port] with
 * no path. Anything else is refused as '' rather than sending the browser, or
 * the session cookie, somewhere unintended.
 */
export function authOrigin(base) {
  const b = String(base || '').trim().replace(/\/+$/, '')
  return /^https?:\/\/[a-z0-9.-]+(:\d+)?$/i.test(b) ? b : ''
}

/**
 * The §4 session probe's address. One source for the client below and the
 * document-head script that starts the same probe at parse time (P3-03,
 * utils/early-session-script.mjs): the app adopts the parked answer only when
 * the two addresses agree.
 */
export function sessionProbeUrl(base) {
  return `${authOrigin(base)}${AUTH_PREFIX}/session`
}

/**
 * §4: a plain link, no SDK. tenant only when it is a DNS label. The redirect
 * stays a WUI path: the hub lands on <APP_URL><redirect>, APP_URL = the WUI.
 */
export function startHref(provider, redirect, tenant, base = '', hint = '') {
  const q = new URLSearchParams({ redirect: safeRedirect(redirect) })
  const t = String(tenant || '')
  if (/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(t)) q.set('tenant', t)
  // SPL-1231: the invited address pre-selects that account at Google /
  // Microsoft (the hub forwards it only there). Never a credential.
  const h = loginHintOf(hint)
  if (h) q.set('login_hint', h)
  return `${authOrigin(base)}${AUTH_PREFIX}/${encodeURIComponent(String(provider))}/start?${q}`
}

/** SPL-1231: a plain e-mail address (lower-cased) usable as a sign-in hint, '' for anything else. */
export function loginHintOf(v) {
  const s = String(v || '').trim().toLowerCase()
  return s.length >= 3 && s.length <= 320 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s) ? s : ''
}

/**
 * SPL-1231: the sign-in an invited address most likely owns — 'google' for
 * Gmail, 'microsoft' for the Outlook family — or '' when it could be anything
 * (a work address may be Google Workspace, Microsoft 365 or a password).
 */
export function hintedProvider(email) {
  const d = loginHintOf(email).split('@')[1] || ''
  if (d === 'gmail.com' || d === 'googlemail.com') return 'google'
  if (/^(outlook|hotmail|live|msn)\.[a-z.]+$/.test(d)) return 'microsoft'
  return ''
}

/** in-flight GET /providers per fetch function and auth origin (loadProviders) */
const providersInFlight = new WeakMap()

export function createAuthClient({ fetchFn = globalThis.fetch, base = '', locale = () => '', sendLocale = false, mock = false } = {}) {
  const root = authOrigin(base)
  // 'include': the cookie must ride a cross-origin call to the auth base; it is
  // the same as 'same-origin' when the base is ''.
  // X-Locale (spec 021, the donor's header): browser fetch cannot override
  // Accept-Language, so the active UI locale rides here; the hub mails a
  // person who has no stored preference in it. OFF unless `sendLocale`: the
  // header is non-simple, so a cross-origin call preflights, and a hub whose
  // CORS allow-list lacks X-Locale refuses EVERY auth call (2e2c601 broke
  // sign-in on dev + prd exactly so). Turn it on only where the hub admits it.
  // Even then it rides only a write: the hub reads it in the native
  // POST handlers that mail, never on a GET, and on GET /session it made the
  // probe every cold load waits for preflight first (one extra round trip,
  // ~380 ms on dev).
  const call = (path, opts) => {
    const write = String((opts && opts.method) || 'GET').toUpperCase() !== 'GET'
    const loc = sendLocale && write ? String((typeof locale === 'function' ? locale() : locale) || '') : ''
    return fetchFn(`${root}${AUTH_PREFIX}${path}`, {
      credentials: 'include',
      ...opts,
      headers: { accept: 'application/json', ...(loc ? { 'x-locale': loc } : {}), ...(opts && opts.headers) },
    })
  }

  /**
   * The registry read WITH its outcome, so "auth is off in this env" (status
   * 'ok', empty list) is told apart from "the hub could not be asked" (status
   * 'unavailable': non-2xx, network, bad JSON). `reason` is the HTTP status or
   * 'network' / 'bad_json'; '' when ok.
   */
  /* /login mounts SocialAuthButtons AND NativeAuthForm, and each asked the
     registry on mount: two identical GETs per load (CLE-35076's probe,
     CLE-35075). Callers in flight at the same moment share one read; each
     gets its own copy, and a later mount reads afresh. */
  function loadProviders() {
    const key = typeof fetchFn === 'function' ? fetchFn : providersInFlight
    let joins = providersInFlight.get(key)
    if (!joins) providersInFlight.set(key, (joins = new Map()))
    let p = joins.get(root)
    if (!p) {
      p = readProviders().finally(() => { joins.delete(root) })
      joins.set(root, p)
    }
    return p.then((out) => ({ ...out, providers: [...out.providers] }))
  }

  async function readProviders() {
    let res
    try {
      res = await call('/providers')
    } catch {
      return { status: 'unavailable', reason: 'network', providers: [], native: false }
    }
    if (!res.ok) return { status: 'unavailable', reason: String(res.status), providers: [], native: false }
    try {
      const data = await res.json()
      const list = Array.isArray(data && data.providers) ? data.providers.map(String) : []
      // native-auth-v1: "native": true sits next to the social list only when on
      return { status: 'ok', reason: '', providers: list, native: Boolean(data && data.native === true) }
    } catch {
      return { status: 'unavailable', reason: 'bad_json', providers: [], native: false }
    }
  }

  /**
   * native-auth-v1 §2: POST a JSON body. Resolves (never throws) to
   * { ok, status, data, error, detail, retryAfter }: `error` is the envelope
   * token, 'network' when the hub was not reached, 'unavailable' for a non-JSON
   * failure; `retryAfter` is the 429 Retry-After in seconds (0 when absent).
   */
  async function post(path, body, method = 'POST') {
    let res
    try {
      res = await call(path, {
        method,
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body || {}),
      })
    } catch {
      return { ok: false, status: 0, data: null, error: 'network', detail: '', retryAfter: 0 }
    }
    let data = null
    if (res.status !== 204) {
      try { data = await res.json() } catch { data = null }
    }
    if (res.ok) return { ok: true, status: res.status, data, error: '', detail: '', retryAfter: 0 }
    const ra = res.headers && typeof res.headers.get === 'function' ? Number(res.headers.get('retry-after')) : 0
    return {
      ok: false,
      status: res.status,
      data,
      error: String((data && data.error) || (res.status === 429 ? 'rate_limited' : 'unavailable')),
      detail: String((data && data.detail) || ''),
      retryAfter: Number.isFinite(ra) && ra > 0 ? ra : 0,
    }
  }

  return {
    loadProviders,
    /** Enabled providers in cnf order; [] = auth off (or unreachable → also []). */
    async providers() {
      return (await loadProviders()).providers
    },
    /**
     * §4 signed-in probe: 200 → 'in', 401 → 'out', anything else (5xx, network,
     * bad JSON) → 'unknown' — keep state, never treat as signed out.
     * `pending` is the same GET already in flight (the head script's, P3-03):
     * its answer is read instead; if it failed, the probe is sent again here.
     */
    async session(pending) {
      if (mock) {
        // specs/054 e2e: signed-out by default; signed-in only when the act-as
        // spec opts in (so the login specs are untouched). Live never takes this.
        const { mockSessionGet } = await import('./act-as-mock.mjs')
        const claims = mockSessionGet()
        // 'unknown' with no opt-in, exactly as the pre-054 mock answered (its
        // /session probe 404'd), so the other e2e specs are byte-for-byte the same.
        return claims ? { state: 'in', claims } : { state: 'unknown', claims: null }
      }
      let res
      try {
        const ask = () => call('/session', { cache: 'no-store' })
        res = await (pending ? Promise.resolve(pending).catch(ask) : ask())
      } catch {
        return { state: 'unknown', claims: null }
      }
      if (res.status === 401) return { state: 'out', claims: null }
      if (res.status !== 200) return { state: 'unknown', claims: null }
      try {
        return { state: 'in', claims: await res.json() }
      } catch {
        return { state: 'unknown', claims: null }
      }
    },
    /** §2 register; also "resend": the same email + password mails a fresh link. */
    register({ email, password, name } = {}) {
      const b = { email: String(email || ''), password: String(password || '') }
      if (name) b.name = String(name)
      return post('/register', b)
    },
    /** the password the link was issued for rides with the token. */
    verifyEmail({ token, password } = {}) {
      return post('/email/verify', { token: String(token || ''), password: String(password || '') })
    },
    /** 200 → `data` is the session claims plus the guarded `redirect`. */
    login({ email, password, tenant, redirect } = {}) {
      const b = { email: String(email || ''), password: String(password || ''), redirect: safeRedirect(redirect) }
      const t = String(tenant || '')
      if (/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(t)) b.tenant = t
      return post('/login', b)
    },
    forgotPassword(email) {
      return post('/password/forgot', { email: String(email || '') })
    },
    resetPassword({ token, password } = {}) {
      return post('/password/reset', { token: String(token || ''), password: String(password || '') })
    },
    /** 204 clears the cookie: the caller signs in again with the new password. */
    changePassword({ current, next } = {}) {
      return post('/password/change', { current_password: String(current || ''), new_password: String(next || '') })
    },
    /**
     * spec 021: store the signed-in human's preferred UI + mail language.
     * 204/200 → ok; 400 = unsupported code; 401 = no session.
     */
    savePreferences({ preferred_locale } = {}) {
      return post('/preferences', { preferred_locale: String(preferred_locale || '') }, 'PUT')
    },
    /**
     * store the signed-in human's "Debug pane" checkbox. Sends
     * ONLY that key (the language is left as it is) and only a real boolean.
     * 200 → ok; 400 = not a boolean; 401 = no session; 409 = no human.
     */
    saveDiagnostics(on) {
      return post('/preferences', { diagnostics_enabled: on === true }, 'PUT')
    },
    /**
     * store the signed-in human's display name. Sends ONLY that
     * key. 200 → `data.display_name` is the stored (trimmed) name; 400
     * invalid_display_name; 401 = no session; 409 = no human.
     */
    saveDisplayName(name) {
      return post('/preferences', { display_name: String(name ?? '') }, 'PUT')
    },
    /**
     * CLE-77794: Settings → Profile "Interests" (humans.interests, rdb 0086),
     * shown on the person's card in the People section. Sends ONLY that key:
     * the free text, or null to clear it. 200 → `data.interests` is the stored
     * value (null when cleared); 400 invalid_interests; 401; 409 = no human.
     */
    saveInterests(interests) {
      const v = String(interests ?? '').trim()
      return post('/preferences', { interests: v === '' ? null : v }, 'PUT')
    },
    /**
     * keep the palette pick on the account (humans.preferred_theme,
     * the field an operator sets with do_spl_human_theme). Sends ONLY that
     * key. 200 → ok; 400 unsupported_theme; 401 = no session; 409 = no human.
     */
    saveTheme(theme) {
      return post('/preferences', { preferred_theme: String(theme || '') }, 'PUT')
    },
    /**
     * SPL-976: Settings -> Behaviour "Text fields" (humans.submit_key, the
     * field do_spl_human_behaviour sets). Sends ONLY that key. 200 → ok;
     * 400 unsupported_submit_key; 401 = no session; 409 = no human.
     */
    saveSubmitKey(key) {
      return post('/preferences', { submit_key: String(key || '') }, 'PUT')
    },
    /**
     * SPL-979: Settings -> Behaviour "Left panel order" (humans.rail_order).
     * Sends ONLY that key: the six rail ids in order, or null for the
     * default. 200 → ok; 400 unsupported_rail_order; 401; 409 = no human.
     */
    saveRailOrder(order) {
      return post('/preferences', { rail_order: Array.isArray(order) ? order.map(String) : null }, 'PUT')
    },
    /**
     * Topic c6994436: Settings -> Behaviour "Message order" / "Omnibox
     * position" (humans.message_order / composer_position, rdb 0070). `key`
     * is 'message_order' or 'composer_position'; sends ONLY that key, null
     * clears it. 200 → ok; 400 unsupported_<key>; 401; 409 = no human.
     */
    saveViewPref(key, value) {
      return post('/preferences', { [String(key)]: value ? String(value) : null }, 'PUT')
    },
    /**
     * SPL-1132: the Issues sheet's column widths (humans.issues_columns, rdb
     * 0076). Sends ONLY that key: an object of column -> whole px, or null
     * (an empty object too) for the automatic layout. 200 → ok; 400
     * unsupported_issues_columns; 401; 409 = no human.
     */
    saveIssueColumns(cols) {
      const obj = cols && typeof cols === 'object' && !Array.isArray(cols) && Object.keys(cols).length ? cols : null
      return post('/preferences', { issues_columns: obj }, 'PUT')
    },
    // SPL-1181: Issues list default sort, per tenant (rdb 0078); null clears.
    saveIssuesSort(sort) {
      const v = sort && sort.col && sort.dir ? { col: String(sort.col), dir: String(sort.dir) } : null
      return post('/preferences', { issues_sort: v }, 'PUT')
    },
    // CLE-77908: the person's time zone in this workspace, per tenant (rdb 0078);
    // null clears it (back to the browser's zone).
    saveTimeZone(zone) {
      const v = typeof zone === 'string' && zone.trim() ? zone.trim() : null
      return post('/preferences', { time_zone: v }, 'PUT')
    },
    // SPL-1182: the two divider widths, per tenant (rdb 0078); null clears.
    savePaneSizes(sizes) {
      const obj = sizes && typeof sizes === 'object' && !Array.isArray(sizes) && Object.keys(sizes).length ? sizes : null
      return post('/preferences', { pane_sizes: obj }, 'PUT')
    },
    /**
     * specs/026 §6: make `tenant` the session's active tenant (the hub
     * re-issues the cookie). 200 → `data` is the new session; 403
     * not_member; 401 = no session.
     */
    switchTenant(tenant) {
      return post('/tenant', { tenant: String(tenant || '') })
    },
    /**
     * specs/054: start acting as a member. 200 → this browser's cookie is now
     * the clone (data = { clone_hum, target, expires_at }); 403 forbidden /
     * not_member (the ceiling); 401 = no session.
     */
    async actAsStart(humanId) {
      const id = String(humanId || '')
      if (mock) {
        // OPT-IN e2e mock: record the act-as so me() reports it (the hub's
        // cookie swap has no analogue with no hub). Live builds never take this.
        const { mockActAsSet } = await import('./act-as-mock.mjs')
        mockActAsSet({ target_hum: id, expires_at: '' })
        return { ok: true, status: 200, data: { clone_hum: 'HUM-clone', target: id }, error: '', detail: '', retryAfter: 0 }
      }
      return post('/act-as', { human_id: id })
    },
    /** specs/054: stop acting (sign-out of the clone). 204 → the cookie is cleared. */
    async actAsExit() {
      if (mock) {
        const { mockActAsClear } = await import('./act-as-mock.mjs')
        mockActAsClear()
        return true
      }
      const res = await call('/act-as/exit', { method: 'POST' })
      return res.status === 204 || res.ok
    },
    async logout() {
      if (mock) {
        // clear the opt-in mock session + any act-as so a reload is signed out
        const { mockSessionClear, mockActAsClear } = await import('./act-as-mock.mjs')
        mockSessionClear()
        mockActAsClear()
        return true
      }
      const res = await call('/logout', { method: 'POST' })
      return res.status === 204 || res.ok
    },
  }
}
