import { defineStore } from 'pinia'
import { productPath } from '~/utils/signed-out-redirect.mjs'

/**
 * 022 FR-010: the top-bar Omnibox sends to whatever page is on screen. A page
 * (lobby, /channel/*, /dm/*) registers its send target while mounted; with no
 * target, plain text cannot be sent and the Omnibox only searches.
 */
export interface OmniboxTarget {
  /** who registered it — an unregister from a stale page is ignored */
  owner: symbol
  placeholder: () => string
  send: (text: string, files: File[], topicId?: string, channelId?: string) => Promise<unknown> | unknown
  busy?: () => boolean
  /**
   * SPL-1003: where the next post goes, for the phone dock's hint - `reply`
   * true while it will go into the open thread (is_parent 0), else a new
   * topic in `target` (the page's own name: '#channel', the peer, ...).
   * `comment` true on an open issue (/issues on a phone): the
   * post is a comment on the issue named by `target` (SPL-n).
   * `dm` true on a direct-message page (HUM-24: "New topic with <peer>").
   */
  dock?: () => { reply: boolean, target: string, comment?: boolean, dm?: boolean }
  /**
   * 080 FR-001: the draft place a send goes to - `ch:<channel>`, `dm:<peer>`
   * or `t:<task_id>` (a reply; on `/` from omniboxReplyTaskId). The composer
   * keeps one draft per place (utils/drafts.mjs); '' or absent keeps none.
   */
  place?: () => string
}

export const useOmniboxStore = defineStore('omnibox', () => {
  const target = shallowRef<OmniboxTarget | null>(null)
  /** bumped to ask the search results list to take the focus (ArrowDown in the Omnibox) */
  const focusResults = ref(0)

  /**
   * SPL-2516 (qto reading panel row 02): on a phone's docs routes the dock is
   * collapsed; openSearch() brings it back in search mode (the composer
   * watches `searchAsk`) and `searchOpen` holds it there until the search
   * line is left or the page changes (closeSearch).
   */
  const searchOpen = ref(false)
  const searchAsk = ref(0)
  function openSearch() {
    searchOpen.value = true
    searchAsk.value++
  }
  function closeSearch() {
    searchOpen.value = false
  }

  function register(t: OmniboxTarget) {
    target.value = t
  }
  function unregister(owner: symbol) {
    if (target.value && target.value.owner === owner) target.value = null
  }
  return { target, focusResults, searchOpen, searchAsk, openSearch, closeSearch, register, unregister }
})

/**
 * SPL-2516: the reading routes whose phone dock and status strip collapse,
 * `/docs` and `/workspace/docs` and below, in any locale.
 */
export function isDocsReadingPath(path: string): boolean {
  return /^\/(?:workspace\/)?docs(?:\/|$)/.test(productPath(path))
}

/** Page helper: register a send target for this page's lifetime. */
export function useOmniboxTarget(t: Omit<OmniboxTarget, 'owner'>) {
  const store = useOmniboxStore()
  const owner = Symbol('omnibox-target')
  onMounted(() => store.register({ ...t, owner }))
  onBeforeUnmount(() => store.unregister(owner))
}
