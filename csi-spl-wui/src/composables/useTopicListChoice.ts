/*
 * Spec 150 part 1-2 (row B6, panel D6): the topic list's filter (New / All)
 * and sort (Last update / Messages / Priority), one choice per browser, as
 * the card-clip control beside it is kept: localStorage, no account field,
 * no API. The header control writes it, the channel feed reads it.
 * The server render paints the defaults; the stored choice is read on mount.
 */
import { storageGet, storageSet } from '~/utils/prefs.mjs'
import {
  parseTopicListFilter,
  parseTopicListSort,
  TOPIC_LIST_FILTER_DEFAULT,
  TOPIC_LIST_SORT_DEFAULT,
} from '~/utils/topic-list-order.mjs'

export type TopicListFilter = 'all' | 'new'
export type TopicListSort = 'last' | 'messages' | 'priority'

const TOPIC_LIST_FILTER_KEY = 'spool-topic-list-filter'
const TOPIC_LIST_SORT_KEY = 'spool-topic-list-sort'

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

  return { filter, sort, setFilter, setSort, filtered, sorted }
}
