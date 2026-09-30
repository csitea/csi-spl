<!-- SPL-1024 (specs/045 §3.3): "Moved to ... · Undo" for 8 s after a move.
     Undo is the same endpoint with the answer's `undo` as the target. Loaded
     lazily by the shell (LazyMoveUndoToast), on the first move only.

     CLE-77809: a thin adapter over the shared UndoSnackbar. The 8 s timer stays
     in useMove (no `duration` here), so behaviour is unchanged; only the markup
     and styling now live in one place. -->
<template>
  <UndoSnackbar
    v-if="item"
    icon="move"
    testid="move-toast"
    :data-id="item.id"
    :text="item.text"
    :undo-label="t('feed.move.undo')"
    :close-label="t('common.close')"
    :show-undo="Boolean(item.undo)"
    :busy="item.busy"
    @undo="move.undo()"
    @dismiss="move.dismiss()"
  />
</template>

<script setup lang="ts">
import UndoSnackbar from '~/components/UndoSnackbar.vue'
import { useMove } from '~/composables/useMove'

const { t } = useI18n({ useScope: 'global' })
const move = useMove()
const item = computed(() => move.toast.value)
</script>
