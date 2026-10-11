// Which component a Vue error came from, and in which phase.
//
// A render error reaches the error journal as a bare DOM message: the owner's
// ERR-CLIENT-20261011-071556-99F1 ("Failed to execute 'insertBefore' on
// 'Node'") said nothing about where. Nuxt's vue:error hook also hands over the
// component instance and Vue's `info`; the journal record keeps both, in
// fields a render error leaves empty: `path` the component trail, `code` the
// phase (errorJournal.mjs buildErrorRecord redacts and caps both).
//
// Its own chunk (plugins/error-journal.client.ts imports it on the first Vue
// error): the initial JS is at its ceiling. Pure, no Vue: node tests import it.

/** Longest trail kept (the hub's `path` cap). */
export const MAX_TRAIL_CHARS = 200
const TRAIL_DEPTH = 12

function componentName(inst) {
  const t = inst.type
  const name = t && (typeof t === 'object' || typeof t === 'function') ? t.name || t.__name : ''
  return String(name || '').replace(/[^A-Za-z0-9_.-]/g, '') || 'Anonymous'
}

/**
 * The component trail of a Vue error, outermost first, innermost last:
 * `TopicPane/LiveFeed/MessageCard`. Takes the public instance Nuxt's hook
 * passes (or an internal one). When it would pass the cap the OUTER names go,
 * as `…/`: the innermost is the one that failed. '' without an instance.
 * @param {unknown} instance
 * @returns {string}
 */
export function vueComponentTrail(instance) {
  try {
    const names = []
    let inst = instance && typeof instance === 'object' && instance.$ ? instance.$ : instance
    while (inst && typeof inst === 'object' && names.length < TRAIL_DEPTH) {
      names.push(componentName(inst))
      inst = inst.parent
    }
    names.reverse()
    let out = names.join('/')
    while (out.length > MAX_TRAIL_CHARS && names.length > 1) {
      names.shift()
      out = '…/' + names.join('/')
    }
    return out.slice(0, MAX_TRAIL_CHARS)
  } catch {
    return ''
  }
}

/**
 * Vue's `info` for an error: a dev build says the phase ("render function"),
 * a production build links its error reference (…/error-reference/#runtime-1),
 * kept as `vue:runtime-1`. '' when there is none.
 * @param {unknown} info
 * @returns {string}
 */
export function vueErrorInfo(info) {
  try {
    if (info == null) return ''
    const s = String(info)
    const ref = /error-reference\/#([a-z]+-\d+)/.exec(s)
    return (ref ? `vue:${ref[1]}` : s).slice(0, 120)
  } catch {
    return ''
  }
}
