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
import { APP_UPDATED_NOTE, createChunkNoteFilter } from '~/utils/chunk-note'
import { chunkReloadsThisLoad } from '~/utils/chunk-reload'

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
  // own handler and the app still behaves exactly as before. The record names
  // the component (path) and Vue's phase (code): a bare DOM message such as
  // ERR-CLIENT-20261011-071556-99F1's insertBefore says nothing about where.
  // The trail helper is its own chunk (the initial JS is at its ceiling): the
  // record waits for it, and is written without the trail if it cannot load.
  // A stale chunk after a deploy is not a defect: chunk-reload reloads the
  // tab, and the journal keeps one info note per page load (SPL-4525). Only
  // when chunk-reload reloads: offline or inside its 10 s guard the failure
  // stays an error, so chunk-reload's own decision is asked.
  // SPL-5742 (F1): ONE rule for every source below. vue:error alone asked it,
  // so the same stale chunk came back as `promise`, `app` and `window` rows.
  const chunkNote = createChunkNoteFilter(chunkReloadsThisLoad)
  /** True when `err` is a stale chunk chunk-reload reloads for: the one note, never an error. */
  function asAppUpdate(err: unknown): boolean {
    const kind = chunkNote(err)
    if (kind === 'note') record('app-update', undefined, APP_UPDATED_NOTE)
    return kind !== 'error'
  }
  nuxtApp.hook('vue:error', (err, instance, info) => {
    if (asAppUpdate(err)) return
    void import('~/utils/vue-error-trail.mjs').then(
      (m) => record('vue', err, { trail: m.vueComponentTrail(instance), code: m.vueErrorInfo(info) || undefined }),
      () => record('vue', err),
    )
  })

  // Nuxt app-level errors (navigation, plugin failures, showError()). Hookable
  // runs this handler in a promise, after showError() has set the error, so
  // it is not ordered before error.vue: error.vue asks chunkReloadsThisLoad()
  // itself and keeps its notice silent for a stale chunk; the note is here.
  nuxtApp.hook('app:error', (err) => {
    if (asAppUpdate(err)) return
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
    const err = ev.error ?? { name: 'Error', message: ev.message }
    if (asAppUpdate(err)) return
    record('window', err, { url: ev.filename || '' })
  })

  // chunk-reload.client.ts reloads the tab for a chunk rejection; the journal
  // keeps the note for it, as for vue:error.
  window.addEventListener('unhandledrejection', (ev: PromiseRejectionEvent) => {
    if (asAppUpdate(ev.reason)) return
    record('promise', ev.reason)
  })
})
