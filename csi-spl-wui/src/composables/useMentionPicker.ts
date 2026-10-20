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
import { feedbackChannelFromPath, isFeedbackChannel } from '~/utils/feedback-channel'
import { activeMentionQuery, decodeMentions, encodeMentions, insertMention, mentionCandidates, mentionFieldName } from '~/utils/mention-autocomplete.mjs'

export interface MentionRow { id: string, box?: string, label?: string, online?: boolean, idle?: boolean, owner?: boolean, sameName?: boolean }

interface MentionPickerOpts {
  text: Ref<string>
  el: Ref<HTMLTextAreaElement | HTMLInputElement | null | undefined>
  /** true = no list here (inside a ``` block, on a /search line) */
  blocked?: () => boolean
  /** after a pick changed the text (a field that reports its draft by @input) */
  onPick?: (text: string) => void
}

/** The rows the list shows for `query`; in the feedback channel the owners come first. */
function candidateRows(query: string | null, roster: ReturnType<typeof useRosterStore>, people: ReturnType<typeof useHumanNames>, inFeedback: Ref<boolean>): MentionRow[] {
  if (query === null) return []
  return mentionCandidates({
    peers: roster.peers,
    names: people.names.value,
    owners: roster.owners,
    selfId: roster.self ? roster.self.id : '',
    query,
    ownersFirst: inFeedback.value,
    isOnline: (id: string) => roster.isOnline(id, 'box-wui'),
  }).map((row: MentionRow) => (
    /* two members with one name: the row shows the id as a muted suffix */
    /^HUM-\d+$/.test(row.id) && people.names.value[row.id] && !mentionFieldName(row.id, people.names.value) ? { ...row, sameName: true } : row
  ))
}

/** The list's highlighted row: reset to the top on a new query, moved by the arrow keys. */
function useActiveRow() {
  const activeIdx = ref(0)
  const listEl = ref<HTMLUListElement | null>(null)

  function reset() {
    activeIdx.value = 0
    nextTick(() => { if (listEl.value) listEl.value.scrollTop = 0 })
  }

  /** Arrow keys move this list only: scrollIntoView would also move the page. */
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

  /** one row down (step 1) or up (step -1) in a list of n rows, wrapping round */
  function move(step: number, n: number) {
    activeIdx.value = (activeIdx.value + step + n) % n
    scrollActive()
  }

  return { activeIdx, listEl, reset, move }
}

/** What a key does to an open list: move, pick, close, or nothing (null). */
function listKey(ev: KeyboardEvent): 'down' | 'up' | 'pick' | 'close' | null {
  if (ev.key === 'ArrowDown') return 'down'
  if (ev.key === 'ArrowUp') return 'up'
  if (ev.key === 'Tab' || (ev.key === 'Enter' && !ev.shiftKey)) return 'pick'
  if (ev.key === 'Escape') return 'close'
  return null
}

/** After a pick: the caret goes back into the field, just past the inserted name. */
function focusAt(el: HTMLTextAreaElement | HTMLInputElement | null | undefined, cursor: number) {
  if (!el) return
  el.focus()
  el.setSelectionRange(cursor, cursor)
}

export function useMentionPicker(opts: MentionPickerOpts) {
  const roster = useRosterStore()
  const people = useHumanNames()
  const route = useRoute()
  const query = ref<string | null>(null)
  const { activeIdx, listEl, reset, move } = useActiveRow()
  const listId = useId()
  /** name -> tag of every person this field shows by name (encode() puts the tag back) */
  const picks = ref<Record<string, string>>({})

  const inFeedback = computed(() => isFeedbackChannel(feedbackChannelFromPath(route.path)))
  const candidates = computed<MentionRow[]>(() => candidateRows(query.value, roster, people, inFeedback))
  const open = computed(() => query.value !== null && candidates.value.length > 0)

  function caret(): number {
    return opts.el.value?.selectionStart ?? opts.text.value.length
  }

  /** input / click / keyup: re-read the @token at the caret. */
  function sync() {
    const q = opts.blocked && opts.blocked() ? null : activeMentionQuery(opts.text.value, caret())
    if (q !== query.value) reset()
    query.value = q
  }

  function close() {
    query.value = null
  }

  function pick(row: MentionRow) {
    const tag = row.label || row.id
    const name = mentionFieldName(row.id, people.names.value)
    if (name) picks.value = { ...picks.value, [name]: tag }
    const next = insertMention(opts.text.value, caret(), name || tag)
    opts.text.value = next.text
    query.value = null
    opts.onPick?.(next.text)
    nextTick(() => focusAt(opts.el.value, next.cursor))
  }

  /** keydown: true when the picker used the key (the field must not act on it). */
  function onKeydown(ev: KeyboardEvent): boolean {
    if (ev.isComposing || !open.value) return false
    const key = listKey(ev)
    if (!key) return false
    ev.preventDefault()
    if (key === 'down' || key === 'up') move(key === 'down' ? 1 : -1, candidates.value.length)
    else if (key === 'pick') {
      const row = candidates.value[activeIdx.value]
      if (row) pick(row)
    } else {
      /* the Escape is the list's: a dialog or the omnibox must not also act on it */
      ev.stopPropagation()
      close()
    }
    return true
  }

  /** The field text as it is stored: every picked name is its tag again. */
  function encode(text: string): string {
    return encodeMentions(text, picks.value)
  }

  /** A stored text as the field shows it: members by name (the tags are kept for encode). */
  function decode(text: string): string {
    const d = decodeMentions(text, people.names.value)
    picks.value = { ...picks.value, ...d.picks }
    return d.text
  }

  return reactive({ query, open, candidates, activeIdx, listEl, listId, sync, close, pick, onKeydown, encode, decode })
}

export type MentionPicker = ReturnType<typeof useMentionPicker>
