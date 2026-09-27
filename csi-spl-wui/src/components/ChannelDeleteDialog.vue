<!-- SPL-72, channels-v1 §5.4: the confirm behind "Delete channel"; its layout
     is UiConfirm's (SPL-1001). Loaded lazily (LazyChannelDeleteDialog) so it
     stays off the initial script: it is needed only after its creator picks
     the item. -->
<template>
  <UiConfirm
    :open="open"
    :title="t('sidebar.delete_channel.title', { name })"
    testid="delete-channel"
    :confirm-label="t('sidebar.delete_channel.confirm')"
    :busy-label="t('sidebar.delete_channel.busy')"
    :busy="busy"
    :error="error"
    @update:open="emit('update:open', $event)"
    @confirm="confirm"
  >
    <p>{{ t('sidebar.delete_channel.body', { name }) }}</p>
  </UiConfirm>
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

