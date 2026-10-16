/*
 * ChannelSidebar's New channel dialog (r13-04): the form, its slug, the create
 * and its errors in words, and the unarchive a reserved name offers.
 */
import { computed, ref, watch, type ComputedRef, type Ref } from 'vue'
import { useChannelStore } from '~/stores/channel'
import { useAccessStore } from '~/stores/access'
import { useMentionPicker } from '~/composables/useMentionPicker'
import { channelSlug } from '~/utils/channel-feed.mjs'

/** channels-v1 §5.1 errors, in words (409 channel_exists, 400 bad_channel). */
function createCopy(t: (key: string) => string, e: unknown) {
  const tok = (e && typeof e === 'object' && 'token' in e) ? String((e as { token?: unknown }).token || '') : ''
  if (tok === 'channel_exists') return t('sidebar.create_error.channel_exists')
  if (tok === 'channel_archived') return t('sidebar.create_error.channel_archived')
  if (tok === 'bad_channel') return t('sidebar.create_error.bad_channel')
  if (tok === 'view_door') return t('sidebar.create_error.view_door')
  return e instanceof Error ? e.message : t('sidebar.create_error.fallback')
}

export function useSidebarChannelCreate(signedOut: ComputedRef<boolean>, newDescriptionEl: Ref<HTMLTextAreaElement | null>) {
  const channel = useChannelStore()
  const access = useAccessStore()
  const { t } = useI18n({ useScope: 'global' })
  const localePath = useLocalePath()
  const newChannel = ref('')
  const newDescription = ref('')
  const descMp = useMentionPicker({ text: newDescription, el: newDescriptionEl })
  const createOpen = ref(false)
  const creating = ref(false)
  const createError = ref('')
  /* what the channel will actually be called in a URL and in an @mention */
  const slug = computed(() => channelSlug(newChannel.value))
  /* `access.can` fails OPEN by design (the store only hides actions;
     the hub re-checks every write), which is right for a member whose /view/me
     read failed and wrong for a visitor who is not signed in at all - they were
     offered a control that can only answer 401. A settled signed-out probe is
     not a failed read. */
  const canCreate = computed(() => !signedOut.value && access.can('channels.manage'))

  function openCreate() {
    createError.value = ''
    createOpen.value = true
  }

  /* a dismissed dialog keeps nothing: the next + starts on an empty form */
  watch(createOpen, (open) => {
    if (open) return
    newChannel.value = ''
    newDescription.value = ''
    createError.value = ''
  })

  /* rdb 0092: when the name is reserved by an ARCHIVED channel, the create error
     offers to unarchive it (channels.manage) instead of only refusing. */
  const archivedSlug = ref('')
  async function unarchiveFromCreate() {
    const id = archivedSlug.value
    if (!id || creating.value) return
    creating.value = true
    createError.value = ''
    try {
      await channel.unarchiveChannel(id)
      archivedSlug.value = ''
      createOpen.value = false
      await navigateTo(localePath('/channel/' + id))
    } catch (e) {
      createError.value = createCopy(t, e)
    } finally {
      creating.value = false
    }
  }

  async function onCreate() {
    const name = newChannel.value.trim()
    if (!name || creating.value) return
    creating.value = true
    createError.value = ''
    archivedSlug.value = ''
    try {
      const row = await channel.createChannel(name, descMp.encode(newDescription.value).trim())
      /* close first: the dialog restores focus to the + it was opened from, and
         the watcher clears the form, so a failed create keeps what was typed */
      createOpen.value = false
      await navigateTo(localePath('/channel/' + row.channel_id))
    } catch (e) {
      createError.value = createCopy(t, e)
      const tok = (e && typeof e === 'object' && 'token' in e) ? String((e as { token?: unknown }).token || '') : ''
      if (tok === 'channel_archived') archivedSlug.value = slug.value
    } finally {
      creating.value = false
    }
  }
  return { newChannel, newDescription, descMp, createOpen, creating, createError, slug, canCreate, openCreate, archivedSlug, unarchiveFromCreate, onCreate }
}
