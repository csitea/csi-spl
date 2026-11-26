/*
 * Spec 186 7.1.6 (row M3; owner HUM-10, t1 032d8010, msgs 5fdfff6c and
 * 4b3833e7): the select phase's selection, shared by every bulk action on
 * topics (Multicast, spec 186 M11; Set priority, spec 153, section 8.3).
 *
 * One ordered list of { task_id, channel, title } for the workspace the
 * reader is in. It spans channel pages and Monitoring -> Topics (H2): a
 * filter change or another channel's page keeps it, unlike the issues list.
 * Clear, a workspace switch and a finished action empty it. Memory only
 * (plan 2.4 Q2 A): a reload empties it, as on issues. Never on the hub.
 *
 * The tick logic is the issues list's (utils/issues-bulk.ts), keyed by
 * task_id; nothing here re-implements it.
 */
import { defineStore } from 'pinia'
import { computed, ref, shallowRef } from 'vue'
import { pageState, rangeSelect, toggleAll, toggleKey } from '~/utils/issues-bulk'
import type { UiIconName } from '~/utils/uiIcons'

/** One selected topic: its task, its channel and the title the card, row or hub answer named. */
export type TopicPick = { task_id: string, channel: string, title: string }

/** A bulk action of the selection bar (7.1.6). `run` gets the selection; it returns true when the action finished (the selection then empties), anything else when it was cancelled. */
export type TopicSelectAction = {
  id: string
  icon: UiIconName
  labelKey: string
  run: (selection: TopicPick[]) => unknown
}

/** The bar's result line, as on issues: how many of how many, and the titles that failed. */
export type TopicSelectResult = { done: number, total: number, failed: string[] }

/** A topic list that pages: "Select all N matching" loads its pages to the end (7.1.6, as on issues). */
export type TopicSelectMatcher = { more: () => boolean, load: () => Promise<void> }

/** The action a `topic_select` frame names while no button was chosen (7.1.6: the first registered one, else Multicast). */
export const TOPIC_SELECT_DEFAULT_ACTION = 'multicast'

/** The channel whose topics are issue discussions: never ticked (R1). */
const ISSUES_CHANNEL = 'issues'

/**
 * A card a box may tick: a topic opener of a channel's topic list (the
 * lobby and general included), never a DM card (Q8 CHN), an `issues` card
 * (R1) or a reply. `listCard` is the feed's own say: a middle-pane topic
 * list, not a thread.
 */
export function selectableCard(msg: { task_id?: string | null, channel?: string | null, is_parent?: number | null } | null | undefined, listCard: boolean): boolean {
  if (!listCard || !msg || msg.is_parent === 0) return false
  const channel = String(msg.channel || '')
  return Boolean(msg.task_id) && channel !== '' && channel !== ISSUES_CHANNEL
}

/** `list` with each task once, the first one kept, empty task ids dropped. */
export function uniquePicks(list: TopicPick[]): TopicPick[] {
  const seen = new Set<string>()
  const out: TopicPick[] = []
  for (const p of Array.isArray(list) ? list : []) {
    const id = String(p?.task_id || '')
    if (!id || seen.has(id)) continue
    seen.add(id)
    out.push({ task_id: id, channel: String(p.channel || ''), title: String(p.title || '') })
  }
  return out
}

function selectionState() {
  const ws = ref('')
  const picks = ref<TopicPick[]>([])
  /* the page's tickable topics in reading order: the page box and shift-range read them */
  const shown = ref<TopicPick[]>([])
  const anchor = ref('')
  const actions = ref<TopicSelectAction[]>([])
  const busy = ref(false)
  const progress = ref<{ done: number, total: number } | null>(null)
  const result = ref<TopicSelectResult | null>(null)
  /* the page's pager, while it has one, and Gmail's "all N matching" state */
  const matcher = shallowRef<TopicSelectMatcher | null>(null)
  const matching = ref(false)
  const allMatching = ref(false)
  /* the newest topic_select sent: an answer to an older one is dropped (7.1.2) */
  const lastReq = ref('')
  /* SPL-6613: the hub's answer to the topic list filter's title field (null =
     no title filter) and the newest frame sent for it */
  const titleMatch = shallowRef<TopicPick[] | null>(null)
  const titleReq = ref('')
  /* the headers that hold the title filter: the last one to go ends it */
  const titleHolders = ref(0)
  const keys = computed(() => picks.value.map((p) => p.task_id))
  const shownKeys = computed(() => shown.value.map((p) => p.task_id))
  return {
    ws, picks, shown, anchor, actions, busy, progress, result, matcher, matching, allMatching, lastReq, titleMatch, titleReq, titleHolders, keys, shownKeys,
    /** the task ids the title field matched, or null while it is empty */
    titleIds: computed(() => (titleMatch.value ? new Set(titleMatch.value.map((p) => p.task_id)) : null)),
    keySet: computed(() => new Set(keys.value)),
    count: computed(() => picks.value.length),
    active: computed(() => picks.value.length > 0),
    channels: computed(() => new Set(picks.value.map((p) => p.channel)).size),
    page: computed(() => pageState(keys.value, shownKeys.value)),
  }
}
type SelectionState = ReturnType<typeof selectionState>

function selectionEdits(s: SelectionState) {
  /** the selection becomes `next` (task ids); a pick's details come from the old selection or `known` */
  function setKeys(next: string[], known: TopicPick[]) {
    if (next === s.keys.value) return
    const by = new Map<string, TopicPick>()
    for (const p of [...known, ...s.picks.value]) by.set(p.task_id, p)
    s.picks.value = next.map((id) => by.get(id) || { task_id: id, channel: '', title: '' })
    s.result.value = null
    s.allMatching.value = false
  }
  return {
    has: (taskId: string) => s.keySet.value.has(String(taskId || '')),
    /** one topic ticked, unticked (`on`) or flipped */
    toggle(p: TopicPick, on?: boolean) {
      setKeys(toggleKey(s.keys.value, p.task_id, on), [p])
      s.anchor.value = p.task_id
    },
    /** shift-click: the run from the last box clicked to `p`, in the page's order */
    range(p: TopicPick, on?: boolean) {
      setKeys(rangeSelect(s.keys.value, s.shownKeys.value, s.anchor.value, p.task_id, on), [p, ...s.shown.value])
      s.anchor.value = p.task_id
    },
    /** the page box: every topic shown ticked, or (all already were) none of them */
    togglePage() {
      setKeys(toggleAll(s.keys.value, s.shownKeys.value), s.shown.value)
    },
    /** topics join the selection (union, deduplicated by task_id) */
    add(list: TopicPick[]) {
      const fresh = uniquePicks(list).filter((p) => !s.keySet.value.has(p.task_id))
      if (fresh.length) setKeys([...s.keys.value, ...fresh.map((p) => p.task_id)], fresh)
    },
    clear() {
      s.picks.value = []
      s.anchor.value = ''
      s.progress.value = null
      s.result.value = null
      s.allMatching.value = false
    },
  }
}

export const useTopicSelectStore = defineStore('topicSelect', () => {
  const s = selectionState()
  const edits = selectionEdits(s)
  /** the reader's workspace; another one empties the selection (a multicast cannot cross workspaces, 3.3) */
  function setWorkspace(id: string) {
    const next = String(id || '')
    if (s.ws.value && next !== s.ws.value) {
      edits.clear()
      s.titleMatch.value = null
    }
    s.ws.value = next
  }
  /** the page's tickable topics, in reading order (the page box, shift-range) */
  function setShown(list: TopicPick[]) {
    s.shown.value = uniquePicks(list)
  }
  /** a bulk action joins the bar (in registration order); the returned function takes it off */
  function register(a: TopicSelectAction): () => void {
    s.actions.value = [...s.actions.value.filter((x) => x.id !== a.id), a]
    return () => { s.actions.value = s.actions.value.filter((x) => x !== a) }
  }
  return { ...s, ...edits, setWorkspace, setShown, register }
})
