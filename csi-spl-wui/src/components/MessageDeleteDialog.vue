<!-- SPL-1001: the confirm behind a message's Delete (spec 032, the card
     menu). Only the question: the caller deletes on `confirm`, so a failure
     shows on the row as every other edit failure does. Loaded lazily
     (LazyMessageDeleteDialog): it is needed only after the item is picked. -->
<template>
  <UiConfirm
    :open="open"
    :title="t('feed.msg_delete.title')"
    testid="msg-delete"
    :confirm-label="t('feed.msg_delete.confirm')"
    :busy-label="t('feed.msg_delete.confirm')"
    @update:open="emit('update:open', $event)"
    @confirm="emit('update:open', false); emit('confirm')"
  >
    <p>{{ t('feed.msg_delete.body') }}</p>
  </UiConfirm>
</template>

<script setup lang="ts">
defineProps<{ open: boolean }>()
const emit = defineEmits<{ 'update:open': [boolean], confirm: [] }>()
const { t } = useI18n({ useScope: 'global' })
</script>
