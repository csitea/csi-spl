// SPL-4624, spec 087 FR-001: Back onto /login with bfcache evicted reloads the
// document, and the prerendered HTML holds the sign-in card from its first byte,
// long before the lazy guard (useMobileStack guardStaleLogin) can leave it. This
// inline <head> script hides that document before the first paint when this
// browser holds a session; the guard then leaves, or shows it if signed out.
//
// Plain ES5 on purpose, like early-session-script.mjs: the text is inlined
// verbatim and its sha256 goes into the Hosting CSP. The timer keeps a failed
// guard chunk from leaving a blank page.
// Unit-tested by tests/unit/stale-login-hide-script.test.mjs.
import { MOBILE_LOGIN_PATH, MOBILE_STACK_QUERY } from './mobile-stack.mjs'
import { WAS_SIGNED_IN_KEY } from './session-recover.mjs'

export const STALE_LOGIN_HIDE_MAX_MS = 3000

/** @returns {string} JavaScript source for nuxt.config `app.head.script` */
export function buildStaleLoginHideScript() {
  return [
    '(function(){try{',
    'var n=performance.getEntriesByType("navigation")[0];',
    'if(!n||n.type!=="back_forward")return;',
    'if(!matchMedia(' + JSON.stringify(MOBILE_STACK_QUERY) + ').matches)return;',
    'if(!' + String(MOBILE_LOGIN_PATH) + '.test(location.pathname))return;',
    'if(localStorage.getItem(' + JSON.stringify(WAS_SIGNED_IN_KEY) + ')!=="1")return;',
    'var s=document.documentElement.style;s.visibility="hidden";',
    'setTimeout(function(){s.visibility=""},' + STALE_LOGIN_HIDE_MAX_MS + ');',
    '}catch(e){}})();',
  ].join('')
}
