import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { SEARCH_OPERATORS, mergeSearchPage, type SearchOperator, type SearchResult } from '~/utils/search.mjs'

type SearchError = { status: number, token: string, detail: string, pos: number, badToken: string, retryAfter: number, raw: unknown }

/**
 * 022 global search (search-v1.md). One query at a time: a newer run drops the
 * answer of an older one. Per-group "load more" follows that group's cursor.
 */
export const useSearchStore = defineStore('search', () => {
  const q = ref('')
  const result = ref<SearchResult | null>(null)
  const loading = ref(false)
  const loadingMore = ref('')
  const error = ref<SearchError | null>(null)
  const operators = ref<SearchOperator[]>(SEARCH_OPERATORS)
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
      const r = await useSpoolApi().search({ q: query })
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
      const page = await useSpoolApi().search({ q: q.value, cursor: g.next })
      if (mine === seq && result.value) result.value = mergeSearchPage(result.value, page)
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
      operators.value = await useSpoolApi().searchOperators()
    } catch {
      /* route not deployed yet / door closed: keep the built-in catalogue */
    }
  }

  return { q, result, loading, loadingMore, error, operators, run, more, loadOperators }
})
