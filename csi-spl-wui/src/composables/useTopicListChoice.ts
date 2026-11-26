/*
 * Spec 150 part 1-2 (row B6, panel D6): the topic list's filter (New / All)
 * and sort (Last update / Messages / Priority / Created), one choice per browser, as
 * the card-clip control beside it is kept: localStorage, no account field,
 * no API. The header control writes it, the channel feed reads it.
 * The server render paints the defaults; the stored choice is read on mount.
 *
 * SPL-6613 (owner HUM-10, t1 f7b53cf8, msg 5b8f9db2: "make the search by
 * title part of the filter"): the filter's title field, its own state beside
 * New / All (never folded into `filter`). Its text lives for the tab, not
 * per browser; the hub resolves it (`topic_select`, spec 186 4.2) into
 * stores/topicSelect.ts `titleMatch`, whose task ids narrow the list.
 */
import { storageGet, storageSet } from '~/utils/prefs.mjs'
import {
  parseTopicListFilter,
  parseTopicListSort,
  TOPIC_LIST_FILTER_DEFAULT,
  TOPIC_LIST_SORT_DEFAULT,
} from '~/utils/topic-list-order.mjs'
import { useTopicSelectStore } from '~/stores/topicSelect'
import { useSpoolApi } from '~/composables/useSpoolApi'

export type TopicListFilter = 'all' | 'new'
export type TopicListSort = 'last' | 'messages' | 'priority' | 'created'

const TOPIC_LIST_FILTER_KEY = 'spool-topic-list-filter'
const TOPIC_LIST_SORT_KEY = 'spool-topic-list-sort'
const TOPIC_LIST_TITLE_KEY = 'spool-topic-list-title'

export function useTopicListChoice() {
  const filter = useState<TopicListFilter>(TOPIC_LIST_FILTER_KEY, () => TOPIC_LIST_FILTER_DEFAULT as TopicListFilter)
  const sort = useState<TopicListSort>(TOPIC_LIST_SORT_KEY, () => TOPIC_LIST_SORT_DEFAULT as TopicListSort)

  function setFilter(next: string) {
    filter.value = parseTopicListFilter(next)
    if (import.meta.client) storageSet(TOPIC_LIST_FILTER_KEY, filter.value)
  }
  function setSort(next: string) {
    sort.value = parseTopicListSort(next)
    if (import.meta.client) storageSet(TOPIC_LIST_SORT_KEY, sort.value)
  }

  onMounted(() => {
    filter.value = parseTopicListFilter(storageGet(TOPIC_LIST_FILTER_KEY))
    sort.value = parseTopicListSort(storageGet(TOPIC_LIST_SORT_KEY))
  })

  /* the dot on an icon: its choice is not the default, so a filtered list never looks like a short one */
  const filtered = computed(() => filter.value !== TOPIC_LIST_FILTER_DEFAULT)
  const sorted = computed(() => sort.value !== TOPIC_LIST_SORT_DEFAULT)

  /* SPL-6613: the title field's text, and the task ids the hub matched for it (null = no title filter) */
  const title = useState<string>(TOPIC_LIST_TITLE_KEY, () => '')
  function setTitle(next: string) {
    title.value = String(next ?? '')
  }
  /* the field shows on a channel's topic list (the list MessageFeed narrows), where the client can send topic_select (R7 W1) */
  const route = useRoute()
  const canTopicSelect = Boolean((useSpoolApi() as unknown as { canTopicSelect?: () => boolean }).canTopicSelect?.())
  const titleOn = computed(() => canTopicSelect && /\/channel\/[^/]+\/?$/.test(route.path))
  /* a DM or the lobby is never narrowed by it */
  const topicSelect = useTopicSelectStore()
  const titleIds = computed(() => (titleOn.value ? topicSelect.titleIds : null))
  const titled = computed(() => titleIds.value !== null)

  return { filter, sort, setFilter, setSort, filtered, sorted, title, setTitle, titleIds, titled, titleOn }
}
