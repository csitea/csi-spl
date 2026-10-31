/**
 * SPL-4450: run `read` once the session is 'in', and again each time it
 * turns 'in' (a sign-out, then a sign-in). While it is 'loading', 'unknown'
 * or 'out' a member read is only a 401 in the console, so nothing runs.
 * `state` is a getter, `watch` is vue's (a parameter, so a node test runs it
 * on a plain ref).
 */
export function whenSignedIn(state, watch, read) {
  return watch(state, (now, before) => { if (now === 'in' && before !== 'in') read() }, { immediate: true })
}
