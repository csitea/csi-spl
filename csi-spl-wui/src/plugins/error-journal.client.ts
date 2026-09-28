// error-journal.client.ts — feed the one error channel from everything that is
// not already a rendered error notice (ported from the donor WUI).
//
// Covers the rest of the tab: a component that throws during render, a
// navigation that fails, a script error, an unhandled promise rejection —
// failures that never reach the hub at all.
//
// Contract, and it is the important part: this plugin OBSERVES. It swallows
// nothing that was not already swallowed, re-throws nothing, and returns
// nothing that would stop Nuxt's own handling. Registering a listener must not
// change what the page does — only what is recorded about it.
//
// Client-only (`.client.ts`): there is no window on the server, and a
// build-time failure must never be baked into a static page.
import { noteError } from '@/composables/errorJournal.mjs'

/** Browser notices that arrive as window errors but are not defects. */
const BENIGN_WINDOW_ERRORS = [
  'ResizeObserver loop completed with undelivered notifications.',
  'ResizeObserver loop limit exceeded',
]

type MaybeError = { name?: unknown; message?: unknown; statusCode?: unknown } | undefined

function record(source: string, err: unknown, extra: Record<string, unknown> = {}): void {
  try {
    const e = (err ?? undefined) as MaybeError
    noteError({
      source,
      error: e,
      name: e && typeof e === 'object' ? e.name : undefined,
      message: e && typeof e === 'object' ? e.message : String(err ?? ''),
      status: e && typeof e === 'object' ? e.statusCode : undefined,
      ...extra,
    })
  } catch {
    // The recorder must never become the failure it is recording.
  }
}

export default defineNuxtPlugin((nuxtApp) => {
  if (!import.meta.client) return

  // Vue render / lifecycle errors. The hook is additive — Nuxt still runs its
  // own handler and the app still behaves exactly as before.
  nuxtApp.hook('vue:error', (err) => {
    record('vue', err)
  })

  // Nuxt app-level errors (navigation, plugin failures, showError()).
  nuxtApp.hook('app:error', (err) => {
    record('app', err)
  })

  // Anything else that reaches the window: a script error from a chunk that
  // failed to load, a third-party embed, a broken image handler.
  window.addEventListener('error', (ev: ErrorEvent) => {
    // Resource load failures (an <img>/<script> that 404s) arrive here with no
    // `error` and a target that is an element — those are noise, not defects,
    // and would flood a 50-slot buffer.
    if (!ev.error && ev.target && ev.target !== window) return
    // Chrome's "ResizeObserver loop completed with undelivered notifications"
    // (and the older "loop limit exceeded") is a notice, not a failure: the
    // observations it names are delivered in the next frame. It fires whenever
    // an observer on a feed sees the cards re-clip inside one delivery loop
    // (newest last follows the bottom that way, topic c6994436), and on prd
    // e2e the snackbar showed it to the reader as an error. Exact text only.
    if (!ev.error && BENIGN_WINDOW_ERRORS.includes(String(ev.message || ''))) return
    record('window', ev.error ?? { name: 'Error', message: ev.message }, {
      url: ev.filename || '',
    })
  })

  window.addEventListener('unhandledrejection', (ev: PromiseRejectionEvent) => {
    record('promise', ev.reason)
  })
})
