<!-- CLE-77882: a message opened in place that cannot be shown - gone,
     archived, or not the reader's to see - says so in one line. A thin
     adapter over UndoSnackbar with no Undo; eager in the shell like the
     other toasts (CLE-77840). -->
<template>
  <UndoSnackbar
    v-if="item"
    :key="item.id"
    icon="messages"
    testid="open-msg-notice"
    :data-id="item.msgId"
    :data-reason="item.reason"
    :text="t('open_message.' + item.reason)"
    :show-undo="false"
    :close-label="t('common.close')"
    :duration="OPEN_NOTICE_MS"
    @dismiss="notice.dismiss()"
  />
</template>

<script setup lang="ts">
import UndoSnackbar from '~/components/UndoSnackbar.vue'
import { OPEN_NOTICE_MS, useOpenMessageNotice } from '~/composables/useOpenMessage'

const { t } = useI18n({ useScope: 'global' })
const notice = useOpenMessageNotice()
const item = computed(() => notice.notice.value)
</script>
