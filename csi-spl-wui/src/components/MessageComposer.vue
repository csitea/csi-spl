<template>
  <form class="composer" :class="{ omnibox, 'omnibox--global': global, 'omnibox--search': searchMode }" @submit.prevent="onSend">
    <div class="composer-box">
      <!-- 022 FR-012: operator autocomplete in /search mode (catalogue: search-v1 §6) -->
      <ul
        v-if="opPickerOpen"
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
            <span class="mention-label">{{ p.label }}</span>
          </button>
        </li>
      </ul>
      <span v-if="searchMode" class="omnibox-mode" data-test="omnibox-mode">
        <UiIcon name="search" :size="14" />{{ t('search.mode_chip') }}
      </span>
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
      />
      <p :id="hintId" class="code-hint muted" aria-live="polite">{{ inCode ? t('composer.code_hint') : '' }}</p>
      <p v-if="global" :id="slashHintId" class="sr-only">{{ t('search.slash_shortcut') }}</p>
      <ul v-if="picked.length" class="file-chips">
        <li v-for="(f, i) in picked" :key="f.name + i">
          📎 {{ f.name }} <small>{{ t('composer.file_bytes', { n: f.size }) }}</small>
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
      <p v-if="sizeError" class="composer-too-big" role="alert" data-testid="composer-too-big">
        <UiIcon name="alert-triangle" :size="16" />
        <span>{{ t(sizeError.key, sizeError.params) }}</span>
      </p>
      <div class="composer-row">
        <label v-if="!searchMode" class="muted attach">
          <input type="file" multiple hidden data-testid="attach" @change="onFiles">
          📎 {{ t('composer.attach') }}
        </label>
        <button v-if="searchMode" type="submit" data-test="omnibox-search" :disabled="!searchQueryOf(text)">{{ t('search.submit') }}</button>
        <button v-else type="submit" :disabled="busy || sendBlocked || (!text.trim() && !picked.length)">{{ busy ? t('composer.sending') : t('composer.send') }}</button>
      </div>
    </div>
  </form>
</template>

<script setup lang="ts">
import { useRosterStore } from '~/stores/roster'
import { closeOpenFence, enterAction, exitFence, fenceStateAt } from '~/utils/code-blocks.mjs'
import { sendLimitError } from '~/utils/code-view.mjs'
import { parseOmnibox } from '~/utils/feed.mjs'
import { applyCompletion, completeOperators, omniboxMode, operatorTokenAt, searchQueryOf, type SearchOperator } from '~/utils/search.mjs'
import {
  activeMentionQuery,
  filterRosterMentions,
  insertMention,
} from '~/utils/mention-autocomplete.mjs'

const props = defineProps<{
  placeholder?: string
  parentTaskId?: string
  busy?: boolean
  /** 013 Top Omnibox: Enter sends; `/search <q>` filters instead; Esc clears the filter. */
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
  send: [text: string, parentTaskId?: string, files?: File[]]
  search: [q: string]
  dismiss: []
  results: []
}>()
const picked = ref<File[]>([])
const roster = useRosterStore()
const text = ref('')
const inputEl = ref<HTMLTextAreaElement | null>(null)
const mentionQuery = ref<string | null>(null)
const activeIdx = ref(0)
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
/** caret offset, kept in sync so the operator picker follows it */
const caretAt = ref(0)
const opClosed = ref(false)
const searchMode = computed(() => Boolean(props.global) && omniboxMode(text.value) === 'search')
const opTok = computed(() => (searchMode.value ? operatorTokenAt(text.value, caretAt.value) : null))
const opCandidates = computed(() => (opTok.value ? completeOperators(opTok.value.token, props.operators).slice(0, 8) : []))
const opPickerOpen = computed(() => !opClosed.value && opCandidates.value.length > 0)

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
  }
  if (searchMode.value) {
    // a search line is a query: no code block, no @-picker
    inCode.value = false
    mentionQuery.value = null
    return
  }
  inCode.value = fenceStateAt(text.value, caret()).inCode
  // no @-autocomplete inside a code block: the text there is literal
  const q = inCode.value ? null : activeMentionQuery(text.value, caret())
  if (q !== mentionQuery.value) activeIdx.value = 0
  mentionQuery.value = q
}

const candidates = computed(() => {
  if (mentionQuery.value === null) return []
  return filterRosterMentions(roster.peers, mentionQuery.value)
})

const pickerOpen = computed(() => mentionQuery.value !== null && candidates.value.length > 0)

function pick(peer: { id: string }) {
  const next = insertMention(text.value, caret(), peer.id)
  text.value = next.text
  mentionQuery.value = null
  nextTick(() => {
    const el = inputEl.value
    if (!el) return
    el.focus()
    el.setSelectionRange(next.cursor, next.cursor)
  })
}

function onKeydown(ev: KeyboardEvent) {
  if (ev.isComposing) return
  if (props.global && onGlobalKey(ev)) return
  if (inCode.value && ev.key === 'Escape' && !pickerOpen.value) {
    // Slack's exit: close the block at the caret, keep typing below it
    ev.preventDefault()
    const next = exitFence(text.value, caret())
    text.value = next.text
    inCode.value = false
    nextTick(() => inputEl.value?.setSelectionRange(next.cursor, next.cursor))
    return
  }
  if (props.omnibox && ev.key === 'Escape' && !pickerOpen.value) {
    emit('search', '')
    return
  }
  if (pickerOpen.value) {
    const n = candidates.value.length
    if (ev.key === 'ArrowDown') {
      ev.preventDefault()
      activeIdx.value = (activeIdx.value + 1) % n
      return
    }
    if (ev.key === 'ArrowUp') {
      ev.preventDefault()
      activeIdx.value = (activeIdx.value - 1 + n) % n
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
  if (ev.key === 'Enter') {
    const state = fenceStateAt(text.value, caret())
    inCode.value = state.inCode
    const act = enterAction({ inCode: state.inCode, shift: ev.shiftKey, alt: ev.altKey, mod: ev.ctrlKey || ev.metaKey })
    if (act === 'send') {
      ev.preventDefault()
      onSend()
    }
  }
}

/** 022 top-bar keys; true = handled. */
function onGlobalKey(ev: KeyboardEvent): boolean {
  if (opPickerOpen.value) {
    const n = opCandidates.value.length
    if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
      ev.preventDefault()
      opIdx.value = ev.key === 'ArrowDown' ? (opIdx.value + 1) % n : (opIdx.value - 1 + n) % n
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
  }
  if (searchMode.value) {
    if (ev.key === 'Enter' && !ev.shiftKey) {
      ev.preventDefault()
      onSend()
      return true
    }
    if (ev.key === 'ArrowDown' && caret() === text.value.length) {
      ev.preventDefault()
      emit('results')
      return true
    }
  }
  if (ev.key === 'Escape' && !inCode.value && !pickerOpen.value) {
    ev.preventDefault()
    if (text.value) text.value = ''
    else emit('dismiss')
    return true
  }
  return false
}

function onSend() {
  if (props.global && searchMode.value) {
    // the rest of the line goes to the hub verbatim (search-v1 §0)
    emit('search', searchQueryOf(text.value))
    opClosed.value = true
    return
  }
  if (props.global && props.sendBlocked) return
  if (props.omnibox && !props.global) {
    const parsed = parseOmnibox(text.value)
    if ('search' in parsed) {
      emit('search', parsed.search || '')
      text.value = ''
      return
    }
  }
  const body = closeOpenFence(text.value).trim()
  if ((!body && !picked.value.length) || props.busy) return
  const tooBig = sendLimitError(body)
  if (tooBig) {
    // nothing is sent and nothing is cleared: the author keeps the text and
    // can attach it as a file (005 T023 upload) instead
    sizeError.value = tooBig
    return
  }
  emit('send', body, props.parentTaskId, picked.value.slice())
  text.value = ''
  picked.value = []
  mentionQuery.value = null
  inCode.value = false
}

function onFiles(ev: Event) {
  const input = ev.target as HTMLInputElement
  if (!input.files || input.files.length === 0) return
  // uploaded on send (POST /v1/files), then referenced by file_id in files[]
  picked.value = [...picked.value, ...input.files]
  input.value = ''
}
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
  font-size: 12px;
  max-width: 100%;
  min-width: 0;
  overflow-wrap: anywhere;
}
.composer-too-big span { min-width: 0; }
textarea.in-code {
  font-family: var(--font-mono);
  font-size: 13px;
  background: var(--color-bg-2);
}
/* kept in the tree while empty so the live region announces entering a block */
.code-hint {
  margin: 0;
  font-size: 11px;
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
.file-chips li {
  font-size: 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 2px 6px;
  overflow-wrap: anywhere;
  min-width: 0;
}
.attach { cursor: pointer; }
.mention-list {
  list-style: none;
  margin: 0 0 8px;
  padding: 4px 0;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  max-height: 180px;
  overflow-y: auto;
  overflow-x: clip;
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
  font-size: 13px;
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
  font-size: 11px;
  padding: 1px 8px;
  margin: 0 0 4px;
  border-radius: var(--radius-pill);
  background: var(--color-accent);
  color: var(--color-on-accent);
  max-width: 100%;
}
.op-list code { font-family: var(--font-mono); }
.op-example {
  font-size: 12px;
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
