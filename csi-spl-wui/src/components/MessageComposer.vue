<template>
  <form class="composer" :class="{ omnibox }" @submit.prevent="onSend">
    <div class="composer-box">
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
      <textarea
        ref="inputEl"
        :aria-label="omnibox ? t('composer.omnibox_label') : t('composer.message_label')"
        v-model="text"
        rows="2"
        :class="{ 'in-code': inCode }"
        :placeholder="placeholder"
        :aria-describedby="hintId"
        autocomplete="off"
        spellcheck="true"
        @keydown="onKeydown"
        @input="syncMention"
        @click="syncMention"
        @keyup="syncMention"
      />
      <p :id="hintId" class="code-hint muted" aria-live="polite">{{ inCode ? t('composer.code_hint') : '' }}</p>
      <ul v-if="picked.length" class="file-chips">
        <li v-for="(f, i) in picked" :key="f.name + i">
          📎 {{ f.name }} <small>{{ t('composer.file_bytes', { n: f.size }) }}</small>
          <button type="button" class="btn ghost" :aria-label="t('composer.remove_file', { name: f.name })" @click="picked.splice(i, 1)">×</button>
        </li>
      </ul>
      <div class="composer-row">
        <label class="muted attach">
          <input type="file" multiple hidden data-testid="attach" @change="onFiles">
          📎 {{ t('composer.attach') }}
        </label>
        <button type="submit" :disabled="busy || (!text.trim() && !picked.length)">{{ busy ? t('composer.sending') : t('composer.send') }}</button>
      </div>
    </div>
  </form>
</template>

<script setup lang="ts">
import { useRosterStore } from '~/stores/roster'
import { closeOpenFence, enterAction, exitFence, fenceStateAt } from '~/utils/code-blocks.mjs'
import { parseOmnibox } from '~/utils/feed.mjs'
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
}>()
const emit = defineEmits<{ send: [text: string, parentTaskId?: string, files?: File[]], search: [q: string] }>()
const picked = ref<File[]>([])
const roster = useRosterStore()
const text = ref('')
const inputEl = ref<HTMLTextAreaElement | null>(null)
const mentionQuery = ref<string | null>(null)
const activeIdx = ref(0)
/** Slack's ``` composer: the caret sits inside an open code block. */
const inCode = ref(false)
const hintId = useId()

const { t } = useI18n({ useScope: 'global' })
const placeholder = computed(() => props.placeholder || t('composer.placeholder_default', { mention: '@CLE-07' }))

function caret(): number {
  return inputEl.value?.selectionStart ?? text.value.length
}

function syncMention() {
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

function onSend() {
  if (props.omnibox) {
    const parsed = parseOmnibox(text.value)
    if ('search' in parsed) {
      emit('search', parsed.search || '')
      text.value = ''
      return
    }
  }
  const body = closeOpenFence(text.value).trim()
  if ((!body && !picked.value.length) || props.busy) return
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
  border-radius: 8px;
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
.mention-item.active,
.mention-item:hover {
  background: var(--color-surface-hover);
}
.mention-label {
  min-width: 0;
  overflow-wrap: anywhere;
}
</style>
