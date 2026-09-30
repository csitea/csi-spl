<!-- SPL-1264 (CLE-77809): "Archived · Undo" bottom-centre after a card is
     archived. A thin adapter over the shared UndoSnackbar; the shell mounts it
     lazily (LazyArchiveUndoToast) only once a card has been archived. 0.7 s per
     the owner, held while hovered/focused (UndoSnackbar). -->
<template>
  <UndoSnackbar
    v-if="item"
    icon="archive"
    testid="archive-toast"
    :text="t('archive.undo.done')"
    :undo-label="t('archive.undo.action')"
    :close-label="t('common.close')"
    :busy="item.busy"
    :duration="ARCHIVE_UNDO_MS"
    @undo="archive.undo()"
    @dismiss="archive.dismiss()"
  />
</template>

<script setup lang="ts">
import UndoSnackbar from '~/components/UndoSnackbar.vue'
import { ARCHIVE_UNDO_MS, useArchiveUndo } from '~/composables/useArchiveUndo'

const { t } = useI18n({ useScope: 'global' })
const archive = useArchiveUndo()
const item = computed(() => archive.toast.value)
</script>
