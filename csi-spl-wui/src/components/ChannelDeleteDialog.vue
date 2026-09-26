<!-- SPL-72, channels-v1 §5.4: the confirm behind "Delete channel". Loaded
     lazily (LazyChannelDeleteDialog) so it stays off the initial script: it
     is needed only after its creator picks the item. -->
<template>
  <UiDialog :open="open" :title="t('sidebar.delete_channel.title', { name })" size="md" @update:open="emit('update:open', $event)">
    <p class="delete-channel__body" data-testid="delete-channel-body">{{ t('sidebar.delete_channel.body', { name }) }}</p>
    <p v-if="error" class="delete-channel__error" role="alert" data-testid="delete-channel-error">{{ error }}</p>
    <template #footer>
      <div class="delete-channel__actions">
        <button type="button" class="btn ghost" data-autofocus :disabled="busy" data-testid="delete-channel-cancel" @click="emit('update:open', false)">{{ t('common.cancel') }}</button>
        <button
          type="button"
          class="btn ghost delete-channel__confirm"
          data-testid="delete-channel-confirm"
          :disabled="busy"
          @click="confirm"
        >{{ busy ? t('sidebar.delete_channel.busy') : t('sidebar.delete_channel.confirm') }}</button>
      </div>
    </template>
  </UiDialog>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'

const props = defineProps<{ open: boolean, channelId: string, name: string }>()
const emit = defineEmits<{ 'update:open': [boolean], deleted: [string] }>()
const { t } = useI18n({ useScope: 'global' })
const channel = useChannelStore()
const busy = ref(false)
const error = ref('')

watch(() => props.open, (v) => { if (v) error.value = '' })

/* the hub refuses anyone but the creator: 403 forbidden, 409 a default
   channel, 404 when it is already gone (or the caller is not a member) */
function copy(e: unknown) {
  const tok = (e && typeof e === 'object' && 'token' in e) ? String((e as { token?: unknown }).token || '') : ''
  if (tok === 'forbidden') return t('sidebar.delete_channel.error_forbidden')
  if (tok === 'channel_public') return t('sidebar.delete_channel.error_default')
  if (tok === 'unknown_channel') return t('sidebar.delete_channel.error_gone')
  return t('sidebar.delete_channel.error_fallback')
}

async function confirm() {
  const id = props.channelId
  if (!id || busy.value) return
  busy.value = true
  error.value = ''
  try {
    await channel.deleteChannel(id)
    emit('update:open', false)
    emit('deleted', id)
  } catch (e) {
    error.value = copy(e)
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.delete-channel__body { margin: 0; overflow-wrap: anywhere; }
.delete-channel__error { margin: 0.5rem 0 0; color: var(--color-danger); overflow-wrap: anywhere; }
.delete-channel__actions { display: flex; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
.delete-channel__confirm {
  color: var(--color-danger);
  border-color: var(--color-danger);
}
</style>
