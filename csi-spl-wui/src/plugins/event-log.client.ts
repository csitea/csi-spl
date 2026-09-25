// event-log.client.ts — ship every error-journal record of a signed-in human
// to their personal event log (005 FR-017, contracts/events-v1.md, CLE-34990).
//
// Same contract as error-journal.client.ts: this plugin OBSERVES. It reads the
// journal, never writes it, and its own failures are silent (event-log.mjs
// talks to fetch directly and never calls noteError) — a POST that fails can
// never become an event, so there is no loop.
//
// Client-only: there is no session on the server and nothing to ship.
import { getErrors, subscribeErrors } from '@/composables/errorJournal.mjs'
import { bindShipperToJournal, createEventShipper, createEventsClient } from '~/utils/event-log.mjs'
import { useSessionStore } from '~/stores/session'

export default defineNuxtPlugin(() => {
  if (!import.meta.client) return
  const session = useSessionStore()
  const shipper = createEventShipper({
    client: createEventsClient({ base: useAuthBase() }),
    session: () => session.state,
  })
  bindShipperToJournal(shipper, { getErrors, subscribeErrors })
  watch(() => session.state, () => shipper.sessionChanged())
})
