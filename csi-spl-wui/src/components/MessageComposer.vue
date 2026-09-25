<template>
  <form class="composer" :class="{ omnibox, 'omnibox--global': global, 'omnibox--search': searchMode }" @submit.prevent="onSend">
    <div class="composer-box">
      <!-- 022 FR-012: operator autocomplete in /search mode (catalogue: search-v1 §6) -->
      <ul
        v-if="opPickerOpen"
        ref="opListEl"
        :id="opListId"
        class="mention-list op-list"
        role="listbox"
        data-test="search-operators"
        :aria-label="t('search.operator_suggestions')"
      >
        <li v-for="(c, i) in opCandidates" :key="c.insert">
          <button
            :id="opListId + '-' + i"
            type="button"
            role="option"
            class="mention-item"
            :class="{ active: i === opIdx }"
            :aria-selected="i === opIdx"
            @mousedown.prevent="pickOp(c.insert)"
          >
            <code class="mention-label">{{ c.insert.trim() }}</code>
            <span v-if="c.label !== c.insert.trim()" class="muted op-example">{{ c.label }}</span>
          </button>
        </li>
      </ul>
      <ul
        v-if="pickerOpen"
        ref="mentionListEl"
        class="mention-list"
        role="listbox"
        :aria-label="t('composer.mention_suggestions')"
      >
        <li v-for="(p, i) in candidates" :key="p.label">
          <button
            type="button"
            role="option"
            class="mention-item"
            :class="{ active: i === activeIdx }"
            :aria-selected="i === activeIdx"
            @mousedown.prevent="pick(p)"
          >
            <SpoolAvatar :id="p.id" :box="p.box" :size="20" />
            <span class="dot" :class="{ on: p.online }" />
            <span class="mention-label">{{ people.label(p.id, p.box) }}</span>
            <span v-if="people.label(p.id, p.box) !== p.label" class="muted">{{ p.label }}</span>
          </button>
        </li>
      </ul>
      <ul
        v-if="inPickerOpen"
        ref="inListEl"
        class="mention-list"
        role="listbox"
        data-test="topic-in-suggestions"
        :aria-label="t('nav.topics')"
      >
        <li v-for="(row, i) in inCandidates" :key="row.taskId">
          <button
            type="button"
            role="option"
            class="mention-item"
            :class="{ active: i === inIdx }"
            :aria-selected="i === inIdx"
            @mousedown.prevent="pickIn(row)"
          >
            <span class="mention-label">{{ row.title }}</span>
            <span v-if="row.channel" class="muted">#{{ row.channel }}</span>
          </button>
        </li>
      </ul>
      <span v-if="searchMode" class="omnibox-mode" data-test="omnibox-mode">
        <UiIcon name="search" :size="14" />{{ t('search.mode_chip') }}
      </span>
      <div class="omnibox-field">
        <textarea
          ref="inputEl"
          :aria-label="global ? t('search.omnibox_label') : omnibox ? t('composer.omnibox_label') : t('composer.message_label')"
          :aria-controls="opPickerOpen ? opListId : undefined"
          :aria-activedescendant="opPickerOpen && opIdx >= 0 ? opListId + '-' + opIdx : undefined"
          :aria-keyshortcuts="global ? '/' : undefined"
          v-model="text"
          :rows="global ? 1 : 2"
          :class="{ 'in-code': inCode }"
          :placeholder="placeholder"
          :aria-describedby="global ? `${hintId} ${slashHintId}` : hintId"
          autocomplete="off"
          spellcheck="true"
          @keydown="onKeydown"
          @input="syncMention"
          @click="syncMention"
          @keyup="syncMention"
          @focus="onOmniboxFocus"
          @blur="onOmniboxBlur"
          @paste="onPaste"
        />
        <p :id="hintId" class="code-hint muted" aria-live="polite">{{ inCode ? t('composer.code_hint') : '' }}</p>
        <p v-if="global" :id="slashHintId" class="sr-only">{{ t('search.slash_shortcut') }}</p>
        <ul v-if="picked.length" class="file-chips">
          <li v-for="(f, i) in picked" :key="f.name + i">
            <img
              v-if="thumbs.get(f)"
              class="file-chip-thumb"
              data-test="composer-file-thumb"
              :src="thumbs.get(f)"
              :alt="f.name"
            >
            <UiIcon v-else :name="fileKind(f.name).icon" :size="16" class="file-kind-icon" :data-kind="fileKind(f.name).kind" />
            {{ f.name }} <small>{{ t('composer.file_bytes', { n: f.size }) }}</small>
            <button
              type="button"
              class="icon-btn"
              data-test="composer-remove-file"
              :aria-label="t('composer.remove_file', { name: f.name })"
              :title="t('composer.remove_file', { name: f.name })"
              @click="picked.splice(i, 1)"
            >
              <UiIcon name="x" :size="14" />
            </button>
          </li>
        </ul>
        <!-- a size refusal is a validation message, not a failure with a
             reference to quote, so it is NOT an ErrorNotice: minting an
             ERR-CLIENT-… into the diagnostics journal for "this snippet is
             long" would bury the failures that journal exists for -->
        <p v-if="pickLost" class="composer-too-big" role="status" data-testid="attach-nothing">
          <UiIcon name="alert-triangle" :size="16" />
          <span>{{ t('composer.attach_nothing') }}</span>
        </p>
        <p v-if="sizeError" class="composer-too-big" role="alert" data-testid="composer-too-big">
          <UiIcon name="alert-triangle" :size="16" />
          <span>{{ t(sizeError.key, sizeError.params) }}</span>
        </p>
        <button
          v-if="global"
          type="button"
          class="omnibox-resize"
          data-test="omnibox-resize"
          :aria-label="t('composer.resize')"
          @pointerdown="startResize"
        />
      </div>
      <div class="composer-row">
        <!-- Both controls are real buttons so Tab lands on each of them.
             A hidden file input is not a tab stop, and a disabled Send
             button is taken out of the tab order — that is the skip. -->
        <button
          v-if="!searchMode"
          type="button"
          class="attach"
          data-testid="attach"
          @mousedown.prevent
          @click="openFiles"
        >📎 {{ t('composer.attach') }}</button>
        <input
          v-if="!searchMode"
          ref="fileEl"
          type="file"
          multiple
          hidden
          tabindex="-1"
          data-testid="attach-input"
          @change="onFiles"
          @cancel="onPickCancel"
        >
        <button v-if="searchMode" type="submit" data-test="omnibox-search" :disabled="!searchQueryOf(text)">{{ t('search.submit') }}</button>
        <button
          v-else
          type="submit"
          class="composer-send"
          data-testid="send"
          @mousedown.prevent
          :aria-disabled="cannotSend ? 'true' : 'false'"
        >{{ busy ? t('composer.sending') : t('composer.send') }}</button>
      </div>
    </div>
  </form>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useRosterStore } from '~/stores/roster'
import { useViewerStore } from '~/stores/viewer'
import { closeOpenFence, enterAction, exitFence, fenceStateAt } from '~/utils/code-blocks.mjs'
import { omniboxFocusHeight, omniboxRememberHeight } from '~/utils/omnibox-size.mjs'
import { sendLimitError } from '~/utils/code-view.mjs'
import { fileKind, isPreviewableImage, readDataUrl } from '~/utils/file-preview.mjs'
import { carriesFiles, filesOf, pasteAttaches } from '~/utils/transfer-files.mjs'
import { useSidePane } from '~/composables/useSidePane'
import { useHumanNames } from '~/composables/useHumanNames'
import { parseOmnibox } from '~/utils/feed.mjs'
import { switchPaneOf } from '~/utils/sidebar-tabs.mjs'
import { applyCompletion, completeOperators, omniboxMode, operatorTokenAt, searchQueryOf, type SearchOperator } from '~/utils/search.mjs'
import {
  activeMentionQuery,
  filterRosterMentions,
  insertMention,
} from '~/utils/mention-autocomplete.mjs'
import {
  activeInQuery,
  filterTopicTitles,
  insertInClause,
  resolveInClause,
  topicChoices,
} from '~/utils/topic-in.mjs'

const props = defineProps<{
  placeholder?: string
  parentTaskId?: string
  busy?: boolean
  /** 013 Top Omnibox: Ctrl or Cmd+Enter sends; Enter inserts a line; `/search <q>` still submits on Enter; Esc clears the filter. */
  omnibox?: boolean
  /**
   * 022 top-bar Omnibox: `/search <q>` is a GLOBAL search (emit search, keep the
   * line for refining), operators autocomplete, Esc on an empty line → dismiss,
   * ArrowDown in search mode → results.
   */
  global?: boolean
  /** 022: no page send target — plain text cannot be sent (search still works) */
  sendBlocked?: boolean
  /** 022: the operator catalogue (search-v1 §6) */
  operators?: SearchOperator[]
}>()
const emit = defineEmits<{
  send: [text: string, parentTaskId?: string, files?: File[], channelId?: string]
  search: [q: string]
  dismiss: []
  results: []
}>()
const picked = ref<File[]>([])
/* a picked picture shows a thumbnail before it is sent (a data: URL: the
   deployed CSP admits no blob:); every other file shows its type icon */
const thumbs = shallowRef(new Map<File, string>())
watch(picked, async (files) => {
  const next = new Map<File, string>()
  for (const f of files) {
    const had = thumbs.value.get(f)
    if (had) next.set(f, had)
    else if (isPreviewableImage(f.name, f.size)) next.set(f, await readDataUrl(f))
  }
  thumbs.value = next
}, { deep: true })
const roster = useRosterStore()
const viewer = useViewerStore()
const channelFeed = useChannelStore()
const liveMain = useLiveFeed('main')
const text = ref('')
const inputEl = ref<HTMLTextAreaElement | null>(null)
/* A drag on the grip. Null until the reader sets one, then typing does not
   snap the box back. Kept across a collapse so the next focus can reopen it. */
const userHeight = ref<number | null>(null)
/* Last open height when the reader did not drag. Null when it was one line. */
const openHeight = ref<number | null>(null)
/* True after focus leaves, so a tall draft stays one line until the reader
   comes back. Ctrl+Enter does not park: the caret is still in the box. */
const parked = ref(false)
/* Ctrl+Enter collapses while the caret stays. The next key sizes to the new
   text; the saved height waits for the next focus. */
const contentUntilFocus = ref(false)
/* A fit queued by the send that clears the text must not reopen the box. */
let fitSerial = 0
function omniboxMax() {
  return Math.max(36, Math.floor(window.innerHeight - 52 - 8))
}
function collapseGlobalBox(park: boolean) {
  const el = inputEl.value
  if (!el || !props.global) return
  openHeight.value = omniboxRememberHeight({
    userHeight: userHeight.value,
    openHeight: openHeight.value,
    measured: Math.round(el.getBoundingClientRect().height),
    keep: parked.value || contentUntilFocus.value,
  })
  parked.value = park
  if (!park) {
    contentUntilFocus.value = true
    const serial = ++fitSerial
    void nextTick(() => {
      if (fitSerial === serial) fitSerial++
    })
  }
  el.style.height = '36px'
}
function onOmniboxFocus() {
  if (!props.global) return
  parked.value = false
  contentUntilFocus.value = false
  const px = omniboxFocusHeight(userHeight.value, openHeight.value, omniboxMax())
  const el = inputEl.value
  if (px != null && el) {
    el.style.height = `${px}px`
    return
  }
  void nextTick(fitGlobalBox)
}
function onOmniboxBlur(ev: FocusEvent) {
  if (!props.global) return
  const next = ev.relatedTarget
  if (next instanceof Element && next.closest('[data-test="omnibox-resize"]')) return
  collapseGlobalBox(true)
}
/* Attach and Send swallow their mousedown (@mousedown.prevent): the focus
   stays in the box, so the blur above does not snap a tall draft to one line
   the moment the reader reaches for Attach (measured 126px -> 36px on the
   mock, 2026-09-25). The click itself fired either way in Chromium. */
/* field-sizing is not enough inside the top-bar flex row: the used height
   stays one line. Measure the text and set the height. Only the field grows.
   The automatic size stops at 40% of the window; the grip can go to the
   bottom of the screen. The bar itself stays 52px. */
function fitGlobalBox() {
  const el = inputEl.value
  if (!el || !props.global || parked.value) return
  if (!contentUntilFocus.value && userHeight.value != null) {
    const px = omniboxFocusHeight(userHeight.value, null, omniboxMax())
    if (px != null) {
      el.style.height = `${px}px`
      return
    }
  }
  el.style.height = 'auto'
  const cap = Math.min(omniboxMax(), Math.floor(window.innerHeight * 0.4))
  el.style.height = `${Math.min(el.scrollHeight, cap)}px`
}
function startResize(ev: PointerEvent) {
  const el = inputEl.value
  const handle = ev.currentTarget
  if (!el || !(handle instanceof HTMLElement)) return
  ev.preventDefault()
  handle.setPointerCapture(ev.pointerId)
  const startY = ev.clientY
  const startH = el.getBoundingClientRect().height
  const move = (e: PointerEvent) => {
    const next = Math.min(omniboxMax(), Math.max(36, Math.round(startH + (e.clientY - startY))))
    userHeight.value = next
    el.style.height = `${next}px`
  }
  const end = () => {
    handle.removeEventListener('pointermove', move)
    handle.removeEventListener('pointerup', end)
    handle.removeEventListener('pointercancel', end)
  }
  handle.addEventListener('pointermove', move)
  handle.addEventListener('pointerup', end)
  handle.addEventListener('pointercancel', end)
}
watch(text, () => {
  if (!props.global) return
  const serial = fitSerial
  void nextTick(() => {
    if (serial !== fitSerial) return
    fitGlobalBox()
  })
})
onMounted(() => { fitGlobalBox() })
const fileEl = ref<HTMLInputElement | null>(null)
/* Empty, busy, or with nowhere to send: the button stays in the tab order
   (aria-disabled, not disabled) and onSend refuses the click. */
const cannotSend = computed(() => Boolean(props.busy) || Boolean(props.sendBlocked) || (!text.value.trim() && !picked.value.length))
const mentionQuery = ref<string | null>(null)
const activeIdx = ref(0)
const mentionListEl = ref<HTMLUListElement | null>(null)
const inQuery = ref<string | null>(null)
const inIdx = ref(0)
const inListEl = ref<HTMLUListElement | null>(null)
/** The topic the reader picked, so two starters with one title stay distinct. */
const pickedIn = ref<{ taskId: string, title: string, channel: string } | null>(null)
const topicsAsked = ref(false)
/** Slack's ``` composer: the caret sits inside an open code block. */
const inCode = ref(false)
/**
 * 013 FR-018 — the send-time size gate. A code block past 3 A4
 * (code-view.mjs SEND_LIMIT: 150 lines / 9000 chars) is a file, not a
 * message: the send is refused here and the author is told to attach it
 * instead. Held as { key, params } so the 19 catalogues own the wording.
 */
const sizeError = ref<ReturnType<typeof sendLimitError>>(null)
const hintId = useId()
const slashHintId = useId()
const opListId = useId()
const opIdx = ref(0)
const opListEl = ref<HTMLUListElement | null>(null)
/** caret offset, kept in sync so the operator picker follows it */
const caretAt = ref(0)
const opClosed = ref(false)
const searchMode = computed(() => Boolean(props.omnibox || props.global) && omniboxMode(text.value) === 'search')
const opTok = computed(() => (searchMode.value ? operatorTokenAt(text.value, caretAt.value) : null))
const opCandidates = computed(() => (opTok.value ? completeOperators(opTok.value.token, props.operators, roster.peers).slice(0, 8) : []))
const opPickerOpen = computed(() => !opClosed.value && opCandidates.value.length > 0)

/** Same scroll as the mention list: arrows move this dropdown, not the page. */
function scrollActiveOp() {
  nextTick(() => {
    const list = opListEl.value
    if (!list) return
    const row = list.querySelectorAll<HTMLElement>('.mention-item')[opIdx.value]
    if (!row) return
    const listRect = list.getBoundingClientRect()
    const rowRect = row.getBoundingClientRect()
    if (rowRect.top < listRect.top) list.scrollTop += rowRect.top - listRect.top
    else if (rowRect.bottom > listRect.bottom) list.scrollTop += rowRect.bottom - listRect.bottom
  })
}

function onOperatorKey(ev: KeyboardEvent): boolean {
  if (!opPickerOpen.value) return false
  const n = opCandidates.value.length
  if (ev.key === 'ArrowDown') {
    ev.preventDefault()
    opIdx.value = (opIdx.value + 1) % n
    scrollActiveOp()
    return true
  }
  if (ev.key === 'ArrowUp') {
    ev.preventDefault()
    opIdx.value = (opIdx.value - 1 + n) % n
    scrollActiveOp()
    return true
  }
  if (ev.key === 'Tab' || (ev.key === 'Enter' && !ev.shiftKey)) {
    ev.preventDefault()
    const c = opCandidates.value[opIdx.value]
    if (c) pickOp(c.insert)
    return true
  }
  if (ev.key === 'Escape') {
    ev.preventDefault()
    opClosed.value = true
    return true
  }
  return false
}

function pickOp(insert: string) {
  const tok = opTok.value
  if (!tok) return
  const next = applyCompletion(text.value, tok, insert)
  text.value = next.text
  caretAt.value = next.cursor
  opIdx.value = 0
  nextTick(() => {
    const el = inputEl.value
    if (!el) return
    el.focus()
    el.setSelectionRange(next.cursor, next.cursor)
  })
}

/** 022: the top bar sets the line (deep link ?q=, mobile expand) */
function setText(s: string) {
  text.value = s
  nextTick(() => {
    const el = inputEl.value
    if (!el) return
    caretAt.value = s.length
    el.setSelectionRange(s.length, s.length)
  })
}
function focusInput() {
  inputEl.value?.focus()
}
/* CLE-3433: the box is cleared on emit, because the emit is fire-and-forget
   and there is nothing to await. That is fine as long as a caller whose send
   FAILED can put the text back - otherwise the only copy of what the human
   wrote is gone, which is exactly how the owner lost a message. */
function restore(body: string, files?: File[]) {
  text.value = body
  if (files && files.length) picked.value = [...files]
  focusInput()
}
defineExpose({ setText, focus: focusInput, restore })

const { t } = useI18n({ useScope: 'global' })
const placeholder = computed(() => props.placeholder || t('composer.placeholder_default', { mention: '@CLE-07' }))

function caret(): number {
  return inputEl.value?.selectionStart ?? text.value.length
}

/* a refusal is about the text that was there; editing it clears it */
watch(text, () => { sizeError.value = null })

function syncMention(ev?: Event) {
  const prevTok = opTok.value && opTok.value.token
  caretAt.value = caret()
  if (ev && ev.type !== 'keyup' && opTok.value?.token !== prevTok) {
    opClosed.value = false
    opIdx.value = 0
    nextTick(() => {
      if (opListEl.value) opListEl.value.scrollTop = 0
    })
  }
  if (searchMode.value) {
    // a search line is a query: no code block, no @-picker, no topic picker
    inCode.value = false
    mentionQuery.value = null
    inQuery.value = null
    return
  }
  inCode.value = fenceStateAt(text.value, caret()).inCode
  // no @-autocomplete inside a code block: the text there is literal
  const q = inCode.value ? null : activeMentionQuery(text.value, caret())
  if (q !== mentionQuery.value) {
    activeIdx.value = 0
    nextTick(() => {
      if (mentionListEl.value) mentionListEl.value.scrollTop = 0
    })
  }
  mentionQuery.value = q
  /* `in:` is the topic-title picker. An @ token at the caret wins, same as a code fence. */
  const nextIn = (inCode.value || q !== null) ? null : activeInQuery(text.value, caret())
  if (nextIn !== inQuery.value) {
    inIdx.value = 0
    nextTick(() => {
      if (inListEl.value) inListEl.value.scrollTop = 0
    })
  }
  inQuery.value = nextIn
}

/* @ finds a person by id or by the display name they chose; the tag inserted is still the id. */
const people = useHumanNames()
const candidates = computed(() => {
  if (mentionQuery.value === null) return []
  return filterRosterMentions(roster.peers, mentionQuery.value, people.names.value)
})

const pickerOpen = computed(() => mentionQuery.value !== null && candidates.value.length > 0)

const topicCatalogue = computed(() => topicChoices({
  topics: viewer.topics,
  messages: [...channelFeed.messages, ...liveMain.messages],
}))
const inCandidates = computed(() => (
  inQuery.value === null ? [] : filterTopicTitles(topicCatalogue.value, inQuery.value)
))
const inPickerOpen = computed(() => inQuery.value !== null && inCandidates.value.length > 0 && !pickerOpen.value)

watch(inQuery, (q) => {
  if (q === null || topicsAsked.value || viewer.topics.length > 0) return
  topicsAsked.value = true
  void viewer.loadTopics()
})

/** Arrow keys move the highlight. Scroll only this list: scrollIntoView also moves the page under the bar. */
function scrollActiveMention() {
  nextTick(() => {
    const list = mentionListEl.value
    if (!list) return
    const row = list.querySelectorAll<HTMLElement>('.mention-item')[activeIdx.value]
    if (!row) return
    const listRect = list.getBoundingClientRect()
    const rowRect = row.getBoundingClientRect()
    if (rowRect.top < listRect.top) list.scrollTop += rowRect.top - listRect.top
    else if (rowRect.bottom > listRect.bottom) list.scrollTop += rowRect.bottom - listRect.bottom
  })
}

function pick(peer: { id: string, label?: string }) {
  const token = peer.label || peer.id
  const next = insertMention(text.value, caret(), token)
  text.value = next.text
  mentionQuery.value = null
  nextTick(() => {
    const el = inputEl.value
    if (!el) return
    el.focus()
    el.setSelectionRange(next.cursor, next.cursor)
  })
}

function scrollActiveIn() {
  nextTick(() => {
    const list = inListEl.value
    if (!list) return
    const row = list.querySelectorAll<HTMLElement>('.mention-item')[inIdx.value]
    if (!row) return
    const listRect = list.getBoundingClientRect()
    const rowRect = row.getBoundingClientRect()
    if (rowRect.top < listRect.top) list.scrollTop += rowRect.top - listRect.top
    else if (rowRect.bottom > listRect.bottom) list.scrollTop += rowRect.bottom - listRect.bottom
  })
}

function pickIn(row: { taskId: string, title: string, channel: string }) {
  const next = insertInClause(text.value, caret(), row.title)
  text.value = next.text
  pickedIn.value = { taskId: row.taskId, title: row.title, channel: row.channel }
  inQuery.value = null
  nextTick(() => {
    const el = inputEl.value
    if (!el) return
    el.focus()
    el.setSelectionRange(next.cursor, next.cursor)
  })
}

function onKeydown(ev: KeyboardEvent) {
  if (ev.isComposing) return
  if (onOperatorKey(ev)) return
  if (props.global && onGlobalKey(ev)) return
  if (inCode.value && ev.key === 'Escape' && !pickerOpen.value && !inPickerOpen.value) {
    // Slack's exit: close the block at the caret, keep typing below it
    ev.preventDefault()
    const next = exitFence(text.value, caret())
    text.value = next.text
    inCode.value = false
    nextTick(() => inputEl.value?.setSelectionRange(next.cursor, next.cursor))
    return
  }
  if (props.omnibox && ev.key === 'Escape' && !pickerOpen.value && !inPickerOpen.value) {
    emit('search', '')
    return
  }
  if (pickerOpen.value) {
    const n = candidates.value.length
    if (ev.key === 'ArrowDown') {
      ev.preventDefault()
      activeIdx.value = (activeIdx.value + 1) % n
      scrollActiveMention()
      return
    }
    if (ev.key === 'ArrowUp') {
      ev.preventDefault()
      activeIdx.value = (activeIdx.value - 1 + n) % n
      scrollActiveMention()
      return
    }
    if (ev.key === 'Tab' || (ev.key === 'Enter' && !ev.shiftKey)) {
      ev.preventDefault()
      const row = candidates.value[activeIdx.value]
      if (row) pick(row)
      return
    }
    if (ev.key === 'Escape') {
      ev.preventDefault()
      mentionQuery.value = null
      return
    }
  }
  if (inPickerOpen.value) {
    const n = inCandidates.value.length
    if (ev.key === 'ArrowDown') {
      ev.preventDefault()
      inIdx.value = (inIdx.value + 1) % n
      scrollActiveIn()
      return
    }
    if (ev.key === 'ArrowUp') {
      ev.preventDefault()
      inIdx.value = (inIdx.value - 1 + n) % n
      scrollActiveIn()
      return
    }
    if (ev.key === 'Tab' || (ev.key === 'Enter' && !ev.shiftKey)) {
      ev.preventDefault()
      const row = inCandidates.value[inIdx.value]
      if (row) pickIn(row)
      return
    }
    if (ev.key === 'Escape') {
      ev.preventDefault()
      inQuery.value = null
      return
    }
  }
  if (ev.key === 'Enter') {
    const state = fenceStateAt(text.value, caret())
    inCode.value = state.inCode
    const act = enterAction({ inCode: state.inCode, shift: ev.shiftKey, alt: ev.altKey, mod: ev.ctrlKey || ev.metaKey })
    if (act === 'send') {
      ev.preventDefault()
      onSend()
      collapseGlobalBox(false)
    }
  }
}

/** 022 top-bar keys; true = handled. */
function onGlobalKey(ev: KeyboardEvent): boolean {
  if (searchMode.value) {
    if (ev.key === 'Enter' && !ev.shiftKey && (ev.ctrlKey || ev.metaKey)) {
      ev.preventDefault()
      onSend()
      collapseGlobalBox(false)
      return true
    }
    if (ev.key === 'Enter' && !ev.shiftKey) {
      ev.preventDefault()
      onSend()
      collapseGlobalBox(false)
      return true
    }
    if (ev.key === 'ArrowDown' && caret() === text.value.length) {
      ev.preventDefault()
      emit('results')
      return true
    }
  }
  if (ev.key === 'Escape' && !inCode.value && !pickerOpen.value && !inPickerOpen.value) {
    ev.preventDefault()
    if (text.value) text.value = ''
    else emit('dismiss')
    return true
  }
  return false
}

function onSend() {
  /* `/switch-pane: messages|channels|topics|flow` changes the left pane
     and is never sent. `topic` is the same pane. An unknown name stays in the box. */
  if (props.global || props.omnibox) {
    const pane = switchPaneOf(text.value)
    if (pane !== null) {
      if (pane) {
        useSidePane().request(pane)
        text.value = ''
        picked.value = []
        mentionQuery.value = null
        inQuery.value = null
      }
      return
    }
  }
  if (props.global && searchMode.value) {
    // the rest of the line goes to the hub verbatim (search-v1 §0)
    emit('search', searchQueryOf(text.value))
    opClosed.value = true
    return
  }
  if (props.global && props.sendBlocked) return
  /* Enter and the Send button both land here. An open title list picks;
     it does not send the half-typed `in:`. */
  if (inPickerOpen.value) {
    const row = inCandidates.value[inIdx.value]
    if (row) pickIn(row)
    return
  }
  if (props.omnibox && !props.global) {
    const parsed = parseOmnibox(text.value)
    if ('search' in parsed) {
      emit('search', parsed.search || '')
      text.value = ''
      return
    }
  }
  let body = closeOpenFence(text.value).trim()
  let topicId = props.parentTaskId
  let channelId: string | undefined
  if ((props.global || props.omnibox) && body) {
    const resolved = resolveInClause(body, topicCatalogue.value)
    if (resolved.taskId) {
      const chosen = pickedIn.value
      const same = Boolean(chosen && resolved.title.toLowerCase() === chosen.title.toLowerCase())
      body = resolved.body
      topicId = same && chosen ? chosen.taskId : resolved.taskId
      channelId = (same && chosen ? chosen.channel : resolved.channel) || undefined
    }
  }
  if ((!body && !picked.value.length) || props.busy) return
  const tooBig = sendLimitError(body)
  if (tooBig) {
    // nothing is sent and nothing is cleared: the author keeps the text and
    // can attach it as a file (005 T023 upload) instead
    sizeError.value = tooBig
    return
  }
  emit('send', body, topicId, picked.value.slice(), channelId)
  text.value = ''
  picked.value = []
  mentionQuery.value = null
  inQuery.value = null
  pickedIn.value = null
  inCode.value = false
}

/* Owner, 2026-09-25: eight tries, eight messages with no file, and not a
   word on screen. A DOUBLE-CLICK on the file in the GTK file dialog lost the
   pick before the page saw it (Select + Open worked, n=1). The page cannot
   get that file back, but it must not stay silent: when the dialog closes
   with nothing, say so and name the two ways that work. Chrome fires
   `cancel` on the input for an empty close; a close that fires neither
   `change` nor `cancel` is caught when the window gets the focus back. */
const pickLost = ref(false)
let awaitingPick = false
let pickTimer: ReturnType<typeof setTimeout> | null = null

function clearPickWait() {
  awaitingPick = false
  if (pickTimer) clearTimeout(pickTimer)
  pickTimer = null
  window.removeEventListener('focus', onWindowFocusAfterPick)
}

function onWindowFocusAfterPick() {
  if (!awaitingPick) return
  if (pickTimer) clearTimeout(pickTimer)
  pickTimer = setTimeout(() => {
    if (awaitingPick) pickLost.value = true
    clearPickWait()
  }, 1000)
}

function openFiles() {
  pickLost.value = false
  clearPickWait()
  awaitingPick = true
  window.addEventListener('focus', onWindowFocusAfterPick)
  fileEl.value?.click()
}

function onPickCancel() {
  clearPickWait()
  pickLost.value = true
}

function onFiles(ev: Event) {
  clearPickWait()
  const input = ev.target as HTMLInputElement
  if (!input.files || input.files.length === 0) {
    pickLost.value = true
    return
  }
  pickLost.value = false
  // uploaded on send (POST /v1/files), then referenced by file_id in files[]
  picked.value = [...picked.value, ...input.files]
  input.value = ''
}
onBeforeUnmount(clearPickWait)

/* A pasted screenshot or copied file is attached, as if picked with Attach.
   A paste with no files, or rich text from a document, stays a text paste. */
function onPaste(ev: ClipboardEvent) {
  if (!pasteAttaches(ev.clipboardData)) return
  ev.preventDefault()
  pickLost.value = false
  picked.value = [...picked.value, ...filesOf(ev.clipboardData)]
}

/* A file dropped anywhere on the page is attached to the Omnibox. Without
   this the browser opens the dropped file and leaves the app. Only the one
   global Omnibox listens, so a drop is attached once. */
function onWindowDragOver(ev: DragEvent) {
  if (!carriesFiles(ev.dataTransfer)) return
  ev.preventDefault()
  if (ev.dataTransfer) ev.dataTransfer.dropEffect = 'copy'
}

function onWindowDrop(ev: DragEvent) {
  if (!carriesFiles(ev.dataTransfer)) return
  ev.preventDefault()
  const files = filesOf(ev.dataTransfer)
  if (!files.length) return
  pickLost.value = false
  picked.value = [...picked.value, ...files]
  focusInput()
}

onMounted(() => {
  if (!props.global) return
  window.addEventListener('dragover', onWindowDragOver)
  window.addEventListener('drop', onWindowDrop)
})
onBeforeUnmount(() => {
  window.removeEventListener('dragover', onWindowDragOver)
  window.removeEventListener('drop', onWindowDrop)
})
</script>

<style scoped>
.composer-too-big {
  display: flex;
  align-items: flex-start;
  gap: 6px;
  margin: 0 0 6px;
  padding: 6px 8px;
  border: 1px solid var(--color-danger);
  border-radius: var(--radius);
  background: var(--color-bg-2);
  color: var(--color-danger);
  font-size: 0.75rem;
  max-width: 100%;
  min-width: 0;
  overflow-wrap: anywhere;
}
.composer-too-big span { min-width: 0; }
textarea.in-code {
  font-family: var(--font-mono);
  font-size: 0.8125rem;
  background: var(--color-bg-2);
}
/* kept in the tree while empty so the live region announces entering a block */
.code-hint {
  margin: 0;
  font-size: 0.6875rem;
  overflow-wrap: anywhere;
}
.file-chips {
  list-style: none;
  margin: 0 0 6px;
  padding: 0;
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  max-width: 100%;
  min-width: 0;
}
.file-kind-icon {
  vertical-align: middle;
  margin-right: 4px;
  color: var(--color-muted);
}
.file-kind-icon[data-kind="pdf"] { color: #d93025; }
.file-kind-icon[data-kind="doc"] { color: #2b6cd4; }
.file-kind-icon[data-kind="sheet"] { color: #1e8e3e; }
.file-kind-icon[data-kind="slides"] { color: #e8710a; }
.file-chip-thumb {
  display: inline-block;
  vertical-align: middle;
  width: 32px;
  height: 32px;
  object-fit: contain;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: repeating-conic-gradient(var(--color-bg-2) 0 25%, var(--color-surface) 0 50%) 0 0 / 8px 8px;
  margin-right: 4px;
}
.file-chips li {
  font-size: 0.75rem;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 2px 6px;
  overflow-wrap: anywhere;
  min-width: 0;
}
.attach {
  cursor: pointer;
  background: transparent;
  color: var(--color-muted);
  border: 0;
  font-weight: 400;
  box-shadow: none;
}
.composer-send[aria-disabled='true'] { opacity: 0.45; }
.mention-list {
  list-style: none;
  margin: 0 0 8px;
  padding: 4px 0;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  max-height: 180px;
  min-height: 0;
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior: contain;
  max-width: 100%;
  min-width: 0;
}
.mention-list li {
  margin: 0;
  padding: 0;
  max-width: 100%;
  min-width: 0;
}
.mention-item {
  border-radius: var(--radius-sm);
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  max-width: 100%;
  min-width: 0;
  min-height: var(--tap);
  padding: 6px 10px;
  background: transparent;
  border: 0;
  color: var(--color-fg);
  cursor: pointer;
  text-align: left;
  font-size: 0.8125rem;
  box-sizing: border-box;
}
.mention-item:hover {
  background: var(--color-surface-hover);
}
/* CLE-3427: the highlighted suggestion is a SELECTED list row — darker fill,
   one 3px marker bar in the shared ring colour. */
.mention-item.active {
  background: var(--color-selected);
  box-shadow: inset var(--select-bar-w) 0 0 var(--focus-ring);
}
.mention-label {
  min-width: 0;
  overflow-wrap: anywhere;
}
.omnibox-mode {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 0.6875rem;
  padding: 1px 8px;
  margin: 0 0 4px;
  border-radius: var(--radius-pill);
  background: var(--color-accent);
  color: var(--color-on-accent);
  max-width: 100%;
}
.op-list code { font-family: var(--font-mono); }
.op-example {
  font-size: 0.75rem;
  min-width: 0;
  overflow-wrap: anywhere;
}
/* 022: in the top bar the pickers drop DOWN over the page, not up into the bar */
.omnibox--global .composer-box { position: relative; }
.omnibox--global .mention-list {
  position: absolute;
  top: 100%;
  inset-inline: 0;
  margin: 4px 0 0;
  z-index: 60;
  box-shadow: 0 8px 24px rgb(0 0 0 / .25);
}
</style>
