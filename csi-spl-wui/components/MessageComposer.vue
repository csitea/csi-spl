<template>
  <form class="composer" @submit.prevent="onSend">
    <div class="composer-box">
      <ul
        v-if="pickerOpen"
        class="mention-list"
        role="listbox"
        aria-label="Mention suggestions"
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
            <span class="dot" :class="{ on: p.online }" />
            <span class="mention-label">{{ p.label }}</span>
          </button>
        </li>
      </ul>
      <textarea
        ref="inputEl"
        v-model="text"
        rows="2"
        :placeholder="placeholder"
        autocomplete="off"
        @keydown="onKeydown"
        @input="syncMention"
        @click="syncMention"
        @keyup="syncMention"
      />
      <ul v-if="picked.length" class="file-chips">
        <li v-for="(f, i) in picked" :key="f.name + i">
          📎 {{ f.name }} <small>{{ f.size }} B</small>
          <button type="button" class="btn ghost" :aria-label="'Remove ' + f.name" @click="picked.splice(i, 1)">×</button>
        </li>
      </ul>
      <div class="composer-row">
        <label class="muted attach">
          <input type="file" multiple hidden data-testid="attach" @change="onFiles">
          📎 attach
        </label>
        <button type="submit" :disabled="busy || (!text.trim() && !picked.length)">{{ busy ? 'Sending…' : 'Send' }}</button>
      </div>
    </div>
  </form>
</template>

<script setup lang="ts">
import { useRosterStore } from '~/stores/roster'
import {
  activeMentionQuery,
  filterRosterMentions,
  insertMention,
} from '~/utils/mention-autocomplete.mjs'

const props = defineProps<{
  placeholder?: string
  parentTaskId?: string
  busy?: boolean
}>()
const emit = defineEmits<{ send: [text: string, parentTaskId?: string, files?: File[]] }>()
const picked = ref<File[]>([])
const roster = useRosterStore()
const text = ref('')
const inputEl = ref<HTMLTextAreaElement | null>(null)
const mentionQuery = ref<string | null>(null)
const activeIdx = ref(0)

const placeholder = computed(() => props.placeholder || 'Message — @CLE-07 to task an agent')

function caret(): number {
  return inputEl.value?.selectionStart ?? text.value.length
}

function syncMention() {
  const q = activeMentionQuery(text.value, caret())
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
  if (ev.key === 'Enter' && !ev.shiftKey && !ev.altKey && !ev.ctrlKey && !ev.metaKey) {
    ev.preventDefault()
    onSend()
  }
}

function onSend() {
  const body = text.value.trim()
  if ((!body && !picked.value.length) || props.busy) return
  emit('send', body, props.parentTaskId, picked.value.slice())
  text.value = ''
  picked.value = []
  mentionQuery.value = null
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
