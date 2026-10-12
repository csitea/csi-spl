<!-- SPL-1560 (owner HUM-10, t1 d74ecae5): the X that removes an attachment
     from the system, on every file card (message cards, issue comments, issue
     descriptions). "The position of the X should be decided based on the user
     settings: Mac or Windows, left or right side": it is the shared
     UiCloseButton, so it follows Settings -> Behaviour -> close_buttons (Mac =
     left, the owner's default, SPL-1133). FileAttachment places this at BOTH
     ends of the card and exactly one of the two renders.

     One click opens the destructive confirm (UiConfirm, SPL-1001); Delete
     calls `remove`, which the host wires to the hub (DELETE
     /v1/attachments/{file_id}). No undo: the blob is gone when the call
     answers. Its strings wait in the second catalogue (ON_DEMAND_COMPONENTS,
     "idle"); FileAttachment mounts it once they are merged. -->
<template>
  <UiCloseButton
    :side="side"
    class="file-remove"
    data-testid="file-remove"
    :label="t('feed.file_remove.label', { name })"
    :size="14"
    @click.stop="open = true"
  />
  <UiConfirm
    v-if="open"
    :open="open"
    :title="t('feed.file_remove.title')"
    testid="file-remove"
    :confirm-label="t('feed.file_remove.confirm')"
    :busy-label="t('feed.file_remove.confirm')"
    :busy="busy"
    :error="error"
    @update:open="open = $event"
    @confirm="onConfirm"
  >
    <p>{{ t('feed.file_remove.body', { name }) }}</p>
  </UiConfirm>
</template>

<script setup lang="ts">
const props = defineProps<{
  /** 'start' = left (Mac), 'end' = right (Windows); UiCloseButton shows one. */
  side: 'start' | 'end'
  name: string
  remove: () => Promise<unknown>
}>()
const { t } = useI18n({ useScope: 'global' })
const open = ref(false)
const busy = ref(false)
const error = ref('')

async function onConfirm() {
  busy.value = true
  error.value = ''
  try {
    await props.remove()
    open.value = false
  } catch (e) {
    const token = String((e as { token?: string })?.token || '')
    error.value = t(token === 'not_author' || token === 'not_editable' ? 'feed.file_remove.not_allowed' : 'feed.file_remove.failed')
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
/* the card's top corner on this X's side (FileAttachment keeps it clear) */
.file-remove {
  position: absolute;
  top: 4px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 28px;
  height: 28px;
  padding: 0;
  border: 0;
  border-radius: var(--radius-sm);
  background: none;
  color: var(--color-muted);
  cursor: pointer;
}
.file-remove[data-close-side="start"] { left: 4px; }
.file-remove[data-close-side="end"] { right: 4px; }
.file-remove:hover { color: var(--color-danger); background: var(--color-surface-hover); }
.file-remove:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}
/* SPL-991 phone: a 44 px target */
@media (max-width: 820px) {
  .file-remove { width: var(--tap); height: var(--tap); top: 0; }
  .file-remove[data-close-side="start"] { left: 0; }
  .file-remove[data-close-side="end"] { right: 0; }
}
</style>
