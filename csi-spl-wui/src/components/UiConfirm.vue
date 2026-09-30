<!-- SPL-1001: the ONE layout of a destructive confirm (delete a message, a
     topic, a channel). A clear question as the title, one short sentence,
     then [Cancel] [Delete]: Cancel is focused (so Enter cancels), Delete is
     the danger colour, Esc and the backdrop close (UiDialog). Buttons sit on
     the end edge on desktop and stack full width on a phone, where UiDialog is
     a full screen (SPL-993). Content only: the behaviour is UiDialog's. -->
<template>
  <UiDialog :open="open" :title="title" size="sm" @update:open="emit('update:open', $event)">
    <div class="ui-confirm__body" :data-testid="`${testid}-body`" v-bind="bodyAttrs">
      <slot />
    </div>
    <p v-if="error" class="ui-confirm__error" role="alert" :data-testid="`${testid}-error`">{{ error }}</p>
    <template #footer>
      <div class="ui-confirm__actions">
        <button
          type="button"
          class="btn ghost ui-confirm__cancel"
          data-autofocus
          :disabled="busy"
          :data-testid="`${testid}-cancel`"
          @click="emit('update:open', false)"
        >{{ t('common.cancel') }}</button>
        <button
          type="button"
          class="btn ghost danger"
          :disabled="busy || disabled"
          :data-testid="`${testid}-confirm`"
          @click="emit('confirm')"
        >
          <UiIcon name="delete" :size="16" />
          <span>{{ busy ? busyLabel : confirmLabel }}</span>
        </button>
      </div>
    </template>
  </UiDialog>
</template>

<script setup lang="ts">
withDefaults(
  defineProps<{
    open: boolean
    title: string
    /** the test-id prefix: `<testid>-body`, `-error`, `-cancel`, `-confirm` */
    testid: string
    confirmLabel: string
    busyLabel: string
    busy?: boolean
    disabled?: boolean
    error?: string
    /** extra attributes for the body (e.g. a data-* the proofs read) */
    bodyAttrs?: Record<string, string>
  }>(),
  { busy: false, disabled: false, error: '', bodyAttrs: () => ({}) },
)
const emit = defineEmits<{ 'update:open': [boolean], confirm: [] }>()
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.ui-confirm__body {
  padding: 8px 24px;
  line-height: 1.5;
  text-align: center;
  overflow-wrap: anywhere;
}
.ui-confirm__body :deep(p) { margin: 0 0 12px; }
.ui-confirm__body :deep(p:last-child) { margin-bottom: 0; }
.ui-confirm__error {
  margin: 8px 24px 0;
  color: var(--color-danger);
  text-align: center;
  overflow-wrap: anywhere;
}
.ui-confirm__actions {
  display: flex;
  justify-content: flex-end;
  gap: 12px;
  flex-wrap: wrap;
}
.ui-confirm__actions .btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  min-width: 104px;
}
/* the destructive button uses the shared .btn.ghost.danger (main.css,
   CLE-77799) so every confirm reads the same and stays WCAG-AA in each theme. */
.ui-confirm__actions .btn:disabled { opacity: 0.6; cursor: default; }
/* a phone: the buttons stack full width, Delete above Cancel (the thumb's
   nearest reach, at the bottom, is the safe one) */
@media (max-width: 600px) {
  .ui-confirm__body { padding: 24px 16px 8px; }
  .ui-confirm__error { margin: 8px 16px 0; }
  .ui-confirm__actions { flex-direction: column-reverse; gap: 8px; }
  .ui-confirm__actions .btn { width: 100%; }
}
</style>
