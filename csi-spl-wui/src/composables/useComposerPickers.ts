// r13-03: the composer's two own pickers, moved out of MessageComposer.vue:
// the /search operator list (022 FR-012, catalogue search-v1 §6) and the
// `in: <title>` topic list. The @ list is useMentionPicker's.
import type { Ref } from 'vue'
import { useRosterStore } from '~/stores/roster'
import { useViewerStore } from '~/stores/viewer'
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { applyCompletion, completeOperators, operatorTokenAt, OP_PICKER_CAP } from '~/utils/search.mjs'
import { activeInQuery, filterTopicTitles, insertInClause, topicChoices } from '~/utils/topic-in.mjs'
import type { ComposerProps } from '~/composables/composerProps'

export interface TopicRow { taskId: string, title: string, channel: string }

interface PickerOpts {
  text: Ref<string>
  inputEl: Ref<HTMLTextAreaElement | null>
  searchMode: Ref<boolean>
  props: ComposerProps
  /** the @ list is open: it wins over the topic list */
  mentionOpen: () => boolean
  /** the template's two lists (their arrows scroll the active row into view) */
  opListEl: Ref<HTMLUListElement | null>
  inListEl: Ref<HTMLUListElement | null>
}

/** Same scroll as the mention list: arrows move this dropdown, not the page. */
function scrollActive(listEl: Ref<HTMLUListElement | null>, idx: number) {
  nextTick(() => {
    const list = listEl.value
    if (!list) return
    const row = list.querySelectorAll<HTMLElement>('.mention-item')[idx]
    if (!row) return
    const listRect = list.getBoundingClientRect()
    const rowRect = row.getBoundingClientRect()
    if (rowRect.top < listRect.top) list.scrollTop += rowRect.top - listRect.top
    else if (rowRect.bottom > listRect.bottom) list.scrollTop += rowRect.bottom - listRect.bottom
  })
}

/** Put the caret at `cursor` once the new text is in the field. */
function caretTo(inputEl: Ref<HTMLTextAreaElement | null>, cursor: number) {
  nextTick(() => {
    const el = inputEl.value
    if (!el) return
    el.focus()
    el.setSelectionRange(cursor, cursor)
  })
}

/** Arrow keys move, Tab / Enter pick, Esc closes; true = handled. */
function listKey(ev: KeyboardEvent, n: number, idx: Ref<number>, on: { scroll: () => void, pick: () => void, close: () => void }): boolean {
  if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
    ev.preventDefault()
    idx.value = (idx.value + (ev.key === 'ArrowDown' ? 1 : n - 1)) % n
    on.scroll()
    return true
  }
  if (ev.key === 'Tab' || (ev.key === 'Enter' && !ev.shiftKey)) {
    ev.preventDefault()
    on.pick()
    return true
  }
  if (ev.key !== 'Escape') return false
  ev.preventDefault()
  on.close()
  return true
}

function useOpPicker(o: PickerOpts) {
  const { props } = o
  const roster = useRosterStore()
  const opIdx = ref(0)
  const opListEl = o.opListEl
  /** caret offset, kept in sync so the operator picker follows it */
  const caretAt = ref(0)
  const opClosed = ref(false)
  const opTok = computed(() => (o.searchMode.value ? operatorTokenAt(o.text.value, caretAt.value) : null))
  const opCandidates = computed(() => (opTok.value ? completeOperators(opTok.value.token, props.operators, roster.peers).slice(0, OP_PICKER_CAP) : []))
  const opPickerOpen = computed(() => !opClosed.value && opCandidates.value.length > 0)
  function pickOp(insert: string) {
    const tok = opTok.value
    if (!tok) return
    const next = applyCompletion(o.text.value, tok, insert)
    o.text.value = next.text
    caretAt.value = next.cursor
    opIdx.value = 0
    caretTo(o.inputEl, next.cursor)
  }
  function onOperatorKey(ev: KeyboardEvent): boolean {
    if (!opPickerOpen.value) return false
    return listKey(ev, opCandidates.value.length, opIdx, {
      scroll: () => scrollActive(opListEl, opIdx.value),
      pick: () => { const c = opCandidates.value[opIdx.value]; if (c) pickOp(c.insert) },
      close: () => { opClosed.value = true },
    })
  }
  /** a new operator token at the caret reopens the list at its top */
  function syncOp(ev?: Event) {
    const prevTok = opTok.value && opTok.value.token
    caretAt.value = o.inputEl.value?.selectionStart ?? o.text.value.length
    if (!ev || ev.type === 'keyup' || opTok.value?.token === prevTok) return
    opClosed.value = false
    opIdx.value = 0
    nextTick(() => { if (opListEl.value) opListEl.value.scrollTop = 0 })
  }
  return { opIdx, caretAt, opClosed, opCandidates, opPickerOpen, pickOp, onOperatorKey, syncOp }
}

function useInPicker(o: PickerOpts) {
  const viewer = useViewerStore()
  const channelFeed = useChannelStore()
  const liveMain = useLiveFeed('main')
  const inQuery = ref<string | null>(null)
  const inIdx = ref(0)
  const inListEl = o.inListEl
  /** The topic the reader picked, so two starters with one title stay distinct. */
  const pickedIn = ref<TopicRow | null>(null)
  let topicsAsked = false
  const topicCatalogue = computed(() => topicChoices({
    topics: viewer.topics,
    messages: [...channelFeed.messages, ...liveMain.messages],
  }))
  const inCandidates = computed(() => (inQuery.value === null ? [] : filterTopicTitles(topicCatalogue.value, inQuery.value)))
  const inPickerOpen = computed(() => inQuery.value !== null && inCandidates.value.length > 0 && !o.mentionOpen())
  watch(inQuery, (q) => {
    if (q === null || topicsAsked || viewer.topics.length > 0) return
    topicsAsked = true
    void viewer.loadTopics()
  })
  function pickIn(row: TopicRow) {
    const next = insertInClause(o.text.value, o.inputEl.value?.selectionStart ?? o.text.value.length, row.title)
    o.text.value = next.text
    pickedIn.value = { taskId: row.taskId, title: row.title, channel: row.channel }
    inQuery.value = null
    caretTo(o.inputEl, next.cursor)
  }
  function onInKey(ev: KeyboardEvent): boolean {
    if (!inPickerOpen.value) return false
    return listKey(ev, inCandidates.value.length, inIdx, {
      scroll: () => scrollActive(inListEl, inIdx.value),
      pick: () => { const row = inCandidates.value[inIdx.value]; if (row) pickIn(row) },
      close: () => { inQuery.value = null },
    })
  }
  /** `in:` is the topic-title picker; null = no list (an @ token or a code block wins) */
  function syncIn(next: string | null) {
    if (next !== inQuery.value) {
      inIdx.value = 0
      nextTick(() => { if (inListEl.value) inListEl.value.scrollTop = 0 })
    }
    inQuery.value = next
  }
  const atCaret = () => activeInQuery(o.text.value, o.inputEl.value?.selectionStart ?? o.text.value.length)
  return { inQuery, inIdx, pickedIn, topicCatalogue, inCandidates, inPickerOpen, pickIn, onInKey, syncIn, atCaret }
}

export function useComposerPickers(o: PickerOpts) {
  return { ...useOpPicker(o), ...useInPicker(o) }
}
