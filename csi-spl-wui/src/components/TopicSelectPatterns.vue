<!-- Spec 186 4.1 step 1 item 4 and 4.2 (row M3; owner HUM-10, t1 032d8010,
     msg 4b3833e7: "the select phase, which also should enable the selection
     by regexes"): Select by title. One pattern per line, `*` = every topic.
     Apply sends the lines as typed in one topic_select frame; the hub
     resolves them and the answer's topics join the selection. A bad line is
     named and adds nothing. This field never reads a pattern itself. Also
     the field of spec 186 M10's multicast loop. -->
<template>
  <form class="topic-select-patterns" data-test="topic-select-patterns" @submit.prevent="apply">
    <label :for="fieldId" class="topic-select-patterns__label">{{ t('topic_select.patterns') }}</label>
    <textarea
      :id="fieldId"
      ref="fieldEl"
      v-model="text"
      class="topic-select-patterns__field"
      data-test="topic-select-patterns-field"
      rows="3"
      spellcheck="false"
      autocomplete="off"
      @keydown.esc.stop.prevent="emit('close')"
    />
    <div class="topic-select-patterns__row">
      <button type="submit" class="btn" data-test="topic-select-apply" :disabled="busy || !text.trim()">{{ t('topic_select.apply') }}</button>
      <button type="button" class="btn ghost" data-test="topic-select-patterns-close" @click="emit('close')">{{ t('common.cancel') }}</button>
    </div>
    <p v-if="note" class="topic-select-patterns__note" :class="{ 'is-error': bad }" role="status" data-test="topic-select-patterns-note" :data-line="bad?.line">{{ note }}</p>
  </form>
</template>

<script setup lang="ts">
import { useTopicSelect, type PatternOutcome } from '~/composables/useTopicSelect'

const emit = defineEmits<{ close: [], added: [n: number] }>()
const { t } = useI18n({ useScope: 'global' })
const { selectByTitle } = useTopicSelect()
const fieldId = useId()
const fieldEl = ref<HTMLTextAreaElement | null>(null)
const text = ref('')
const busy = ref(false)
const outcome = ref<PatternOutcome | null>(null)
const bad = computed(() => outcome.value?.bad || null)
const note = computed(() => {
  const o = outcome.value
  if (!o) return ''
  if (o.bad) return t('topic_select.bad_pattern', { line: o.bad.line, reason: o.bad.reason })
  if (o.none) return t('topic_select.none')
  return o.error
})
onMounted(() => fieldEl.value?.focus())

async function apply() {
  if (busy.value) return
  busy.value = true
  try {
    const out = await selectByTitle(text.value)
    if (!out) return
    outcome.value = out
    if (out.added > 0) emit('added', out.added)
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.topic-select-patterns { display: flex; flex-direction: column; gap: 6px; padding: 8px 0; min-width: 0; }
.topic-select-patterns__label { font-size: 0.8125rem; color: var(--color-muted); }
.topic-select-patterns__field { width: 100%; min-width: 0; box-sizing: border-box; font-family: var(--font-mono, monospace); font-size: 0.875rem; resize: vertical; }
.topic-select-patterns__row { display: flex; gap: 6px; }
.topic-select-patterns__note { margin: 0; font-size: 0.8125rem; }
.topic-select-patterns__note.is-error { color: var(--color-danger); }
</style>
