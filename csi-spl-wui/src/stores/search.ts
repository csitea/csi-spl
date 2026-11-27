import { defineStore } from 'pinia'
import type { Ref } from 'vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { SEARCH_OPERATORS, ensureSearchOperators, type SearchOperator, type SearchResult } from '~/utils/search.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'

/** The hub's search time budget in seconds (hub searchBudgetDefault, search-v1 §5.1): a 503 search_budget says it. */
export const SEARCH_BUDGET_S = 7

/** `ms` = how long the failed call ran (0 = not measured), for the debug pane only. */
export type SearchError = { status: number, token: string, detail: string, pos: number, badToken: string, retryAfter: number, ms: number, raw: unknown }

/**
 * SPL-1833: the one plain sentence a failed search gets (SearchErrorNotice):
 * `slow` = the hub's own budget (503 search_budget) or a gateway that gave up
 * (504, 408); `busy` = 429; `offline` = no HTTP answer the page may read;
 * `failed` = anything else.
 */
export function searchErrorKind(e: Pick<SearchError, 'status' | 'token'>): 'slow' | 'busy' | 'offline' | 'failed' {
  if (e.status === 429) return 'busy'
  if (e.status === 503 || e.status === 504 || e.status === 408 || e.token === 'search_budget' || e.token === 'timeout') return 'slow'
  if (!e.status && !e.token) return 'offline'
  return 'failed'
}

function toError(e: unknown, ms = 0): SearchError {
  const x = (e || {}) as { status?: number, token?: string, detail?: string, pos?: number, badToken?: string, retryAfter?: number }
  return {
    status: Number(x.status) || 0,
    token: String(x.token || ''),
    detail: String(x.detail || ''),
    pos: Number.isInteger(x.pos) ? Number(x.pos) : -1,
    badToken: String(x.badToken || ''),
    retryAfter: Number(x.retryAfter) || 0,
    ms,
    raw: e,
  }
}

/* 010 FR-009: a member's first read of a fresh page flips the view door to
   the sign-in cookie. Without this a signed-in human deep-linking to
   /search?q=… got the door prompt instead of results (measured on dev
   2026-09-21: "This tenant's topics need a member sign-in or a view
   token"), the same 401 view_door 2dfefe7 fixed for /channel, /dm and the
   roster. */
function searchFirstPage(query: string) {
  const api = useSpoolApi()
  return withSessionRetry(api, () => api.search({ q: query }))
}

/** `q` is the store's query ref, read when the call (or its retry) goes out. */
function searchNextPage(q: Ref<string>, cursor: string) {
  const api = useSpoolApi()
  return withSessionRetry(api, () => api.search({ q: q.value, cursor }))
}

/** search-v1 §6: the hub's operator catalogue, completed by ensureSearchOperators. */
async function readOperators(): Promise<SearchOperator[]> {
  const api = useSpoolApi()
  return ensureSearchOperators(await withSessionRetry(api, () => api.searchOperators()))
}

/** search-v1 §6 once per session; the built-in catalogue until (or unless) it answers. */
function operatorsLoader(operators: Ref<SearchOperator[]>) {
  let opsLoaded = false
  return async function loadOperators() {
    if (opsLoaded) return
    opsLoaded = true
    try {
      operators.value = await readOperators()
    } catch {
      /* route not deployed yet / door closed: keep the built-in catalogue */
    }
  }
}

/** SPL-6675: the calendars section read whole, real entries only, nearest upcoming first (utils/search-calendar.ts) */
async function withCalendarWhole(r: SearchResult, q: Ref<string>): Promise<SearchResult> {
  if (!r.groups.some((g) => g.type === 'calendars')) return r
  const { completeCalendarSection } = await import('~/utils/search-calendar') // off the first paint (027 budget)
  return completeCalendarSection(r, (cursor) => searchNextPage(q, cursor), Date.now())
}

/**
 * SPL-6675 (owner HUM-10, t1 bcfd15e1 msg 2f0259cc): the results are their own
 * slide-in panel (SearchPanel in layouts/default.vue), open from an Omnibox
 * search until the reader closes it or actually opens a hit; no results page.
 * `previewing` = the panel moved the route for a preview already, so the next
 * preview replaces that history entry.
 */
function searchPanel(s: { q: Ref<string>, result: Ref<SearchResult | null>, loading: Ref<boolean>, run: (query: string) => Promise<void> }) {
  const panelOpen = ref(false)
  const previewing = ref(false)
  /* a phone tap steps the panel aside (still open, hidden): the page it was
     tapped on, coming back by Back, shows it again as it was */
  const asideFrom = ref('')
  /** an Omnibox search: the panel opens with its answer (the same query again keeps the answer and the chosen hit) */
  function openPanel(query: string) {
    panelOpen.value = true
    previewing.value = false
    asideFrom.value = ''
    if (query === s.q.value && (s.result.value || s.loading.value)) return
    void s.run(query)
  }
  /** the panel's X, Esc, or a hit actually opened: the section's own left pane comes back */
  function closePanel() {
    panelOpen.value = false
    previewing.value = false
    asideFrom.value = ''
  }
  /** a phone tap: the hit takes the screen, the list waits for Back to `from` */
  function stepAside(from: string) { asideFrom.value = from }
  /** the route is `path`: back where the panel stepped aside, it shows again */
  function routeAt(path: string) { if (asideFrom.value && path === asideFrom.value) asideFrom.value = '' }
  return { panelOpen, previewing, asideFrom, openPanel, closePanel, stepAside, routeAt }
}

/**
 * 022 global search (search-v1.md). One query at a time: a newer run drops the
 * answer of an older one. Per-group "load more" follows that group's cursor.
 */
export const useSearchStore = defineStore('search', () => {
  const q = ref('')
  /* SPL-1216: the whole result (groups x rows x bodies) is READ-ONLY to the UI
     and is only ever replaced wholesale (run() and more() reassign result.value,
     never mutate it in place), so shallowRef skips the deep reactive proxy over
     every hit - the same call SPL-5086 made for the live/channel row lists. */
  const result = shallowRef<SearchResult | null>(null)
  const loading = ref(false)
  const loadingMore = ref('')
  const error = ref<SearchError | null>(null)
  const operators = ref<SearchOperator[]>(SEARCH_OPERATORS)
  /* CLE-77884: the left panel's chosen hit and its scroll, so the list comes
     back as the reader left it after an open (phone Back, a remount) */
  const activeKey = ref('')
  const scrollTop = ref(0)
  let seq = 0

  async function run(query: string) {
    const mine = ++seq
    q.value = query
    error.value = null
    if (!query.trim()) {
      result.value = null
      loading.value = false
      return
    }
    loading.value = true
    const t0 = Date.now()
    try {
      const r = await withCalendarWhole(await searchFirstPage(query), q)
      if (mine === seq) result.value = r
    } catch (e) {
      if (mine === seq) {
        result.value = null
        error.value = toError(e, Date.now() - t0)
      }
    } finally {
      if (mine === seq) loading.value = false
    }
  }

  async function more(type: string) {
    const cur = result.value
    const g = cur && cur.groups.find((x) => x.type === type)
    if (!cur || !g || !g.next || loadingMore.value) return
    const mine = seq
    loadingMore.value = type
    const t0 = Date.now()
    try {
      const page = await searchNextPage(q, String(g.next || ''))
      if (mine !== seq || !result.value) return
      const { mergeSearchPage } = await import('~/utils/search-results.mjs') // off the first paint (027 budget)
      result.value = mergeSearchPage(result.value, page)
    } catch (e) {
      if (mine === seq) error.value = toError(e, Date.now() - t0)
    } finally {
      loadingMore.value = ''
    }
  }

  const loadOperators = operatorsLoader(operators)

  const { panelOpen, previewing, asideFrom, openPanel, closePanel, stepAside, routeAt } = searchPanel({ q, result, loading, run })

  return { q, result, activeKey, scrollTop, panelOpen, previewing, asideFrom, loading, loadingMore, error, operators, run, more, loadOperators, openPanel, closePanel, stepAside, routeAt }
})
