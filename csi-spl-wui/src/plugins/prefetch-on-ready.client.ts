// perf round 3 P3-04: a signed-out document ships its <link rel="prefetch">
// hints inside an inert <template id="spl-prefetch"> (nuxt.config's
// first-screen hints, utils/first-screen-hints.mjs deferDocumentPrefetch), so
// the sign-in form does not share the visitor's first seconds with ~83 app
// chunks. Once the page is ready (painted, then an idle moment) the hints go
// back into <head> and the browser prefetches them as before.
import { DEFERRED_PREFETCH_ID } from '~/utils/first-screen-hints.mjs'

export default defineNuxtPlugin(() => {
  onNuxtReady(() => {
    const held = document.getElementById(DEFERRED_PREFETCH_ID)
    if (!(held instanceof HTMLTemplateElement)) return
    document.head.appendChild(held.content)
    held.remove()
  })
})
