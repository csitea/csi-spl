import { forgetRosterRead, loadHumanNames } from '~/utils/avatar.mjs'
import { personLabel } from '~/utils/channel-feed.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'

/**
 * The display names members chose (Settings > Profile), from the roster the
 * avatars already read. `label(id, box)` is the name, or the id when there is
 * none. `refresh()` re-reads it at once, e.g. after the reader renames
 * themself.
 */
export function useHumanNames() {
  const api = useSpoolApi()
  const names = useState<Record<string, string>>('spool.human-names', () => ({}))

  async function load(force = false) {
    if (api.mock) return
    if (force) forgetRosterRead()
    const got = await loadHumanNames({ base: api.base, token: api.token, credentials: api.credentials, read: () => api.rosterView() })
    if (JSON.stringify(got) !== JSON.stringify(names.value)) names.value = got
  }

  /* The roster needs a member session: signed in already, read on mount;
     signing in makes it readable, so read it then, not on the next reload.
     Before either, a read is only a 401. */
  const session = useSessionStore()
  onMounted(() => { if (session.state === 'in') void load() })
  watch(() => session.state, (now, before) => { if (now === 'in' && before !== 'in') void load(true) })

  function label(id: string, box?: string) {
    return personLabel(id, box, names.value)
  }

  return { names, label, refresh: () => load(true) }
}
