<!-- CLE-77852 (owner bug t1 e6c13767): "Sent to CLE-001 as a direct message:
     not a member of this channel". An @-mentioned agent that is seated in the
     workspace but not in the channel got the poke as a DM; this tells the
     author so instead of the old "cannot read this" error. A thin adapter over
     UndoSnackbar with no Undo; eager in the shell like the other toasts
     (CLE-77840). -->
<template>
  <UndoSnackbar
    v-if="item"
    :key="item.id"
    icon="messages"
    testid="mention-direct-toast"
    :data-id="item.id"
    :text="item.text"
    :show-undo="false"
    :close-label="t('common.close')"
    :duration="DIRECT_NOTE_MS"
    @dismiss="direct.dismiss()"
  />
</template>

<script setup lang="ts">
import UndoSnackbar from '~/components/UndoSnackbar.vue'
import { DIRECT_NOTE_MS, useMentionDirectNote } from '~/composables/useMentionPoke'

const { t } = useI18n({ useScope: 'global' })
const direct = useMentionDirectNote()
const item = computed(() => direct.note.value)
</script>
