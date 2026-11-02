// SPL-4648: the navigation the router has started and not finished. A page that
// replaces its own query checks it first: a replace cancels a move on its way.
type NavTarget = { path: string }
let pending: NavTarget | null = null

export const navPending = (): NavTarget | null => pending
/** The router started a move to `to`. */
export function navStarted(to: NavTarget): void { pending = to }
/** The move to `to` ended, however; a later move stays marked. */
export function navEnded(to: NavTarget): void { if (pending === to) pending = null }
