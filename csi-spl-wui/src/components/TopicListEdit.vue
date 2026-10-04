<template>
  <textarea
    :value="modelValue"
    class="topic-list-edit"
    data-testid="topic-list-edit"
    rows="3"
    :disabled="saving"
    :aria-label="label"
    @input="onInput"
    @keydown="emit('keydown', $event)"
  />
</template>

<script setup lang="ts">
/* The topic list's in-place edit. It is not a reply composer: the omnibox
   stays the only message box on /t (composer-grow). */
defineProps<{
  modelValue: string
  saving?: boolean
  label: string
}>()
const emit = defineEmits<{
  'update:modelValue': [value: string]
  keydown: [ev: KeyboardEvent]
}>()
function onInput(ev: Event) {
  const el = ev.target
  if (el instanceof HTMLTextAreaElement) emit('update:modelValue', el.value)
}
</script>

<style scoped>
.topic-list-edit {
  display: block;
  width: 100%;
  box-sizing: border-box;
  margin: 2px 0;
  font: inherit;
  color: inherit;
  background: var(--color-bg);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 6px 8px;
  resize: vertical;
}
</style>
