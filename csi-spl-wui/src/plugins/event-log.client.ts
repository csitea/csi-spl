// event-log.client.ts — ship every error-journal record of a signed-in human
// to their personal event log (005 FR-017, contracts/events-v1.md).
//
// Same contract as error-journal.client.ts: this plugin OBSERVES. It reads the
// journal, never writes it, and its own failures are silent (event-log.mjs
// talks to fetch directly and never calls noteError) — a POST that fails can
// never become an event, so there is no loop.
//
// Client-only by file suffix: there is no session on the server and nothing
// to ship. Nuxt loads a *.client.ts plugin only in the client bundle, so an
// import.meta.client guard here is dead.
import { getErrors, subscribeErrors } from '@/composables/errorJournal.mjs'
import { useSessionStore } from '~/stores/session'

export default defineNuxtPlugin(() => {
  const session = useSessionStore()
  // 027 budget: the shipper (event-log.mjs) never renders and only observes,
  // so it rides a lazy chunk loaded after boot rather than the initial chunk.
  // The journal buffers every error until then, so bindShipperToJournal ships
  // the backlog and none is lost.
  void import('~/utils/event-log.mjs').then(({ bindShipperToJournal, createEventShipper, createEventsClient }) => {
    const shipper = createEventShipper({
      client: createEventsClient({ base: useAuthBase() }),
      session: () => session.state,
    })
    bindShipperToJournal(shipper, { getErrors, subscribeErrors })
    watch(() => session.state, () => shipper.sessionChanged())
  })
})
