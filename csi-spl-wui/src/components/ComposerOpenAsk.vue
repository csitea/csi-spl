<script setup lang="ts">
defineProps<{ name: string }>()
const emit = defineEmits(['open', 'post', 'dismiss'])
const { t } = useI18n({ useScope: 'global' })
</script>

<template>
  <div
    class="composer-open-ask"
    data-test="composer-open-channel"
    role="group"
    :aria-label="t('composer.open_channel', { name })"
    @keydown.escape.prevent="emit('dismiss')"
  >
    <button
      type="button"
      class="composer-open-ask__open"
      data-test="composer-open-channel-yes"
      @mousedown.prevent
      @click="emit('open')"
    >{{ t('composer.open_channel', { name }) }}</button>
    <button
      type="button"
      class="composer-open-ask__post"
      data-test="composer-open-channel-post"
      @mousedown.prevent
      @click="emit('post')"
    >{{ t('composer.post_anyway') }}</button>
  </div>
</template>

<style scoped>
.composer-open-ask {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin: 0 0 6px;
  max-width: 100%;
  min-width: 0;
}
.composer-open-ask button {
  min-height: var(--tap);
  padding: 6px 12px;
  border-radius: var(--radius-sm);
  border: 1px solid var(--color-border);
  background: var(--color-surface);
  color: var(--color-fg);
  font: inherit;
  font-size: 0.8125rem;
  cursor: pointer;
  overflow-wrap: anywhere;
}
.composer-open-ask button.composer-open-ask__open {
  background: var(--color-accent);
  color: var(--color-on-accent);
  border-color: transparent;
  font-weight: 600;
}
</style>
