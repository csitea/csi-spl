/*
 * ChannelSidebar's channel row actions (r13-04): mute, Properties, and the
 * Delete / Archive confirms, with the leave-for-#lobby when the open channel
 * goes.
 */
import { computed, onBeforeUnmount, onMounted, ref, type ComputedRef, type Ref } from 'vue'
import { useChannelStore, type ChannelInfo } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { useAccessStore } from '~/stores/access'
import type { useSpoolApi } from '~/composables/useSpoolApi'
import type { useLive } from '~/composables/useLive'
import { isSignedOutVisitor } from '~/utils/shell-bootstrap.mjs'
import { MUTED_CHANNELS_KEY, loadMutedChannels, normalizeChannel, saveMutedChannels, toggleMutedChannel } from '~/utils/notify.mjs'
import { canDeleteChannel, viewerHumanId } from '~/utils/channel-members'

/* a channel's mute, kept in this browser (notify.mjs) */
function useChannelMute() {
  const mutedChannels = ref<string[]>([])
  function isChannelMuted(id: string) {
    return mutedChannels.value.includes(normalizeChannel(id))
  }
  function toggleChannelMute(id: string) {
    mutedChannels.value = saveMutedChannels(toggleMutedChannel(mutedChannels.value, id))
  }
  /* HUM-24 (311427c6): an unmute in Settings, or in another tab, shows here at once */
  function onMutedStorage(e: StorageEvent) {
    if (e.key === MUTED_CHANNELS_KEY || e.key === null) mutedChannels.value = loadMutedChannels()
  }
  onBeforeUnmount(() => window.removeEventListener('storage', onMutedStorage))
  onMounted(() => {
    mutedChannels.value = loadMutedChannels()
    window.addEventListener('storage', onMutedStorage)
  })
  return { isChannelMuted, toggleChannelMute }
}

export function useSidebarChannelAdmin(api: ReturnType<typeof useSpoolApi>, live: ReturnType<typeof useLive>, shownChannels: ComputedRef<ChannelInfo[]>, channelOrder: Ref<string[]>) {
  const channel = useChannelStore()
  const roster = useRosterStore()
  const session = useSessionStore()
  const access = useAccessStore()
  const localePath = useLocalePath()
  const { isChannelMuted, toggleChannelMute } = useChannelMute()
  const propertiesOpen = ref(false)
  const propertiesChannel = ref({ channel_id: '', name: '', description: '', created_by: '' })
  // A default channel has Properties too: it lists everyone, read-only.
  function showProperties(_id: string) {
    return !isSignedOutVisitor(session.state, api.mock)
  }
  function openProperties(id: string) {
    const row = shownChannels.value.find((c) => c.channel_id === id)
    propertiesChannel.value = {
      channel_id: id,
      name: String(row?.name || id),
      description: String(row?.description || ''),
      created_by: String(row?.created_by || ''),
    }
    propertiesOpen.value = true
  }
  /* SPL-72, channels-v1 §5.4: Delete channel. Offered to its creator only; the
     hub refuses anyone else (403, or 404 to a non-member) whatever this shows. */
  const selfId = computed(() => viewerHumanId(access.me, live.identity.value, { mock: api.mock, rosterMe: roster.me?.id || '' }))
  const deleteOpen = ref(false)
  const deleteTarget = ref({ channel_id: '', name: '' })
  function deletableChannel(id: string) {
    const row = shownChannels.value.find((c) => c.channel_id === id)
    return !!row && canDeleteChannel({ selfId: selfId.value, row })
  }
  /* the confirm is LazyChannelConfirmDialog: off the initial script (027 §6) */
  function askDeleteChannel(id: string) {
    const row = shownChannels.value.find((c) => c.channel_id === id)
    deleteTarget.value = { channel_id: id, name: String(row?.name || id) }
    deleteOpen.value = true
  }
  /* rdb 0092: Archive channel - the creator only, same door as delete. The
     confirm is LazyChannelConfirmDialog. */
  const archiveOpen = ref(false)
  const archiveTarget = ref({ channel_id: '', name: '' })
  function askArchiveChannel(id: string) {
    const row = shownChannels.value.find((c) => c.channel_id === id)
    archiveTarget.value = { channel_id: id, name: String(row?.name || id) }
    archiveOpen.value = true
  }
  function onChannelArchived(id: string) {
    onChannelDeleted(id) // an archived channel drops from the sidebar just like a deleted one
  }
  /* the open channel is gone: leave it for #lobby rather than show a 404 page */
  function leaveDeleted(id: string) {
    if (channel.active === id) void navigateTo(localePath('/channel/lobby'))
  }
  function onChannelDeleted(id: string) {
    channelOrder.value = channelOrder.value.filter((k) => k !== id)
    leaveDeleted(id)
  }
  /* another member deleted it: every open sidebar drops the row (store), and a
     member reading it right now is taken to #lobby */
  let offChannel: (() => void) | undefined
  onMounted(() => {
    offChannel = live.onChannel((f) => {
      if (f.type === 'channel_deleted') leaveDeleted(String(f.channel || ''))
    })
  })
  onBeforeUnmount(() => { offChannel?.() })
  return { propertiesOpen, propertiesChannel, isChannelMuted, toggleChannelMute, showProperties, openProperties, deleteOpen, deleteTarget, deletableChannel, askDeleteChannel, archiveOpen, archiveTarget, askArchiveChannel, onChannelArchived, onChannelDeleted }
}
