// Spec 072 A3 (research 06 W1): the WUI reads its env values at runtime from a
// served `/config.json`, in the shape Element Web uses (research 19), so ONE
// `nuxt generate` serves any domain, tenant and env. Both carriers write it:
// the compose web image renders it from its env at container start
// (src/docker/wui-config.sh), the Hosting deploy (wf 30) writes it per env
// next to build.json. Values baked by the build (NUXT_PUBLIC_*) stay only as
// the lde defaults: a key the file leaves out keeps the baked value, and no
// file at all (lde, an older deploy) keeps the whole baked config.
//
// The document head starts the fetch at parse time (buildEarlyConfigScript)
// and parks the promise on `window`; the pre plugin
// plugins/0.0.runtime-config.client.ts adopts it, merges the file into
// useRuntimeConfig().public, and only then do the other plugins run.
//
// Plain ES5 in the inline script on purpose (rootLocaleRedirect.mjs): its
// sha256 goes into the Hosting CSP. Unit-tested by
// tests/unit/runtime-config.test.mjs.

/** The served file. Same origin: connect-src 'self' admits it. */
export const RUNTIME_CONFIG_PATH = '/config.json'

/** `window` key of the parked fetch: Promise<object | null>. */
export const EARLY_CONFIG_KEY = '__spoolConfig'

/**
 * The keys a `config.json` may set, and their kind. Anything else in the file
 * is ignored: the build owns the rest (version, mock mode, build stamp).
 * `base` = an http(s) origin or "" (trailing slashes dropped); `flag` = "0" /
 * "1"; `text` = a short string with no space or quote. The default locale is
 * NOT one: it decides which routes the build prefixes, so it stays a build
 * value (NUXT_PUBLIC_DEFAULT_LOCALE).
 */
export const RUNTIME_CONFIG_KEYS = Object.freeze({
  apiBase: 'base',
  authBase: 'base',
  siteUrl: 'base',
  tenant: 'text',
  tenantHosts: 'flag',
  envName: 'text',
  lobbyTaskId: 'text',
  perfRum: 'flag',
  perfSampleRate: 'text',
  // HUM-10: cnf env.wui.repo_* (commit links, /help repo links, the
  // connect-agent clone); "" = that link is hidden, never a fallback repo
  repoWebUrl: 'base',
  repoCloneUrl: 'base',
  repoCommitPath: 'text',
  repoHelpPath: 'text',
})

// {tenant} stays legal in a base: the lde / legacy tenant-host template
const BASE_RE = /^https?:\/\/[a-z0-9.{}-]+(:\d+)?(\/[^\s"'<>]*)?$/i
const TEXT_RE = /^[^\s"'<>]{0,128}$/

function cleanValue(kind, raw) {
  if (raw === null || raw === undefined) return undefined
  if (typeof raw === 'boolean' && kind === 'flag') return raw ? '1' : '0'
  if (typeof raw !== 'string' && typeof raw !== 'number') return undefined
  const s = String(raw).trim()
  if (kind === 'flag') {
    if (s === '1' || s === 'true') return '1'
    if (s === '0' || s === 'false' || s === '') return '0'
    return undefined
  }
  if (kind === 'base') {
    const b = s.replace(/\/+$/, '')
    return b === '' || BASE_RE.test(b) ? b : undefined
  }
  return TEXT_RE.test(s) ? s : undefined
}

/**
 * Merge a parsed `config.json` into the public runtime config, in place.
 * Only RUNTIME_CONFIG_KEYS are taken; a value of the wrong shape is skipped
 * (the baked one stays) and named in `rejected`.
 * @param {Record<string, any>} pub useRuntimeConfig().public
 * @param {any} raw the parsed file, or null when there is none
 * @returns {{ applied: string[], rejected: string[] }}
 */
export function applyRuntimeConfig(pub, raw) {
  const applied = []
  const rejected = []
  if (!pub || !raw || typeof raw !== 'object' || Array.isArray(raw)) return { applied, rejected }
  for (const key of Object.keys(RUNTIME_CONFIG_KEYS)) {
    if (!Object.prototype.hasOwnProperty.call(raw, key)) continue
    const v = cleanValue(RUNTIME_CONFIG_KEYS[key], raw[key])
    if (v === undefined) {
      rejected.push(key)
      continue
    }
    pub[key] = v
    applied.push(key)
  }
  return { applied, rejected }
}

/**
 * The api base when neither the build nor the file names one: the page's own
 * origin. The compose stack serves the hub on the WUI's origin (Caddy), so a
 * bundle built with no NUXT_PUBLIC_API_BASE works there with no file at all.
 * @param {Record<string, any>} pub
 * @param {string} origin window.location.origin
 */
export function defaultApiBase(pub, origin) {
  if (!pub || String(pub.apiBase || '').trim()) return
  const o = String(origin || '')
  if (/^https?:\/\/[^/]+$/i.test(o)) pub.apiBase = o
}

/**
 * The parsed body of a `config.json` response, or null: a 404, the Hosting
 * SPA fallback (an HTML page with status 200) and a broken file all read as
 * "no file", so the baked config stays.
 * @param {{ ok?: boolean, json?: () => Promise<any> } | null | undefined} res
 */
export async function readConfigResponse(res) {
  if (!res || !res.ok || typeof res.json !== 'function') return null
  try {
    const body = await res.json()
    return body && typeof body === 'object' && !Array.isArray(body) ? body : null
  } catch {
    return null
  }
}

/**
 * The inline head script: fetch `/config.json` at parse time and park the
 * parsed body (or null) on `window[EARLY_CONFIG_KEY]`. Revalidated, never a
 * stale copy: a domain change must reach the next page load.
 * @returns {string} JavaScript source
 */
export function buildEarlyConfigScript() {
  var key = JSON.stringify(EARLY_CONFIG_KEY)
  var path = JSON.stringify(RUNTIME_CONFIG_PATH)
  return [
    '(function(){try{',
    'if(!window.fetch)return;',
    'window[' + key + ']=fetch(' + path + ',{cache:"no-cache",headers:{accept:"application/json"}})',
    '.then(function(r){return r&&r.ok?r.json():null})',
    '.then(function(b){return b&&typeof b==="object"&&!Array.isArray(b)?b:null})',
    '.catch(function(){return null});',
    '}catch(e){}})();',
  ].join('')
}

/**
 * The head script's parked config, once; else a fresh fetch. Never rejects:
 * no file reads as null.
 * @param {any} win
 * @param {typeof fetch | undefined} fetchFn
 * @returns {Promise<any>}
 */
export function takeParkedConfig(win, fetchFn) {
  const parked = win && win[EARLY_CONFIG_KEY]
  if (win) win[EARLY_CONFIG_KEY] = undefined
  if (parked && typeof parked.then === 'function') return parked.then((b) => b, () => null)
  if (typeof fetchFn !== 'function') return Promise.resolve(null)
  return fetchFn(RUNTIME_CONFIG_PATH, { cache: 'no-cache', headers: { accept: 'application/json' } })
    .then(readConfigResponse, () => null)
}
