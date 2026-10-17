<!-- SPL-2143 (owner HUM-10, t1 1061f05f msg 4d63f24c, suggestion 7): autosave
     kept the text with no sign of it and no way to drop it. While the box's
     text is the stored draft of this place (spec 080), one quiet line says
     "Draft saved", with Clear: it empties the box and removes the stored
     draft. No confirm: the app asks none for text actions.

     Lazy (LazyComposerDraftState) and on demand: its strings wait in the
     second catalogue (utils/i18n-first-screen.mjs) and it renders once they
     are merged, so first paint is unchanged. CSP: classes only, no :style. -->
<template>
  <p v-if="ready" class="composer-draft-state" data-testid="draft-state" role="status">
    <UiIcon name="check" :size="14" />
    <span>{{ t('composer.draft_state.saved') }}</span>
    <button
      type="button"
      class="composer-draft-state__clear"
      data-testid="draft-clear"
      :title="t('composer.draft_state.clear_hint')"
      @mousedown.prevent
      @click="emit('clear')"
    >{{ t('composer.draft_state.clear') }}</button>
  </p>
</template>

<script setup lang="ts">
const emit = defineEmits<{ clear: [] }>()
const { t, te } = useI18n({ useScope: 'global' })
/* its words are in the second catalogue, merged when the browser is first idle */
const ready = computed(() => te('composer.draft_state.saved'))
</script>

<style scoped>
.composer-draft-state {
  display: flex;
  align-items: center;
  gap: 6px;
  margin: 2px 0 4px;
  padding: 0 8px;
  min-width: 0;
  font-size: 0.75rem;
  color: var(--color-muted);
}
.composer-draft-state__clear {
  border: 0;
  background: none;
  padding: 0 2px;
  font: inherit;
  color: var(--color-accent);
  text-decoration: underline;
  cursor: pointer;
}
.composer-draft-state__clear:hover { color: var(--color-fg); }
</style>
