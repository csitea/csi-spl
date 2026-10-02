// P3-03 (perf audit round 3): start the session probe from the document.
//
// The probe used to leave from plugins/0.boot-early, once the entry chunk had
// downloaded, parsed and run: 166..214 ms after navigation on desktop and
// 603..645 ms on a phone (p50, n=10, dev). An inline <head> script fires the
// same GET at parse time and parks the promise on `window`; the session store
// adopts it (utils/early-session.mjs takeParkedSession), so the signed-in
// chain (session -> route -> channels -> Flow) starts that much earlier.
//
// Plain ES5 on purpose, like rootLocaleRedirect.mjs: the text is inlined
// verbatim and its sha256 goes into the Hosting CSP (the render hashes every
// inline block of the generated bundle). connect-src already admits the auth
// base. Unit-tested by tests/unit/early-session-script.test.mjs.
import { sessionProbeUrl } from './auth-client.mjs'

/** `window` key of the parked probe: `{ u: <url>, p: Promise<Response> }`. */
export const EARLY_SESSION_KEY = '__spoolEarlySession'

/**
 * The inline script for nuxt.config `app.head.script`. Same request as the
 * auth client's `session()` (credentials, no-store, a simple Accept header,
 * so a cross-origin auth base answers without a preflight).
 *
 * @param {{ authBase: string }} opts
 * @returns {string} JavaScript source
 */
export function buildEarlySessionScript(opts) {
  var url = JSON.stringify(sessionProbeUrl(opts.authBase))
  var key = JSON.stringify(EARLY_SESSION_KEY)
  return [
    '(function(){try{',
    'if(window.__spoolLeaving)return;',
    'if(!window.fetch)return;',
    'var u=' + url + ';',
    'var p=fetch(u,{credentials:"include",cache:"no-store",headers:{accept:"application/json"}});',
    'p.catch(function(){});',
    'window[' + key + ']={u:u,p:p};',
    '}catch(e){}})();',
  ].join('')
}
