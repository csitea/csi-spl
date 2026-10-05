/**
 * Latest-only request token (refactor round 3, row 8). A loader that writes
 * refs after an `await` takes a token first and writes only while it is
 * still the newest: a dialog re-opened for another message or person, or a
 * page reloaded under an in-flight "Load more", then drops the older answer
 * instead of showing it. The pattern `const mine = ++seq; ...; if (mine !==
 * seq) return` (pages/boxes/[id].vue) as one shared helper.
 *
 * @returns {{ next: () => number, isLatest: (token: number) => boolean }}
 */
export function createLatest() {
  let seq = 0
  return { next: () => ++seq, isLatest: (token) => token === seq }
}
