import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { SEARCH_OPERATORS, ensureSearchOperators, type SearchOperator, type SearchResult } from '~/utils/search.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'

/** The hub's search time budget in seconds (hub searchBudgetDefault, search-v1 §5.1): a 503 search_budget says it. */
export const SEARCH_BUDGET_S = 5

type SearchError = { status: number, token: string, detail: string, pos: number, badToken: string, retryAfter: number, raw: unknown }

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
  /* > 0 while the left list's own open navigates (ChannelSidebar keeps the list) */
  const opening = ref(0)
  let seq = 0
  let opsLoaded = false

  function toError(e: unknown): SearchError {
    const x = (e || {}) as { status?: number, token?: string, detail?: string, pos?: number, badToken?: string, retryAfter?: number }
    return {
      status: Number(x.status) || 0,
      token: String(x.token || ''),
      detail: String(x.detail || ''),
      pos: Number.isInteger(x.pos) ? Number(x.pos) : -1,
      badToken: String(x.badToken || ''),
      retryAfter: Number(x.retryAfter) || 0,
      raw: e,
    }
  }

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
    try {
      /* 010 FR-009: a member's first read of a fresh page flips the view door to
         the sign-in cookie. Without this a signed-in human deep-linking to
         /search?q=… got the door prompt instead of results (measured on dev
         2026-09-21: "This tenant's topics need a member sign-in or a view
         token"), the same 401 view_door 2dfefe7 fixed for /channel, /dm and the
         roster. */
      const api = useSpoolApi()
      const r = await withSessionRetry(api, () => api.search({ q: query }))
      if (mine === seq) result.value = r
    } catch (e) {
      if (mine === seq) {
        result.value = null
        error.value = toError(e)
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
    try {
      const api = useSpoolApi()
      const cursor = String(g.next || '')
      const page = await withSessionRetry(api, () => api.search({ q: q.value, cursor }))
      if (mine !== seq || !result.value) return
      const { mergeSearchPage } = await import('~/utils/search-results.mjs') // off the first paint (027 budget)
      result.value = mergeSearchPage(result.value, page)
    } catch (e) {
      if (mine === seq) error.value = toError(e)
    } finally {
      loadingMore.value = ''
    }
  }

  /** search-v1 §6 once per session; the built-in catalogue until (or unless) it answers. */
  async function loadOperators() {
    if (opsLoaded) return
    opsLoaded = true
    try {
      const api = useSpoolApi()
      operators.value = ensureSearchOperators(await withSessionRetry(api, () => api.searchOperators()))
    } catch {
      /* route not deployed yet / door closed: keep the built-in catalogue */
    }
  }

  return { q, result, activeKey, scrollTop, opening, loading, loadingMore, error, operators, run, more, loadOperators }
})
