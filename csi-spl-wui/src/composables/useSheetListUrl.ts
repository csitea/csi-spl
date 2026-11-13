/**
 * A Monitoring sheet's sort and filters follow the address and back
 * (spec 153 3.15, SPL-4729), lifted from the Lanes page so Topics behaves
 * the same way (3.29, SPL-5430; owner HUM-10, t1 5804c44c, msg b65c7989).
 * The codec is utils/sheet-list-url.mjs, the sheet's spec its page's.
 *
 * A change replaces the address, never adds a history entry; a default
 * writes no parameter; any other parameter (?lane=) stays. The first answer
 * sets back to All a choice it does not offer, then writes the address once.
 *
 * SPL-5276: the address, not the route, as the Issues list does
 * (useIssueListUrl, SPL-4648): closing a phone sheet steps Back over its
 * entry, so the route moves to the entry under it while useMobileStack puts
 * the sheet's address back; only the address keeps what the sheet wrote.
 */
import type { Ref } from 'vue'
import { isNavigationFailure, NavigationFailureType } from 'vue-router'
import { currentQuery } from '~/composables/useIssueOpen'
import { plainQuery, sameQuery, sheetFiltersOffered, sheetStateFromQuery, sheetStateQuery } from '~/utils/sheet-list-url.mjs'

type SheetSort = { col: string, dir: string }
type SheetUrlSpec = Parameters<typeof sheetStateFromQuery>[0]

export type SheetListUrlOptions = {
  /** the sheet's columns, ages and defaults (e.g. LANES_URL_SPEC) */
  spec: SheetUrlSpec
  sort: Ref<SheetSort>
  /** the page's reactive filters, one per column */
  filters: Record<string, string>
  /** the answer: its first non-null value checks the address's choices */
  answer: Ref<unknown>
  /** the choices the answer offers, per choice column */
  choices: () => Record<string, unknown>
}

export function useSheetListUrl(o: SheetListUrlOptions) {
  const route = useRoute()
  const router = useRouter()
  const listPath = route.path
  const addressQuery = () => (import.meta.client ? currentQuery() : plainQuery(route.query))
  const here = () => router.currentRoute.value.path === listPath
  /* replaces on their way: the route still names the state before them */
  let writing = 0
  /* the state is newer than the address: a navigation (the sheet's Back)
     cancelled the replace, and it is owed once more */
  let owed = false

  /** the address's sort and filters, each value the answer does not offer set back to All */
  function readUrl() {
    const q = sheetStateFromQuery(o.spec, addressQuery())
    if (q.sort.col !== o.sort.value.col || q.sort.dir !== o.sort.value.dir) o.sort.value = q.sort
    const f = o.answer.value ? sheetFiltersOffered(o.spec, q.filters, o.choices()) : q.filters
    if (Object.entries(f).some(([k, v]) => o.filters[k] !== v)) Object.assign(o.filters, f)
  }
  function writeUrl() {
    if (!import.meta.client || !here()) return
    const base = addressQuery()
    const next = sheetStateQuery(o.spec, { sort: o.sort.value, filters: o.filters }, base)
    if (!writing && sameQuery(next, base)) { owed = false; return }
    writing++
    /* a pick that also closes its phone sheet: the sheet's history.back cancels
       this replace; it stays owed, and follow() or the refusal sends it */
    const landed = (failure?: unknown) => {
      writing--
      if (writing) return
      if (isNavigationFailure(failure, NavigationFailureType.cancelled)) { owed = true; return }
      owed = false
      if (!failure) follow()
    }
    /* force: after a sheet's Back the route names the entry under it while the
       address kept the sheet's query, so a Clear back to that route's query is a
       "duplicate" the router would skip, and the address would keep the filter */
    router.replace({ query: next, force: true }).then(landed, landed)
  }
  /* the address moved (Back, Forward, a link to this page) */
  function follow() {
    if (writing || !here()) return
    if (!owed) readUrl()
    writeUrl()
  }

  readUrl()
  if (import.meta.client) {
    /* a refused or aborted move: the address is still owed what changed meanwhile */
    onBeforeUnmount(router.afterEach((_to, _from, failure) => {
      if (failure && (owed || writing) && isNavigationFailure(failure, NavigationFailureType.aborted)) setTimeout(writeUrl, 0)
    }))
    watch(() => router.currentRoute.value.query, follow)
  }
  watch([o.sort, o.filters], writeUrl, { deep: true })
  /* the first answer checks the link's values against what it offers, and the
     address names what the page shows from then on (an old link's parameters go) */
  let offeredChecked = false
  watch(o.answer, (v) => {
    if (!v || offeredChecked) return
    offeredChecked = true
    Object.assign(o.filters, sheetFiltersOffered(o.spec, { ...o.filters }, o.choices()))
    writeUrl()
  })
}
