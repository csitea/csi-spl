<!-- SPL-1264 (CLE-77809): "Archived · Undo" bottom-centre after a card is
     archived. A thin adapter over the shared UndoSnackbar; the shell mounts it
     once a card has been archived; it ships WITH the shell (eager, CLE-77840: a
     lazy chunk is gone on a tab older than the last deploy). 0.7 s per
     the owner, held while hovered/focused (UndoSnackbar); CLE-77871: at least
     6 s on a touch UI, held while touched. Keyed by the toast id: a second
     archive restarts the window. -->
<template>
  <UndoSnackbar
    v-if="item"
    :key="item.id"
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
