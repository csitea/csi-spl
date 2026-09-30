import { effectScope } from 'vue'
import { personLabel } from '~/utils/channel-feed.mjs'
import { sameNames } from '~/utils/display-name.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'

/* One sign-in watcher and one in-flight read for the whole tab (CLE-35075).
   Every card, avatar, badge and text run calls useHumanNames() - about seven
   per card - and each call used to add its own session watcher, so a sign-in
   forgot the roster read and read it again once PER INSTANCE. */
let wired = false
let inFlight: Promise<void> | null = null

/**
 * The display names members chose (Settings > Profile), from the roster the
 * avatars already read. `label(id, box)` is the name, or the id when there is
 * none. `refresh()` re-reads it at once, e.g. after the reader renames
 * themself.
 */
export function useHumanNames() {
  const api = useSpoolApi()
  const names = useState<Record<string, string>>('spool.human-names', () => ({}))

  function load(force = false): Promise<void> {
    if (api.mock) return Promise.resolve()
    /* a mount while a read is on its way shares it; a forced read never
       joins an older one, it starts after forgetting the cached roster */
    if (inFlight && !force) return inFlight
    /* 027 budget: the roster reader (avatar.mjs) rides a lazy chunk; the
       read is async anyway, so nothing on first paint waits for it */
    const p = import('~/utils/avatar.mjs')
      .then(({ forgetRosterRead, loadHumanNames }) => {
        if (force) forgetRosterRead()
        return loadHumanNames({ base: api.base, token: api.token, credentials: api.credentials, read: () => api.rosterView() })
      })
      .then((got: Record<string, string>) => { if (!sameNames(got, names.value)) names.value = got })
    const run = p.finally(() => { if (inFlight === run) inFlight = null })
    inFlight = run
    return run
  }

  /* The roster needs a member session: signed in already, read on mount;
     signing in makes it readable, so read it then, not on the next reload.
     Before either, a read is only a 401. */
  const session = useSessionStore()
  onMounted(() => { if (session.state === 'in') void load() })
  if (import.meta.client && !wired) {
    wired = true
    effectScope(true).run(() => {
      watch(() => session.state, (now, before) => { if (now === 'in' && before !== 'in') void load(true) })
    })
  }

  function label(id: string, box?: string) {
    return personLabel(id, box, names.value)
  }

  return { names, label, refresh: () => load(true) }
}
