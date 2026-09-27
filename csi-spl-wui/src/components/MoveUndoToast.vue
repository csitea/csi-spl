<!-- SPL-1024 (specs/045 §3.3): "Moved to ... · Undo" for 8 s after a move.
     Undo is the same endpoint with the answer's `undo` as the target. Loaded
     lazily by the shell (LazyMoveUndoToast), on the first move only. -->
<template>
  <div v-if="item" class="move-toast" role="status" aria-live="polite" data-testid="move-toast" :data-id="item.id">
    <UiIcon class="move-toast__icon" name="move" :size="18" />
    <p class="move-toast__text" data-testid="move-toast-text">{{ item.text }}</p>
    <button
      v-if="item.undo"
      type="button"
      class="btn ghost move-toast__undo"
      data-testid="move-toast-undo"
      :disabled="item.busy"
      @click="move.undo()"
    >{{ t('feed.move.undo') }}</button>
    <button
      type="button"
      class="icon-btn move-toast__close"
      data-testid="move-toast-close"
      :aria-label="t('common.close')"
      :title="t('common.close')"
      @click="move.dismiss()"
    >
      <UiIcon name="x" :size="16" />
    </button>
  </div>
</template>

<script setup lang="ts">
import { useMove } from '~/composables/useMove'

const { t } = useI18n({ useScope: 'global' })
const move = useMove()
const item = computed(() => move.toast.value)
</script>

<style scoped>
.move-toast {
  position: fixed;
  left: 50%;
  bottom: 1rem;
  transform: translateX(-50%);
  z-index: var(--z-snackbar);
  display: flex;
  align-items: center;
  gap: 0.5rem;
  width: max-content;
  max-width: calc(100vw - 2rem);
  padding: 0.5rem 0.5rem 0.5rem 0.75rem;
  border: 1px solid var(--color-border-strong, var(--color-border));
  border-radius: var(--radius-sm);
  background: var(--color-bg-2, var(--color-surface));
  color: var(--color-fg);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
}
.move-toast__icon { flex: none; color: var(--color-accent); }
.move-toast__text {
  margin: 0;
  min-width: 0;
  font-size: 0.875rem;
  overflow-wrap: anywhere;
}
.move-toast__undo { flex: none; font-weight: 600; color: var(--color-accent); }
.move-toast__close { flex: none; }
</style>
