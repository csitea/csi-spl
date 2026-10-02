<!-- The confirm behind a channel's "Delete channel" (SPL-72, channels-v1 §5.4)
     and "Archive channel" (rdb 0092: hides the channel and reserves its name;
     PUT .../unarchive brings it back). One component for both (CLE-77915:
     ChannelDeleteDialog and ChannelArchiveDialog were line-for-line copies
     but for the action). Layout is UiConfirm's (SPL-1001). Loaded lazily
     (LazyChannelConfirmDialog) so it stays off the initial script: it is
     needed only after the channel's creator picks the item. -->
<template>
  <UiConfirm
    :open="open"
    :title="t(`sidebar.${action}_channel.title`, { name })"
    :testid="`${action}-channel`"
    :confirm-label="t(`sidebar.${action}_channel.confirm`)"
    :busy-label="t(`sidebar.${action}_channel.busy`)"
    :busy="busy"
    :error="error"
    @update:open="emit('update:open', $event)"
    @confirm="confirm"
  >
    <p>{{ t(`sidebar.${action}_channel.body`, { name }) }}</p>
  </UiConfirm>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'

const props = defineProps<{ open: boolean, action: 'delete' | 'archive', channelId: string, name: string }>()
const emit = defineEmits<{ 'update:open': [boolean], done: [string] }>()
const { t } = useI18n({ useScope: 'global' })
const channel = useChannelStore()
const busy = ref(false)
const error = ref('')

watch(() => props.open, (v) => { if (v) error.value = '' })

/* the hub refuses anyone but the creator: 403 forbidden, 409 a default
   channel, 404 when it is already gone (or the caller is not a member) */
function copy(e: unknown) {
  const tok = (e && typeof e === 'object' && 'token' in e) ? String((e as { token?: unknown }).token || '') : ''
  const k = `sidebar.${props.action}_channel`
  if (tok === 'forbidden') return t(`${k}.error_forbidden`)
  if (tok === 'channel_public') return t(`${k}.error_default`)
  if (tok === 'unknown_channel') return t(`${k}.error_gone`)
  return t(`${k}.error_fallback`)
}

async function confirm() {
  const id = props.channelId
  if (!id || busy.value) return
  busy.value = true
  error.value = ''
  try {
    await (props.action === 'archive' ? channel.archiveChannel(id) : channel.deleteChannel(id))
    emit('update:open', false)
    emit('done', id)
  } catch (e) {
    error.value = copy(e)
  } finally {
    busy.value = false
  }
}
</script>
