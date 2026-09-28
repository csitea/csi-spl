// SPL-1132: the person's Issues sheet column widths, one value for both views
// (List | By status) and every status group. Signed in, it is the
// `issues_columns` session claim kept on the hub (humans.issues_columns), so
// the widths follow the person to every device; signed out (mock, lde) the
// page's own per-browser store is the fallback.
//
// A drag writes the width many times a second; the claim follows at once and
// the hub save is debounced, so one gesture is one PUT.
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { applyIssueColumns, parseIssueColumns } from '~/utils/issue-columns-pref.mjs'

type Widths = Record<string, number>

export const ISSUE_COLUMNS_SAVE_MS = 500

export function useIssueColumns(fallback?: { load: () => Widths, save: (w: Widths) => void }) {
  const session = useSessionStore()
  const auth = useAuthClient()
  const signedIn = computed(() => session.state === 'in')
  /* the hub's value before this gesture started (what a refusal restores) */
  let saved: Widths | null = null
  let timer: ReturnType<typeof setTimeout> | null = null

  const local = ref<Widths>(fallback ? parseIssueColumns(fallback.load()) : {})
  const widths = computed<Widths>(() => (signedIn.value ? parseIssueColumns(session.claims?.issues_columns) : local.value))

  async function flush() {
    timer = null
    const want = parseIssueColumns(session.claims?.issues_columns)
    const current = saved
    saved = null
    await applyIssueColumns(want, {
      current,
      apply: (v) => session.setIssuesColumns(v),
      save: (v) => auth.saveIssueColumns(v),
    })
  }

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
    if (timer) clearTimeout(timer)
    timer = setTimeout(flush, ISSUE_COLUMNS_SAVE_MS)
  }

  onBeforeUnmount(() => {
    if (timer) {
      clearTimeout(timer)
      void flush()
    }
  })

  return { widths, signedIn, save }
}
