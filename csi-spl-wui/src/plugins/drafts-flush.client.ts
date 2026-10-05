import { flushDraft } from '~/utils/drafts.mjs'

/*
 * 088 FR-001: `visibilitychange` -> hidden and `pagehide` are the last events
 * a phone page reliably gets before it is frozen or discarded; write the
 * composer's pending draft then instead of after its 300 ms debounce.
 */
export default defineNuxtPlugin(() => {
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') flushDraft()
  })
  window.addEventListener('pagehide', () => flushDraft())
})
