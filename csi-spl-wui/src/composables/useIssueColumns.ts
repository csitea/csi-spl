// SPL-1132: the person's Issues sheet column widths, one value for both views
// (List | By status) and every status group. Signed in, it is the
// `issues_columns` session claim kept on the hub (humans.issues_columns), so
// the widths follow the person to every device; signed out (mock, lde) the
// page's own per-browser store is the fallback.
//
// A drag writes the width many times a second; the claim follows at once and
// the hub save is debounced, so one gesture is one PUT. A save still pending
// when the page goes (reload, tab closed) is sent on pagehide, keepalive: a
// reload never runs the unmount hook, so the width was lost (c-340). The
// reloaded page reads its session before that PUT lands, so the widths are
// also stashed for this tab and put back on the next load.
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { applyIssueColumns, parseIssueColumns } from '~/utils/issue-columns-pref.mjs'
import { pendingSave, stashColWidths, tabStore, takeColWidthsStash } from '~/utils/issues-colw.mjs'

type Widths = Record<string, number>

export const ISSUE_COLUMNS_SAVE_MS = 500

export function useIssueColumns(fallback?: { load: () => Widths, save: (w: Widths) => void }) {
  const session = useSessionStore()
  const auth = useAuthClient()
  const signedIn = computed(() => session.state === 'in')
  /* the hub's value before this gesture started (what a refusal restores) */
  let saved: Widths | null = null

  const local = ref<Widths>(fallback ? parseIssueColumns(fallback.load()) : {})
  const widths = computed<Widths>(() => (signedIn.value ? parseIssueColumns(session.claims?.issues_columns) : local.value))

  async function flush(opts: { keepalive?: boolean } = {}) {
    const want = parseIssueColumns(session.claims?.issues_columns)
    const current = saved
    saved = null
    await applyIssueColumns(want, {
      current,
      apply: (v) => session.setIssuesColumns(v),
      save: (v) => auth.saveIssueColumns(v, opts),
    })
  }
  const pending = pendingSave((opts: { keepalive?: boolean }) => void flush(opts), ISSUE_COLUMNS_SAVE_MS)

  /** Store `next` (column -> px; {} = the automatic layout everywhere). */
  function save(next: Widths) {
    const clean = parseIssueColumns(next)
    if (!signedIn.value) {
      local.value = clean
      fallback?.save(clean)
      return
    }
    if (saved === null) saved = parseIssueColumns(session.claims?.issues_columns)
    session.setIssuesColumns(Object.keys(clean).length ? clean : null)
    pending.schedule()
  }

  /* who the stash belongs to: the human id, or the email where hum is not wired */
  const person = () => String(session.claims?.hum || session.claims?.email || '')

  function onPageHide() {
    const now = { ...widths.value }
    if (pending.flush({ keepalive: true })) stashColWidths(now, person(), tabStore())
  }

  /* a stash from the page this tab just left: once the session says who is
     signed in, the same person gets those widths back */
  function restoreStash() {
    const stash = takeColWidthsStash(tabStore())
    if (!stash) return
    const apply = () => {
      if (session.state === 'loading' || session.state === 'unknown') return false
      if (signedIn.value && person() === stash.hum) save(stash.w)
      return true
    }
    if (apply()) return
    const stop = watch(() => [session.state, person()], () => {
      if (apply()) stop()
    })
  }

  onMounted(() => {
    window.addEventListener('pagehide', onPageHide)
    restoreStash()
  })
  onBeforeUnmount(() => {
    window.removeEventListener('pagehide', onPageHide)
    pending.flush()
  })

  return { widths, signedIn, save }
}
