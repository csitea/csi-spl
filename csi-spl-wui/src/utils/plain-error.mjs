// csi-spl-wui/src/utils/plain-error.mjs
//
// SPL-1839 (owner HUM-10, t1 659e3927, msg 4de3b04e): which ONE plain
// sentence a failure gets (components/PlainErrorNotice.vue, the snackbar row).
// The stores keep only the technical message ("spool 500 internal",
// "Failed to fetch"), so the class is read from it.
//
// Pure ES module, no Vue: the unit suite executes it under bare `node`.

/** A browser's whole words for "no HTTP answer" (Chrome, Firefox, Safari, RN). */
const OFFLINE_RE = /^(?:TypeError: )?(?:failed to fetch|load failed|network request failed|networkerror\b.*)$/i

/**
 * The HTTP status a failure carries: the rejection's `status`, else the
 * spool client's "spool <status> <token>" message. 0 = none known.
 * @param {unknown} message
 * @param {unknown} [error]
 * @returns {number}
 */
export function plainErrorStatus(message, error) {
  const s = Number(/** @type {{ status?: unknown } | null | undefined} */ (error)?.status)
  if (Number.isInteger(s) && s > 0) return s
  const m = /^spool (\d{3})\b/.exec(String(message || ''))
  return m ? Number(m[1]) : 0
}

/**
 * The plain_err.<kind> key a failure is told with:
 *   offline = no answer from the server (network, a dropped connection);
 *   slow    = the server or a gateway gave up (408, 503, 504);
 *   denied  = 401 / 403;
 *   load    = this screen's content could not be read (what = 'load');
 *   other   = anything else.
 * @param {number} status
 * @param {unknown} message
 * @param {unknown} [error]
 * @param {'load' | 'other'} [what]
 * @returns {'offline' | 'slow' | 'denied' | 'load' | 'other'}
 */
export function plainErrorKind(status, message, error, what = 'other') {
  const said = [message, /** @type {{ message?: unknown } | null | undefined} */ (error)?.message]
  if (!status && said.some((m) => OFFLINE_RE.test(String(m || '').trim()))) return 'offline'
  if (status === 408 || status === 503 || status === 504) return 'slow'
  if (status === 401 || status === 403) return 'denied'
  return what === 'load' ? 'load' : 'other'
}

/**
 * SPL-1839 test hook (mock only): localStorage `spool.mock.read-fault` =
 * `{ status, token, detail, only }` makes the mock topic read (`only:
 * 'topic'`), the mock feed read (`only: 'list'`) or both fail as the hub
 * would, so an e2e drives the real store and pane path.
 * @param {'topic' | 'list'} scope
 */
export function mockReadFault(scope) {
  let f = null
  try { f = JSON.parse(globalThis.localStorage?.getItem('spool.mock.read-fault') || 'null') } catch { f = null }
  if (!f || typeof f !== 'object' || (f.only && f.only !== scope)) return
  const status = Number(f.status) || 0
  const msg = status ? `spool ${status} ${f.token || scope}` : 'Failed to fetch'
  throw Object.assign(status ? new Error(msg) : new TypeError(msg), {
    status, token: String(f.token || ''), detail: String(f.detail || ''), mockFault: true,
  })
}
