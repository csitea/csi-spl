<!-- SPL-1024 (specs/045 §3.3): "Moved to ... · Undo" for 8 s after a move.
     Undo is the same endpoint with the answer's `undo` as the target. Mounted by
     the shell on the first move; its code ships WITH the shell (CLE-77840: a
     lazy chunk is gone on a tab older than the last deploy).

     CLE-77809: a thin adapter over the shared UndoSnackbar.
     CLE-77871: the 8 s (3 s with no Undo) window moved here from useMove, so
     the snackbar's clock holds it while hovered, focused or touched like the
     others. Keyed by the toast id: a second move restarts the window. -->
<template>
  <UndoSnackbar
    v-if="item"
    :key="item.id"
    icon="move"
    testid="move-toast"
    :data-id="item.id"
    :text="item.text"
    :undo-label="t('feed.move.undo')"
    :close-label="t('common.close')"
    :show-undo="Boolean(item.undo)"
    :busy="item.busy"
    :duration="item.undo ? MOVE_UNDO_MS : UNDO_NOTE_MS"
    @undo="move.undo()"
    @dismiss="move.dismiss()"
  />
</template>

<script setup lang="ts">
import UndoSnackbar from '~/components/UndoSnackbar.vue'
import { MOVE_UNDO_MS, useMove } from '~/composables/useMove'
import { UNDO_NOTE_MS } from '~/utils/undo-timer.mjs'

const { t } = useI18n({ useScope: 'global' })
const move = useMove()
const item = computed(() => move.toast.value)
</script>
