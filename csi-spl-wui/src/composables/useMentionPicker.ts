// SPL-985 (spec 042 §2): the one @ picker. The omnibox had it first; every
// text field a person writes in now uses this same composable plus
// components/MentionList.vue - there is no second copy.
//
// Usage in a field:
//   const mp = useMentionPicker({ text: draft, el: areaEl })
//   <MentionList :picker="mp" />
//   <textarea ref="areaEl" v-model="draft"
//     @input="mp.sync" @click="mp.sync" @keyup="mp.sync" @blur="mp.close"
//     @keydown="mp.onKeydown($event) || onSubmitKey($event, save)" />
// While the list is open, Enter and Tab pick and the key never reaches the
// field's submit handler (SPL-976 useSubmitKey), whatever the setting says.
//
// SPL-1009: a pick writes the person's NAME into the field (`@Ann Lee`); the
// text is stored with the tag (`@HUM-3@box-wui`). So every field stores
// `mp.encode(text)`, and a field pre-filled from a stored text shows
// `mp.decode(stored)`.
import type { Ref } from 'vue'
import { useRosterStore } from '~/stores/roster'
import { useHumanNames } from '~/composables/useHumanNames'
import { feedbackChannelFromPath, isFeedbackChannel } from '~/utils/feedback-channel.mjs'
import { activeMentionQuery, decodeMentions, encodeMentions, insertMention, mentionCandidates, mentionFieldName } from '~/utils/mention-autocomplete.mjs'

export interface MentionRow { id: string, box?: string, label?: string, online?: boolean, idle?: boolean, owner?: boolean, sameName?: boolean }

function setupState() {
  const roster = useRosterStore()
  const people = useHumanNames()
  const route = useRoute()
  const query = ref<string | null>(null)
  const activeIdx = ref(0)
  const listEl = ref<HTMLUListElement | null>(null)
  const listId = useId()
  const picks = ref<Record<string, string>>({})

  const inFeedback = computed(() => isFeedbackChannel(feedbackChannelFromPath(route.path)))

  const candidates = computed<MentionRow[]>(() => {
    if (query.value === null) return []
    return mentionCandidates({
      peers: roster.peers,
      names: people.names.value,
      owners: roster.owners,
      selfId: roster.self ? roster.self.id : '',
      query: query.value,
      ownersFirst: inFeedback.value,
      isOnline: (id: string) => roster.isOnline(id, 'box-wui'),
    }).map((row: MentionRow) =>
      /^HUM-\d+$/.test(row.id) && people.names.value[row.id] && !mentionFieldName(row.id, people.names.value) ? { ...row, sameName: true } : row
    )
  })

  const open = computed(() => query.value !== null && candidates.value.length > 0)

  return { query, activeIdx, listEl, listId, picks, candidates, open }
}

function setupCaretAndSync(opts: {
  text: Ref<string>
  el: Ref<HTMLTextAreaElement | HTMLInputElement | null | undefined>
  blocked?: () => boolean
}, state: ReturnType<typeof setupState>) {
  const { query, activeIdx, listEl } = state

  function caret(): number {
    return opts.el.value?.selectionStart ?? opts.text.value.length
  }

  function sync() {
    const q = opts.blocked && opts.blocked() ? null : activeMentionQuery(opts.text.value, caret())
    if (q !== query.value) {
      activeIdx.value = 0
      nextTick(() => { if (listEl.value) listEl.value.scrollTop = 0 })
    }
    query.value = q
  }

  function close() {
    query.value = null
  }

  return { caret, sync, close }
}

function setupScrollAndPick(opts: {
  text: Ref<string>
  el: Ref<HTMLTextAreaElement | HTMLInputElement | null | undefined>
  onPick?: (text: string) => void
}, state: ReturnType<typeof setupState>) {
  const { activeIdx, listEl, picks, candidates } = state

  function scrollActive() {
    nextTick(() => {
      const list = listEl.value
      if (!list) return
      const row = list.querySelectorAll<HTMLElement>('.mention-item')[activeIdx.value]
      if (!row) return
      const listRect = list.getBoundingClientRect()
      const rowRect = row.getBoundingClientRect()
      if (rowRect.top < listRect.top) list.scrollTop += rowRect.top - listRect.top
      else if (rowRect.bottom > listRect.bottom) list.scrollTop += rowRect.bottom - listRect.bottom
    })
  }

  function pick(row: MentionRow) {
    const tag = row.label || row.id
    const name = mentionFieldName(row.id, useHumanNames().names.value)
    if (name) picks.value = { ...picks.value, [name]: tag }
    const { caret } = setupCaretAndSync(opts, state)
    const next = insertMention(opts.text.value, caret(), name || tag)
    opts.text.value = next.text
    state.query.value = null
    opts.onPick?.(next.text)
    nextTick(() => {
      const el = opts.el.value
      if (!el) return
      el.focus()
      el.setSelectionRange(next.cursor, next.cursor)
    })
  }

  return { scrollActive, pick }
}

function setupInteractions(opts: {
  text: Ref<string>
  el: Ref<HTMLTextAreaElement | HTMLInputElement | null | undefined>
  blocked?: () => boolean
  onPick?: (text: string) => void
}, state: ReturnType<typeof setupState>) {
  const { caret, sync, close } = setupCaretAndSync(opts, state)
  const { scrollActive, pick } = setupScrollAndPick(opts, state)

  function onKeydown(ev: KeyboardEvent): boolean {
    if (ev.isComposing || !state.open.value) return false
    const n = state.candidates.value.length
    if (ev.key === 'ArrowDown') {
      ev.preventDefault()
      state.activeIdx.value = (state.activeIdx.value + 1) % n
      scrollActive()
      return true
    }
    if (ev.key === 'ArrowUp') {
      ev.preventDefault()
      state.activeIdx.value = (state.activeIdx.value - 1 + n) % n
      scrollActive()
      return true
    }
    if (ev.key === 'Tab' || (ev.key === 'Enter' && !ev.shiftKey)) {
      ev.preventDefault()
      const row = state.candidates.value[state.activeIdx.value]
      if (row) pick(row)
      return true
    }
    if (ev.key === 'Escape') {
      ev.preventDefault()
      ev.stopPropagation()
      close()
      return true
    }
    return false
  }

  return { sync, close, pick, onKeydown }
}

function setupEncoding(state: ReturnType<typeof setupState>) {
  const { picks } = state

  function encode(text: string): string {
    return encodeMentions(text, picks.value)
  }

  function decode(text: string): string {
    const people = useHumanNames()
    const d = decodeMentions(text, people.names.value)
    picks.value = { ...picks.value, ...d.picks }
    return d.text
  }

  return { encode, decode }
}

export function useMentionPicker(opts: {
  text: Ref<string>
  el: Ref<HTMLTextAreaElement | HTMLInputElement | null | undefined>
  blocked?: () => boolean
  onPick?: (text: string) => void
}) {
  const state = setupState()
  const interactions = setupInteractions(opts, state)
  const encoding = setupEncoding(state)

  return reactive({
    ...state,
    ...interactions,
    ...encoding,
  })
}

export type MentionPicker = ReturnType<typeof useMentionPicker>
