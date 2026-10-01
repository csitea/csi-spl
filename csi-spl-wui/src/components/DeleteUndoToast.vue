<!-- CLE-77840 (owner, t1 topic bc1fd547): "Deleted · Undo" bottom-centre after
     a reply is deleted with the Delete key. A thin adapter over the shared
     UndoSnackbar, like ArchiveUndoToast; it ships WITH the shell (eager) for
     the same reason. Closing it is what sends the DELETE (useDeleteUndo). -->
<template>
  <UndoSnackbar
    v-if="item"
    icon="trash"
    testid="delete-toast"
    :text="t('feed.msg_delete.undo.done')"
    :undo-label="t('feed.msg_delete.undo.action')"
    :close-label="t('common.close')"
    :busy="item.busy"
    :duration="DELETE_UNDO_MS"
    @undo="del.undo()"
    @dismiss="del.dismiss()"
  />
</template>

<script setup lang="ts">
import UndoSnackbar from '~/components/UndoSnackbar.vue'
import { DELETE_UNDO_MS, useDeleteUndo } from '~/composables/useDeleteUndo'

const { t } = useI18n({ useScope: 'global' })
const del = useDeleteUndo()
const item = computed(() => del.toast.value)
</script>
