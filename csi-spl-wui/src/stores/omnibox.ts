import { defineStore } from 'pinia'

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
   */
  dock?: () => { reply: boolean, target: string, comment?: boolean }
}

export const useOmniboxStore = defineStore('omnibox', () => {
  const target = shallowRef<OmniboxTarget | null>(null)
  /** bumped to ask the search results list to take the focus (ArrowDown in the Omnibox) */
  const focusResults = ref(0)

  function register(t: OmniboxTarget) {
    target.value = t
  }
  function unregister(owner: symbol) {
    if (target.value && target.value.owner === owner) target.value = null
  }
  return { target, focusResults, register, unregister }
})

/** Page helper: register a send target for this page's lifetime. */
export function useOmniboxTarget(t: Omit<OmniboxTarget, 'owner'>) {
  const store = useOmniboxStore()
  const owner = Symbol('omnibox-target')
  onMounted(() => store.register({ ...t, owner }))
  onBeforeUnmount(() => store.unregister(owner))
}
